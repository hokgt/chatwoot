# Deferred Auto-Assignment — Reconciliation (design + operator guide)

Reassigns conversations that lost their human assignee when an agent was **deleted**, when the
live post-commit agent-deletion bridge did not complete (e.g. a crash between the unassignment
commit and the dispatch). It is **additive**: the live new-conversation path, the agent-deletion
bridge, eligibility, the native selector, capacity/presence/round-robin, locks, and ERP owner
sync are all unchanged.

There are **two** reconciliation entry points, both scanning **only** durable provenance and both
ending at the exact same native pipeline — neither is the primary future deletion mechanism (that
stays `Agents::DestroyJob -> Registrar`, unchanged):

1. **One-time initial reconciliation** (a migration at deploy) — the historical-backlog mechanism,
   run **exactly once** with a fixed cutoff.
2. **Recurring recovery drainer** (a low-frequency cron) — a durable-outbox / crash-gap **fallback**
   for provenance recorded **after** the one-time run, which its fixed cutoff can never reach.

## Evidence conclusion (why this is provenance-driven, not heuristic)

There is **no reliable immutable historical chain** for assignee changes in this install:

- `Enterprise::Audit::Conversation` audits `only: []` on `:destroy` — it records **nothing** about
  the assignee and only on destroy, so there is no assignment-change audit.
- `Enterprise::Audit::User` is effectively disabled (`unless: proc { |_u| true }`) — no user
  deletion audit.
- `Enterprise::Audit::AccountUser` records `:create`/`:update` only — **never** `:destroy`.
- All of the above are Enterprise-only; CE/FOSS has no audit at all.
- `Agents::DestroyJob` clears `assignee_id` via `update_all`, which skips callbacks/audits.

`reporting_events`, participants, sender history and free-text activity are **not** acceptable
proof (free text such as "Assigned to X" is evidence only, never authoritative). Therefore the
only trustworthy source is provenance this battery records **itself, at deletion time**.

## Durable provenance (recorded going forward)

When `Agents::DestroyJob` deletes an agent it **row-locks (`FOR UPDATE`)** the conversations still
assigned to that user, clears **only** those still owned by the user while the lock is held, and
records a `wijaya_deferred_assignment_provenance` tombstone for **exactly the rows it cleared**. A
concurrent manual reassignment is serialized either fully **before** the lock (excluded from every
step) or fully **after** the commit (it wins), so a deletion can never record a tombstone for — nor
clobber — a conversation it did not actually unassign.

> **Best-effort, NOT guaranteed atomic completeness.** The tombstone write is savepoint-isolated
> (`requires_new: true`) and routed through the fail-open core dispatcher, so a recorder failure can
> **never** roll back the user deletion. The direct consequence, stated plainly: provenance capture
> is **best-effort**. On a recorder failure the deletion still commits with that tombstone **absent**,
> and — having no other authoritative source — that conversation stays **unrecoverable** by
> reconciliation. Normal deletion is never blocked. This is a deliberate fail-open trade-off, not an
> all-or-nothing guarantee.

Each tombstone stores:

- account, conversation, inbox, **prior human agent id**, event kind (`agent_deletion`), event time,
  a `reconciled_at` cursor, a `superseded_at` continuity cursor, and a **`deletion_key`**.
