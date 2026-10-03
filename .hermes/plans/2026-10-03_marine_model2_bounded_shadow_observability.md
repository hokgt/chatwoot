# Marine Model 2 bounded shadow observability

Date: 2026-10-03
Branch: devbot
HEAD baseline: 37d6c1d274ce19ffeb8f3dc2c0dc42fff54ff0c0

## Goal / scope

Make the existing, DEFAULT-OFF, NON-DELIVERING Langkah 3 `Model2ShadowExecution` result
runtime-provable by adding ONLY a bounded, aggregate-only observability seam. The execution's
existing deep-frozen closed `Result(status, reason)` — currently computed and then DISCARDED by
`ShadowJob#run_model2_shadow` — is now projected to its two closed codes and counted in an
aggregate Redis store. Execution semantics are unchanged (byte-for-byte equivalent in meaning) and
the path remains non-delivering.

## Traced seam

```
Marine::Decision::ShadowJob#run_model2_shadow
  -> Marine::Backend::Model2ShadowExecution#call            (UNCHANGED) -> deep-frozen Result(status, reason)
  -> Marine::Backend::Model2ShadowObservation.build(result:) (NEW)       -> bounded {status, reason} projection
  -> Marine::Backend::Model2ShadowMetricsStore.record(obs)   (NEW)       -> aggregate integer counters
```

Idempotency: an independent job_id-only NX completion marker
(`marine:model2:shadow:done:v1:<job_id>`), reusing the exact pattern of the existing Decision
marker (`claim_marker` / `release_marker` helpers), so the Model 2 aggregate records at most once
per ActiveJob delivery without colliding with the Decision metric's marker.

## Files changed

- `custom/wijaya/batteries/marine_ai/app/services/marine/backend/model2_shadow_observation.rb` (NEW)
  - Projection. Trusts ONLY a genuine `Model2ShadowExecution::Result`; reads ONLY `#status` /
    `#reason`; validates the pair against `ALLOWED_PAIRS` (derived from the execution's own
    constants); raises `Invalid` on any non-Result / unknown status / out-of-contract reason /
    impossible pair. Frozen value exposing only `status` and `reason`.
- `custom/wijaya/batteries/marine_ai/app/services/marine/backend/model2_shadow_metrics_store.rb` (NEW)
  - Redis aggregate store. Date-only daily key `marine:model2:shadow:metrics:v1:YYYYMMDD` (NO
    account/assistant/conversation/message id). Fully-STATIC field allowlist: `total` + one
    `<status>.<reason>` per allowed pair. One MULTI (hincrby + 14-day TTL). `#snapshot` reads <=14
    explicit daily keys (no scan), merges non-negative integers, fails closed. No reset/destructive
    method. Every path fail-open (returns false / error snapshot, never raises into the job).
- `custom/wijaya/batteries/marine_ai/app/jobs/marine/decision/shadow_job.rb` (EDIT, additive)
  - `run_model2_shadow` now captures the Result and calls `record_model2_metrics`, which builds the
    projection and records once via the independent Model 2 marker. New
    `MODEL2_COMPLETION_KEY_PREFIX`. Still returns nil; every added step independently rescued.
- `custom/wijaya/patches/patch_registry.yml` (EDIT)
  - Added the two new battery files under the existing Langkah 3 `custom_files` block + a note.
- Specs (NEW/EDIT): see Tests.

## Fixed allowed status/reason pairs (closed enum, reused from the execution)

- `accepted`  -> `deliverable_wording`                                  (externally: `accepted.deliverable_wording`)
- `rejected`  -> `not_generatable`, `generation_failed`, `fact_rejected`, `persona_rejected`, `fact_unverified`, `invalid_packet`, `internal_error`
- `skipped`   -> `relationship_invalid`, `not_exact_price`, `invalid_packet`

`ALLOWED_PAIRS` is built from `Model2ShadowExecution::{STATUS_*, REASON_*, PRESENTER_REASON}` so the
projection and store can never drift from the vocabulary the execution emits; no new vocabulary is
invented. Required required-pair coverage (accepted / rejected.fact_rejected /
rejected.fact_unverified / rejected.generation_failed / skipped.not_exact_price /
skipped.invalid_packet) is a subset of this set and each is proven by a test.

## Privacy boundary (why it holds)

- The projection reads ONLY `Result#status` and `Result#reason` (both closed symbols). It accepts
  ONLY a genuine `Result` struct, so a broad/look-alike payload (a Hash carrying generated text) is
  rejected before any field is read.
- The store's field keyspace is fully STATIC (no dynamic component): a field is valid iff it is
  `total` or an enumerated `<status>.<reason>`. No customer/model text, price, currency, UOM,
  variant/product code, language, prompt, provider body, or exception can become a field.
- The Redis key is DATE-ONLY. No account/assistant/conversation/contact/message/customer identifier
  is used as a metrics dimension or stored value.
- The idempotency marker carries ONLY the ActiveJob `job_id` (a UUID), never a customer id.
- No logs/events/exception-tracker calls carrying forbidden data; every seam fail-open and silent.

## Tests

- `spec/.../backend/model2_shadow_observation_spec.rb` (NEW): one projection per required pair; all
  other valid pairs accepted; only status/reason exposed; fail-closed on non-Result / broad payload
  / look-alike / unknown status / bad reason / impossible pair.
- `spec/.../backend/model2_shadow_metrics_store_spec.rb` (NEW): one increment per required pair under
  the date-only key + 14-day TTL in one MULTI; static allowlist carries no id/price/code; record
  fails closed (no write) on out-of-contract / impossible observation; Redis failure -> false;
  snapshot reads exactly the explicit <=14 keys (no scan), merges, fails closed on bad field/value,
  deep-frozen; source-proof scan for forbidden tokens.
- `spec/.../decision/shadow_job_spec.rb` (EDIT, new describe): genuine Result projected and recorded
  once carrying only status/reason; raw Result never handed to the store; duplicate delivery records
  at most once under an independent job_id marker; Decision + Model 2 markers use distinct prefixes;
  non-Result fails closed without disturbing the Decision metric; store failure swallowed; nil
  authority result records nothing.

## Non-goals / invariants (unchanged)

- No change to `Model2ShadowExecution` decisions, `EvidencePacketPresenter`, prompt, validators,
  verifier, provider, Evidence Packet, JEV, Candidate Plan, Authority, repository, or legacy
  behavior.
- Capability map runtime left EMPTY and unconfigured.
- Decision shadow/cutover, Product Authority shadow/cutover, candidate mode all remain OFF;
  `CandidateGate` phase lock unchanged. No gate/config/env/seed/migration change.
- No core (OSS/enterprise) file edits.
- Customer delivery path unchanged; the shadow remains non-delivering and `perform` returns nil.

## Deploy verification checklist

- New + existing Step 3 specs green via `custom/wijaya/batteries/test_database_safety/bin/run_test_specs.sh`:
  evidence_prompt_builder, evidence_reply_generator, post_generation_fact_validator,
  evidence_fact_verifier, evidence_packet_presenter, model2_shadow_execution, model2_shadow_observation,
  model2_shadow_metrics_store, decision/shadow_job.
- RuboCop clean on changed Ruby/spec files.
- `bundle exec rails zeitwerk:check` (eager-load autoload-path sanity).
- `bash check_custom_patches.sh`.
- `git diff --check`.
- Static scan of changed production files for forbidden data fields and any
  configuration/capability/gate edit (none expected).
- No commit / push / deploy / container restart / migration performed (supervisor owns those).
