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
- stamps every examined row `reconciled_at` so it is processed **at most once**.

For each provenance row it **fails closed**:

| Category | Meaning |
|----------|---------|
| **ambiguous** (never registered) | conversation missing; account mismatch (cross-account safety); event is not a recorded agent deletion; conversation created at/after the cutoff; **prior agent is still an account member** (not actually deleted) |
| **skipped** (proven orphan, not currently actionable) | already carries a marker (live pipeline owns it); not currently `Eligibility.deferrable?` (resolved/snoozed/pending, already manually or bot-assigned, team auto-assign off, V2, inbox gone) |
| **registered** | proven deleted-agent orphan **and** deferrable **and** markerless **and** same-account **and** created before cutoff |

Registration goes through `Registrar.register_unassigned_from_provenance`, which shares the exact
live pipeline and **never writes `assignee_id` directly**:

```
Reconciler -> Registrar.register_unassigned_from_provenance
           -> (per id) Marker exists? skip  |  Eligibility.deferrable? recheck
           -> Marker (unique conversation_id)
           -> ProcessInboxJob (coalesced per inbox)
           -> InboxProcessor (row-locked recheck) -> native AutoAssignment::AgentAssignmentService
           -> conversation.update! -> existing ERP owner-sync callback (only if a lead is linked)
```

A manual assignment made before reconciliation is never overwritten (assignee-present rows are not
deferrable, and the row-locked recheck in `InboxProcessor` re-verifies immediately before writing).

### Observability

The `Reconciler` records accurate, content-free run counters on the ledger and logs them:
`scanned / registered / skipped / ambiguous`. The **assignment outcome** (assigned / no eligible
agent, marker retained / dropped) is produced asynchronously by the shared `InboxProcessor`, which
logs it per marker (`conversation=<id> outcome=<...>`, no message content). The reconciler does not
fabricate async assignment counts it cannot truthfully know.

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