- **`deletion_key`** is the `Agents::DestroyJob` ActiveJob `job_id` — stable across retries of one
  deletion but distinct for a genuinely new deletion. Uniqueness is
  `(conversation_id, prior_assignee_id, event, deletion_key)`, so a **retry** of one deletion dedupes
  while a later **re-add and re-deletion** of the same conversation+agent records a **distinct,
  independently reconcilable** tombstone (the earlier design's 3-column key collapsed these).
- `prior_assignee_id` has **no foreign key** — the agent User is deleted in this very scenario, and
  a cascading FK would erase the provenance. Account/conversation/inbox FKs cascade because nothing
  is left to reassign once those are gone.
- **No message content, no credentials** are ever stored.

### Causal-continuity guard (`superseded_at`)

A pending tombstone is adopted only while the conversation's emptiness still traces to the deletion.
The reconciliation does **not** rely on "current assignee is nil": the moment an **intervening
intentional transition** commits on the conversation — a human/bot assignment, a team/inbox routing
change, or a status transition (**close/reopen**) — the battery `ConversationExtensions`
**in-transaction** `after_update` seam marks any still-pending tombstone `superseded_at`, atomically
with that transition. The `unreconciled` scope excludes superseded rows, so a conversation that was
reassigned/routed/reopened and **then** unassigned again is **never re-adopted**. The
deletion-caused unassignment itself uses `update_all` (callbacks skipped), so it never supersedes its
own tombstone and a genuine crash-gap orphan stays eligible. The write is a validation/FK-free
`update_all`, so on the rare DB failure the whole transaction rolls back with the transition
(fail-closed).

## Automatic one-time (initial) reconciliation

A migration (`20260912000003_enqueue_deferred_assignment_reconciliation_after_schema`) persists a
**durable run intent** exactly once at deploy: it INSERTs a `wijaya_deferred_reconciliation_runs`
row (`status = running`, `started_at = NULL`, full-history `cutoff_at`), **not** a one-shot Redis
`perform_later`. Relying on an in-migration `perform_later` was fragile — a Redis outage, or an old
Sidekiq worker consuming the job in the deploy window against an incomplete schema, could silently
drop the only trigger. The **recurring `RecoveryDrainerJob` is the coordinator**: each tick it
selects **at most one** incomplete run and runs the `Reconciler` **inline** (see the recovery-drainer
section) until it truthfully completes (bounded), so the one-time run executes later under new code
with the full schema and cannot be lost to Redis/timing. The INSERT is idempotent (`WHERE NOT EXISTS`
on the unique `generation`), so a re-run of the migration never creates a second intent, and the
ledger's unique `generation` keeps the run one-time. (The enqueue originally lived in `…000001`,
which is now a **no-op**.) Because `…000003` was rewritten in place from the old Redis enqueue to
this durable INSERT, an environment that had already recorded the OLD `…000003` would never re-run
its rewritten `up`; the forward migration **`…000007`** idempotently ensures the same one-time run
intent exists on those installs (`WHERE NOT EXISTS` on the same `generation`, no Redis). The
coordinator (and the retained `ReconciliationJob`, below) run the `Reconciler`, which:

- scans **only** unreconciled provenance rows (never all unassigned conversations), in bounded
  batches;
- is guarded by a `wijaya_deferred_reconciliation_runs` ledger keyed on a unique **generation**
  (the persisted run/cutoff/completion state) so a retry/re-enqueue **resumes** the same run
  instead of starting a second engine;
- runs the **entire scan + dispatch + finalize under a single GLOBAL PostgreSQL SESSION advisory
  lock** (a fixed key, **not** scoped to the generation), so only **one** reconciliation of **any**
  generation is ever inside it — the one-time run and every recurring drainer run are strictly
  serialized and can never race each other's `running` run rows. A job that cannot take the lock
  **raises** `Reconciler::LockContention` (a `StandardError`) so `ReconciliationJob`'s bounded
  `retry_on` re-enqueues it and its generation is eventually processed once the lock frees — it
  **never** returns a successful no-op, which would strand its run row permanently `running` (nothing
  else would retry it). It can **never** mark a run `completed` while another worker still owns (and
  may roll back) the tail of the scan. The lock auto-releases if the owner's DB session dies, so a
  later re-enqueue safely resumes;
- claims each batch with **`FOR UPDATE SKIP LOCKED`** (defense in depth behind the advisory lock)
  and, in **one transaction**, classifies + registers + stamps `reconciled_at` + adds the batch's
  counts to the run row — so a row is stamped (and counted) **only after its disposition has
  committed**. A failed batch rolls back wholesale (row left unreconciled, counters untouched); a
  retried or duplicate job **resumes** from the remaining unreconciled rows without losing or
  double-counting work;
- does **not** enqueue the coalesced `ProcessInboxJob` per batch. Instead the reconciliation-stamped
  markers themselves are a **durable outbox**: after all batches are scanned, every still-present
  marker for the generation is (re-)dispatched, then the run is finalized. A crash/raise **between a
  batch commit and the enqueue** therefore strands nothing — a retry re-dispatches every
  still-present generation marker, relying on the existing in-flight coalescing + `InboxProcessor`
  idempotency. That per-batch dispatch is **best-effort**, though: `enqueue_for_inbox` is coalesced
  away by a stale in-flight key left by a **crashed worker**, and both keys then expire with no
  worker having consumed them. Finalizing the run right after dispatch is therefore safe **only
  because the marker is durable and the hourly `RecoveryDrainerJob` marker-outbox drain
  redispatches every still-present marker on every tick** (see the recovery-drainer section) — a
  finalized run, whose provenance is now reconciled, never re-dispatches on its own.

