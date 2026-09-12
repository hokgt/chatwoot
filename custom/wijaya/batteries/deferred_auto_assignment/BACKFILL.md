# Deferred Auto-Assignment — Historical Reconciliation (design + operator guide)

Reassigns conversations that lost their human assignee when an agent was **deleted**, when the
live post-commit agent-deletion bridge did not complete (e.g. a crash between the unassignment
commit and the dispatch). It is **additive**: the live new-conversation path, the agent-deletion
bridge, eligibility, the native selector, capacity/presence/round-robin, locks, and ERP owner
sync are all unchanged.

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

When `Agents::DestroyJob` deletes an agent, a `wijaya_deferred_assignment_provenance` tombstone is
written **atomically inside the unassignment transaction** (savepoint-isolated + fail-open, so it
can never roll back the user deletion) for each cleared conversation:

- account, conversation, inbox, **prior human agent id**, event kind (`agent_deletion`), event time,
  and a `reconciled_at` cursor.
- `prior_assignee_id` has **no foreign key** — the agent User is deleted in this very scenario, and
  a cascading FK would erase the provenance. Account/conversation/inbox FKs cascade because nothing
  is left to reassign once those are gone.
- **No message content, no credentials** are ever stored.

## Automatic one-time reconciliation

A migration (`20260912000001_enqueue_deferred_assignment_reconciliation`) enqueues
`ReconciliationJob` exactly once at deploy — the same convention as
`EnqueueValidateOpenaiHooksJob`. It is recorded once in `schema_migrations`, so it is **not a
recurring blanket scan**. The job runs the `Reconciler`, which:

- scans **only** unreconciled provenance rows (never all unassigned conversations), in bounded
  batches;
- is guarded by a `wijaya_deferred_reconciliation_runs` ledger keyed on a unique **generation**
  (the persisted run/cutoff/completion state) so a retry/re-enqueue **resumes** the same run
  instead of starting a second engine;
- claims each batch with **`FOR UPDATE SKIP LOCKED`** (the same primitive the native
  `AutoAssignment::AssignmentService` uses) and, in **one transaction**, classifies + registers +
  stamps `reconciled_at` + adds the batch's counts to the run row — so a row is stamped (and
  counted) **only after its disposition has committed**. A failed batch rolls back wholesale (row
  left unreconciled, counters untouched); a retried or duplicate job **resumes** from the remaining
  unreconciled rows without losing or double-counting work, and two concurrent jobs lock **disjoint**
  batches instead of colliding. The coalesced `ProcessInboxJob` is enqueued only **after** the batch
  commits, so a rolled-back batch leaves neither a phantom marker nor a phantom job.

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
count **transitions** (`no_eligible_agent → assigned`/`dropped`) rather than double-counting. Every
outcome is logged content-free (`conversation=<id> outcome=<...> reconciliation_generation=<gen>`) —
never message bodies or assignee names.

### Retry / deploy safety

`ReconciliationJob` uses a **bounded** `retry_on StandardError, attempts: 5` (consistent with the
app's job conventions, e.g. `Captain::Documents::PerformSyncJob`) — **not** an unbounded custom
loop. Each retry resumes the same generation from the still-unreconciled rows and increments
`retries`; a failed attempt increments `failed`. After attempts are exhausted the run stays
`running`, safe to re-enqueue later without rescanning completed batches.

**Deploy order** (so an old Sidekiq cannot consume the new job before the new code runs):

1. **Stop the old Sidekiq workers.**
2. **Run migrations using the new image** (`20260912000000`, `…000001`, `…000002`). The enqueue
   migration (`…000001`) queues `ReconciliationJob`, and `…000002` adds the correlation columns and
   the full counter set.
3. **Start the new workers**, which pick up the job with the corrected code.

On **this** install the initial run scans **zero** legacy rows (the provenance table is new), so it
is effectively a no-op here; the machinery is correct for any future re-deploy or for deletions that
accumulate a crash-gap provenance row going forward. Pre-feature deletions carry no provenance and
are never inferred from activity text.

## Limitation: pre-provenance legacy cases cannot be recovered automatically

Conversations that lost their assignee to a deletion that happened **before** this battery started
recording provenance have **no provenance row**. They are invisible to the reconciler and are
**never** guessed from free-text activity. This includes the current open-unassigned backlog. Such
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
