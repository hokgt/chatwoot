# Deferred Auto-Assignment — Historical Backfill (operator guide)

One-time, operator-invoked mechanism to reassign conversations that became **open +
unassigned before the agent-deletion bridge existed** (so they carry no deferred marker).
It is **additive**: the live new-conversation path, the agent-deletion bridge, eligibility,
the native selector, capacity/presence/round-robin, locks, and ERP owner sync are unchanged.

**Dry-run is the default. Nothing mutates without `MODE=apply`, an explicit allowlist, and `APPLY=1`.**

## Canonical operator interface

There is **one** operator entry point — a battery-owned runner script driven by environment
variables (no rake task, no ad-hoc console snippet):

```bash
bundle exec rails runner custom/wijaya/batteries/deferred_auto_assignment/bin/historical_backfill.rb
```

Behaviour is selected by `MODE` (absent or `MODE=discover` → read-only discovery, the default;
`MODE=apply` → guarded apply). An unknown `MODE` or invalid params **fail closed** (non-zero exit,
nothing enqueued).

## 1. Discover (dry-run, provably read-only)

Full discovery for an account (bounded by `LIMIT`, default 100, max 500):

```bash
ACCOUNT_ID=<id> [LIMIT=<n>] [INBOX_ID=<id>] \
  bundle exec rails runner custom/wijaya/batteries/deferred_auto_assignment/bin/historical_backfill.rb
```

Preview an exact proposed allowlist (reports marker presence + live `deferrable?`):

```bash
ACCOUNT_ID=<id> CONVERSATION_IDS=101,102,103 \
  bundle exec rails runner custom/wijaya/batteries/deferred_auto_assignment/bin/historical_backfill.rb
```

Each candidate reports: conversation/account/inbox/team ids, current assignee, status, bot
ownership, marker presence, created/updated timestamps, latest **assignment-related activity**
(a staff-facing system event — never customer message bodies), an *apparent* target
classification (`current_agent` / `current_team` / `deleted_or_unknown` / `ambiguous`, a
best-effort label, never authoritative), linked ERP Lead presence, and the current
`Eligibility.deferrable?` result. Free text is evidence only — it never drives approval, and
no discovery result flows into apply automatically.

## 2. Apply (explicit allowlist, requires `MODE=apply` + `APPLY=1`)

```bash
MODE=apply APPLY=1 ACCOUNT_ID=<id> CONVERSATION_IDS=101,102,103 \
  bundle exec rails runner custom/wijaya/batteries/deferred_auto_assignment/bin/historical_backfill.rb
```

- Requires `MODE=apply` **and** `APPLY=1` **and** a non-empty `CONVERSATION_IDS`; anything else fails closed.
- Fails closed on a missing/empty `CONVERSATION_IDS`.
- Cross-account and non-existent ids are rejected **distinctly** and never enqueued.
- Bounded to `MAX_BATCH` (500) ids, dispatched as **one** `BackfillJob` (no per-id fan-out).

Apply enqueues bounded background processing that runs the exact live pipeline:

```
BackfillJob -> Registrar.register_unassigned_historical
            -> (per id) Eligibility.deferrable? recheck -> Marker (unique conversation_id)
            -> ProcessInboxJob (coalesced per inbox)
            -> InboxProcessor (row-locked recheck) -> native AutoAssignment::AgentAssignmentService
            -> conversation.update! -> existing ERP owner-sync callback (only if a lead is linked)
```

Idempotent: re-running is safe (unique `conversation_id`, per-id eligibility recheck, existing
per-inbox coalescing). An already-assigned / manually-assigned / resolved / bot-owned / deleted
conversation is skipped; a still-eligible one with no agent available keeps its marker for a
later availability/presence trigger, exactly like the live path.

## Notes

- **No new schema** — reuses the existing `wijaya_deferred_assignments` marker table.
- **No recurring job / no blanket scan** — the allowlist (or bounded discovery) is the entire work-list.
- **No new ERP path** — assignment flows through the existing `after_update_commit` owner-sync callback.