For each provenance row it **fails closed**:

| Category | Meaning |
|----------|---------|
| **ambiguous** (never registered) | conversation missing; account mismatch (cross-account safety); event is not a recorded agent deletion; conversation created at/after the cutoff; **prior agent is still an account member** (not actually deleted) |
| **skipped** (proven orphan, not currently actionable) | already carries a marker (live pipeline owns it); not currently `Eligibility.deferrable?` (resolved/snoozed/pending, already manually or bot-assigned, team auto-assign off, V2, inbox gone) |
| **registered** | proven deleted-agent orphan **and** deferrable **and** markerless **and** same-account **and** created before cutoff |

Registration goes through `Registrar.register_unassigned_from_provenance`, which shares the exact
live pipeline and **never writes `assignee_id` directly**:

```
Reconciler (per batch, in one FOR UPDATE SKIP LOCKED transaction)
           -> Registrar.register_unassigned_from_provenance (returns { adopted:, inbox_ids: })
                -> (per id) Marker exists? skip  |  Eligibility.deferrable? recheck
                -> Marker (unique conversation_id, stamped reconciliation_generation)
           -> stamp reconciled_at + bump run counters  (atomic, same transaction)
   after commit:
           -> ProcessInboxJob (coalesced per inbox)
           -> InboxProcessor (row-locked recheck) -> native AutoAssignment::AgentAssignmentService
           -> conversation.update! -> existing ERP owner-sync callback (only if a lead is linked)
           -> Marker.resolve_and_record / record_waiting  (ledger disposition, correlated by generation)
```

A manual assignment made before reconciliation is never overwritten (assignee-present rows are not
deferrable, and the row-locked recheck in `InboxProcessor` re-verifies immediately before writing).

> **`registered` is the ACTUAL adopted count.** `Registrar.register_unassigned_from_provenance`
> re-checks each candidate (`Marker.exists?` / `Eligibility.deferrable?` / a concurrently-created
> marker) and returns how many markers it truly adopted. A conversation that was marked or assigned
> between the reconciler's classification and this call is reported **skipped**, so `registered` can
> never overstate what happened. It returns a structured outcome and does **not** enqueue — the
> reconciler enqueues the coalesced per-inbox pass after the batch commits.

### Observability

The run ledger carries the **full required counter set**, persisted **cumulatively and
idempotently** (never a once-only finalize), so a resumed run reports exact totals:

| Counter | Meaning |
|---------|---------|
| `scanned` | provenance rows examined (each stamped `reconciled_at` exactly once) |
| `identified` | of those, the ones structurally **proven** deleted-agent orphans (`registered + skipped`) |
| `registered` | orphans a marker was **actually adopted** for by this run (post Registrar re-check) |
| `skipped` | proven orphans left to existing behavior (already marked / not deferrable / raced) |
| `ambiguous` | rows without structural proof (never touched) |
| `assigned` / `no_eligible_agent` / `dropped` | the **latest, unique** async disposition of each registered marker |
| `failed` / `retries` | failed run attempts and resumes (job retries) for this generation |

The three async dispositions are recorded by the shared `InboxProcessor` — the only place the actual
assignment result is truthfully known — and correlated back to the run via a nullable
`reconciliation_generation` stamped on the marker (**NULL for every ordinary marker**, which is
therefore unchanged). The ledger represents the **latest unique disposition per identified
conversation**: a repeated "no eligible agent" pass is **not** re-counted, and if a waiting orphan is
later assigned (by the system) or dropped (manually/bot assigned or resolved between passes) the
count **transitions** (`no_eligible_agent → assigned`/`dropped`) rather than double-counting. The
marker's outcome/removal transition and the run counter transition are wrapped in **one transaction**
at every call site (`Marker.resolve_and_record` / `Marker.record_waiting`), so a crash between them
can never leave the marker and the counters diverged. Every outcome is logged content-free
(`conversation=<id> outcome=<...> reconciliation_generation=<gen>`) — never message bodies or
assignee names.

> **What `completed` means.** A run row marked `completed` means only that the **scan + durable
> dispatch** were accepted. The scan-time counters (`scanned` / `identified` / `registered` /
> `skipped` / `ambiguous`) are final at that point, but the async outcome counters (`assigned` /
> `no_eligible_agent` / `dropped`) keep **transitioning afterwards** as the `InboxProcessor` resolves
> each still-waiting marker on later availability triggers. `completed` is therefore **not** a claim
> that every adopted conversation has already been assigned — only that every one has been durably
> registered and dispatched.

### Retry / deploy safety

`ReconciliationJob` is **retained for legacy / manual / already-queued compatibility only** (an
operator-invoked one-off resume, or an old job still on the `:low` queue from before this change) — it
is **no longer enqueued by the coordinator**. When it does run it uses a **bounded** `retry_on
StandardError, attempts: 5` (consistent with the app's job conventions, e.g.
`Captain::Documents::PerformSyncJob`) — **not** an unbounded custom loop. Each retry resumes the same
generation from the still-unreconciled rows and increments `retries`; a failed attempt increments
`failed`. After attempts are exhausted the run stays `running`, safe to re-run later without
rescanning completed batches.

The **coordinator path does not use `ReconciliationJob` at all** — it runs the `Reconciler` **inline**
(see the recovery-drainer section), so it carries **no** separate `retry_on` tree. Its bounded retry
is simply the next hourly cron occurrence.

**Migration set (version order).** `…000001` is a no-op (kept because it may already be recorded in
`schema_migrations`); `…000002` adds the `reconciliation_generation` / `reconciliation_outcome`
marker columns and the full run counter set; `…000003` persists the durable one-time run intent;
`…000004` adds the per-occurrence `deletion_key` and reindexes provenance uniqueness to
`(conversation_id, prior_assignee_id, event, deletion_key)`; `…000005` is a **forward-only repair**
of the marker foreign keys to `on_delete: :cascade` (reconciling the drift left by editing the
already-applied `20260905000000` in place — never a history rewrite); `…000006` adds the
`superseded_at` continuity column; `…000007` is the **forward repair** ensuring the durable one-time
run intent exists on installs that recorded the OLD (pre-rewrite) `…000003` and would never re-run
its rewritten `up` (idempotent `WHERE NOT EXISTS` on the same `generation`, no Redis); `…000008`
installs the **`MarkerDropTrigger`** BEFORE DELETE trigger that keeps the run ledger's terminal
counters truthful when a DB cascade removes a reconciliation-owned marker with **no** Rails callback
(declared with the HairTrigger `create_trigger` DSL, so it is dumped into `db/schema.rb` and a fresh
`db:schema:load` reconstructs it in the correct function-before-trigger order — no boot-time DDL).
All are additive/idempotent and never edit an applied
migration as an upgrade substitute. The `generation` for the automatic run is `20260912000003`.

Because the one-time run is a **persisted intent executed by the drainer coordinator** (not a Redis
job queued inside the migration), it no longer depends on old-Sidekiq/Redis timing: it runs later
under new code with the full schema regardless.

**Deploy order** (still recommended so nothing consumes the job path prematurely):

1. **Stop the old Sidekiq workers.**
2. **Back up the database.**
3. **Build the new image** (with the corrected battery code).
4. **Run migrations using the new image** (`20260912000000` … `…000008`). `…000003` persists the
   durable run intent (`…000007` repairs it on installs that recorded the old `…000003`); `…000008`
   installs the marker-drop trigger; the remaining additive/repair migrations complete the schema.
5. **Start the new `rails` and `sidekiq`.** The scheduled `RecoveryDrainerJob` then resumes the
   persisted run intent (and drains any crash-gap provenance) under the corrected code.

On **this** install the initial run scans **zero** legacy rows (the provenance table is new), so it
is effectively a no-op here, but its run ledger still **completes truthfully**; the machinery is
correct for any future re-deploy or for deletions that accumulate a crash-gap provenance row going
forward. Pre-feature deletions carry no provenance and are never inferred from activity text.

## Recurring recovery drainer (crash-gap fallback — distinct from the one-time run)

The one-time initial reconciliation runs **exactly once** with a **fixed cutoff** (the deploy
moment), so any provenance recorded **after** it is excluded **forever**. A future agent deletion
that hits the one irreducible crash-gap — a SIGKILL **after** the unassignment transaction commits
(the provenance tombstone is durable) but **before** the post-commit `Registrar` dispatch — would
therefore be **stranded permanently** with only the one-time migration in place.

`Wijaya::Batteries::DeferredAutoAssignment::RecoveryDrainerJob` closes that gap **and** acts as the
**durable-run-intent coordinator**. It is a **low-frequency scheduled fallback, NOT the primary
future deletion mechanism** — the normal `Agents::DestroyJob -> Registrar` bridge remains primary and
behaviorally unchanged. It is itself **one hourly scheduled cron occurrence**, and on each tick it
selects **at most one** persisted run intent and runs the `Reconciler` **INLINE** (a direct
`Reconciler.run` call under the Reconciler's own global advisory lock) — it **does NOT** call
`ReconciliationJob.perform_later`/`perform_now`. Handing off to that second `:low` queue was the
release blocker: while the queue was delayed/down each tick would enqueue **another**
`ReconciliationJob` for the same work, accumulating duplicates each with its own `retry_on` tree, and
a fresh generation could be enqueued before its run row was atomically claimed. Running inline
collapses recovery to **exactly one queued unit per tick** (this cron occurrence) with no downstream
retry tree.

On each tick it **adopts at most one incomplete `ReconciliationRun`** (the oldest — the one-time
migration intent, or any run left `running` by a crash / expected failure on a prior tick) and
reconciles it inline with the run's **own persisted `generation`/`cutoff_at`** — so a persisted intent
is retried until it truthfully completes. **If any incomplete run exists, the tick stops there and
does NOT open a new generation** (the amplification guard). Only once **every** intent has completed
does a tick open crash-gap recovery:

- scans **only** unreconciled `DeletionProvenance` tombstones (`reconciled_at IS NULL`) whose
  `event_at` is **older than a short safety age** (`SAFETY_AGE = 15.minutes`), so it never races the
  live post-commit bridge and only ever picks up a genuine crash-gap straggler — it **never** scans
  the conversations table or all Unassigned conversations;
- **self-gates**: if no such tombstone exists (and no incomplete run) it does **nothing** — no
  `ReconciliationRun` row is created and no reconciliation runs (an empty system stays completely
  quiet);
- when a straggler exists, it **durably `find_or_create`s exactly one fresh recovery run intent** (a
  `generation` bucketed to the minute, persisted **before** any processing) and reconciles **that**
  run inline. From there it is the **identical** path as the one-time run: `Reconciler ->
  Registrar.register_unassigned_from_provenance -> Marker -> ProcessInboxJob -> InboxProcessor ->
  native AgentAssignmentService -> conversation.update! -> existing ERP owner-sync callback`. **No
  direct `assignee_id` write, no second engine.**

**Bounded, idempotent, concurrency-safe.** Each tick reconciles **at most one** run inline and opens
**at most one** new generation, and never opens a new generation while any incomplete run exists — so
a persistent registrar/DB/lock failure keeps run growth **flat** (one inline resume per tick) instead
of accumulating one fresh generation per tick on top of a stuck run. Two overlapping ticks in the
same minute `find_or_create` the **same** generation and collapse onto one row (`find_or_create_by!`
absorbs the create race); the **global** advisory lock then serializes them and the loser raises
`LockContention`, which the coordinator **swallows** (logged, not re-raised — re-raising would let
ActiveJob's Sidekiq default retry spin a second, unbounded retry tree). A later legitimate tick either
resumes the still-incomplete run or, once it has completed, finds the rows already stamped
`reconciled_at` and scans (near) nothing. A transient reconciliation failure is likewise swallowed:
the `Reconciler` leaves the run `running` with its committed batches intact, and the **next hourly
tick is the bounded retry** — it resumes the same generation. Every provenance row the live bridge
already handled is re-checked and stamped reconciled as **skipped**/**ambiguous** on the first drain
that reaches it — harmless and one-time. Run counters and marker outcome accounting are the **same**
truthful ledger as the one-time run.

### Marker durable outbox (always-on, every tick)

Reconciler `dispatch` calls `ProcessInboxJob.enqueue_for_inbox`, which is **best-effort**: if a Redis
in-flight key from a **crashed/lost worker** is present, the dispatch is coalesced away (a rerun key
is set) and **no worker consumes it**; both keys then expire after their 5-minute TTL. Since the
Reconciler has by then stamped provenance `reconciled_at` and completed the run, and the crash-gap
branch scans **only unreconciled** provenance, the still-present `Marker` row would be **stranded
forever** with no guaranteed worker.

So on **every** tick — first, before run-intent coordination, and regardless of any run/provenance
state — the drainer also redispatches a **bounded** batch (`MARKER_OUTBOX_BATCH = 100` distinct
inbox ids) of the inboxes that **currently hold `Marker` rows**, querying **only** the battery
marker table (never `Conversation`, never all Unassigned). It reuses `enqueue_for_inbox`, so the
in-flight/rerun coalescing stays **authoritative**: a **live** key coalesces the tick (no job
storm — repeated ticks against a live key enqueue nothing new), while a **stale** key that has since
expired lets a **later** hourly tick enqueue a real `ProcessInboxJob`. The batch bound means a tick
with more than 100 marker-inboxes drains the rest on subsequent ticks (markers are durable). This is
what makes the marker a true durable outbox and lets the Reconciler finalize immediately after an
accepted/coalesced dispatch.

**Ordering (deliberate, fail-closed).** The marker-outbox drain runs **first**, so it executes on
every tick and is never preempted by the reconcile step, whose commonly-expected `LockContention`
(or a transient reconcile error) the tick-level guard swallows. The **whole tick** — drain + run
selection + inline reconcile — is under a **single** `rescue`: any DB/Redis/dispatch error is logged
and **swallowed**, never re-raised (re-raising would let ActiveJob's Sidekiq default retry spin an
independent, unbounded retry tree, one per hourly tick). A drain failure that preempts the reconcile
loses nothing — the run intent is persisted and resumes next tick, and the drain retries next tick
against the durable markers.

**Scheduler touchpoint.** A single `config/schedule.yml` entry
(`wijaya_deferred_assignment_recovery_drainer_job`, hourly, inside `WIJAYA_CUSTOM` markers) drives it.
This is permitted as a scheduled job **precisely because it queries provenance tombstones** (and the
battery's own marker table), not a blanket Unassigned scan. It is covered by `check_custom_patches.sh`
and the patch registry.

## Limitation: pre-provenance legacy cases cannot be recovered automatically

Conversations that lost their assignee to a deletion that happened **before** this battery started
recording provenance have **no provenance row**. They are invisible to **both** the one-time
reconciliation **and** the recurring recovery drainer (each scans only durable provenance) and are
**never** guessed from free-text activity — they remain **unrecoverable and untouched**. This
includes the current open-unassigned backlog of pre-feature rows without immutable provenance. Such
cases can only be recovered by supplying an **external authoritative source** (a database backup, an
audit export, or an operator who can vouch for the exact prior assignee) — see the deprecated manual
tooling below. There is no safe automatic way to reconstruct them from the live database alone.

## Deprecated: manual allowlist apply (operator escape hatch)

> **Deprecated as the required path.** Automatic reconciliation needs no manual ids and no
> per-conversation approval. The manual apply remains only as an operator escape hatch for
> pre-provenance cases backed by an external authoritative source. The **read-only discovery /
> dry-run stays useful as diagnostics.**

One operator entry point (dry-run by default; nothing mutates without `MODE=apply`, an explicit
allowlist, and `APPLY=1`):

```bash
# Read-only discovery (diagnostics)
ACCOUNT_ID=<id> [LIMIT=<n>] [INBOX_ID=<id>] \
  bundle exec rails runner custom/wijaya/batteries/deferred_auto_assignment/bin/historical_backfill.rb

# Guarded apply for an operator-approved, externally-authoritative allowlist
MODE=apply APPLY=1 ACCOUNT_ID=<id> CONVERSATION_IDS=101,102,103 \
  bundle exec rails runner custom/wijaya/batteries/deferred_auto_assignment/bin/historical_backfill.rb
```

Discovery evidence (including any assignment-related **activity** line) is review material only —
never customer message bodies, never approval. Apply reuses the same live pipeline as automatic
reconciliation via `Registrar.register_unassigned_historical`; it is bounded, idempotent, and
rejects cross-account/missing ids distinctly.

## Notes

- **No blanket scan / no recurring job** — provenance rows are the entire automatic work-list.
- **No new ERP path** — assignment flows through the existing `after_update_commit` owner-sync callback.
- **No second assignment engine, no direct `assignee_id` write** — every path ends at the native selector.
