# Marine Product Catalog — Phase 7 Release Readiness

Cross-flow hardening and release-readiness summary for the deterministic product-catalog
delivery feature (Phases 1–6, hardened by Phase 7). This document is Marine-owned and adds
no runtime behavior. It records what has been **verified from source** versus the
**operational/runtime gates that are unavailable in this environment**, and the rollback
posture. It is a report, not a runbook — it contains no deployment commands.

## Scope of the feature

A deterministic, fail-closed product path that runs BEFORE general RAG on a trigger-bound
incoming message: contextual intent extraction → approved-table-only catalog repositories →
a frozen decision/state plan (no side effects) → native outgoing text and, when a single
usable primary catalog exists for the validated family, ONE native Product Catalog
attachment reusing the existing document blob. No provider/channel API is called directly;
delivery is a native `Message` persist whose native callbacks own the send.

## Source verification (PASS)

Established by the committed Phase 1–6 specs plus the Phase 7 aggregate specs
(`catalog/product_flow_security_spec.rb`, `catalog/product_flow_regression_spec.rb`):

- **No raw stock quantity** crosses the PostgreSQL boundary or enters the plan, reply
  descriptor, customer text, flow state, logs, error, or message metadata — stock is a
  binary `available`/`empty`/`unavailable` status only. (stock_repository, reply_renderer,
  orchestrator, state_store; Phase 7 security spec asserts the SQL aggregates `actual_qty`
  and never projects it.)
- **Price** carries only the three approved fields (`price_list_rate`, `currency`, `uom`);
  a conflict fails closed to handoff, an incomplete tuple to unavailable.
- **Approved tables only.** Every external catalog query targets exactly
  `item` / `item_variant_attribute` / `item_price` / `price_list` / `bin`, is a single
  parameterized SELECT the connection guard accepts, and binds every client/policy value.
  (Phase 7 security spec drives the real repository SQL-builders and asserts the union.)
- **No direct provider/channel egress** in the product path. (Phase 7 security spec scans
  the shipped sources; reasoning goes only through the injected Marine LLM abstraction and
  delivery only through native `Message` persistence.)
- **Adversarial repository fields** (extra columns, injected numerics, SQL-ish strings)
  never reach the frozen plan or the customer text; the deterministic text map is
  exhaustive and fact-safe over every `ReplyRenderer::KINDS` kind. (Phase 7 regression spec.)
- **Cross-flow lifecycle**: duplicate/stale/takeover/resolved/snoozed suppression yields no
  output; family/intent switch clears stale variant/catalog markers; state expiry resets to
  a fresh flow; one catalog per flow; transactional finalization rolls back and leaves the
  claim retryable on any failure. (orchestrator, state_store, eligibility, processing_claim,
  response_builder_job specs.)
- **RAG / handoff / Copilot intact** — legacy 2-arg job path is byte-for-byte unchanged and
  the existing Cell/Charge/Circuit/Copilot suites are untouched.
- **Core diff zero** across `app/ config/ lib/ enterprise/ db/` (and battery frontend) for
  the entire Phase 1–7 range; every file lives under the battery + registry.

### Verified test counts (source-level, this environment)

Executed on 2026-08-13 against the uncommitted Phase 7 tree via the fail-closed test-database
wrapper (`custom/wijaya/batteries/test_database_safety/bin/run_test_specs.sh`, `RAILS_ENV=test`,
`chatwoot_test`). These are source/behavioral results only — no live catalog, channel, or runtime
proof (see the operational gates below).

- **Complete Marine suite** (`spec/custom/wijaya/batteries/marine_ai`): **886 examples, 0 failures,
  5 pending**. The 5 pending are the SOP extraction smoke examples in
  `documents/sop/extraction_smoke_spec.rb`, which `skip` because the OCR binaries (Poppler /
  Tesseract `eng+ind` / ImageMagick) are not installed in the base container. They are
  environment-gated skips, not failures.
- **Focused scenarios controller** (`controllers/scenarios_controller_spec.rb`): **17 examples,
  0 failures**.
- **Phase 7 aggregate** (`catalog/product_flow_security_spec.rb` +
  `catalog/product_flow_regression_spec.rb`): **11 examples, 0 failures**.
- **Static gates**: RuboCop clean (0 offenses) and `ruby -c` OK on every changed Ruby/spec file;
  `git diff --check` clean; `patch_registry.yml` parses as YAML; `check_custom_patches.sh` passes;
  the registry covers every Phase 7 file (the scenarios spec was already registered and is not
  duplicated); Core diff is zero for both the uncommitted Phase 7 change and the committed catalog
  range.

**Stale-test alignment (specs only, no runtime change).** The tool-reference examples in
`controllers/scenarios_controller_spec.rb` previously asserted a tool-resolution / 422-validation
contract that no longer exists. Marine custom-tool execution and reference paths are disabled by
design: `Marine::Scenario#resolve_tool_references` forces `tools` to `nil`, `resolved_tools` /
`agent_tools` return `[]`, and `validate_instruction_tools` is a no-op. The two examples were
realigned to assert this actual disabled-tool contract — a `tool://` reference is inert whether it
names an existing custom tool or an unknown one: the scenario is created, no tools are materialized
(`tools` is `nil`), and no `422` is raised. Only the specs changed; no controller, model, or service
runtime was modified.

## Operational / runtime gates (UNVERIFIED — unavailable here)

These are required for a true production GO and could **not** be exercised in this
environment. None were faked.

- **Live catalog runtime**: the read-only catalog DB is not configured and holds zero
  Product Catalog records. No live query, price, stock, or table-privilege verification
  occurred. `Config.configured?` is false; all catalog reads fail closed by design.
- **Native attachment smoke** against a real channel/blob store: not run.
- **Runtime/image SHA match**: the running image is stale relative to this branch; no push,
  deploy, migration, or restart was performed. No live verification occurred.
- **Async delivery-failure fallback**: intentionally **deferred**. Only the immediate
  transactional failure path is tested (a create failure rolls the finalization back and
  leaves the claim retryable). There is **no supported native interface** to observe an
  asynchronous outgoing-`Message` delivery failure and emit a text fallback, so
  `CatalogDeliveryStatusJob` is **not implemented**. This is the one known feature gap.

## Rollback posture

- **Commit order**: roll back **Phase 6 first, then Phase 5** — revert
  `2e55b4db1cceb4e72236f48953177f842dccac82` (native catalog delivery), then
  `0690dca9b6b2105c59ecb6032149379cc81d7920` (product orchestration runtime integration),
  via standard `git revert` in that order. No history rewrite.
- **No destructive JSON cleanup required.** Product flow state lives in an additive,
  Marine-owned namespace (`additional_attributes.wijaya_marine_ai.product_flow_v1`) that
  native code never reads; leaving it in place after a rollback is inert.
- **Queued three-arg job compatibility.** `ResponseBuilderJob#perform` keeps its optional
  third argument: a job enqueued by the new path (3 args) and a job enqueued before it
  (2 args, legacy RAG path) both remain valid across a rollback, so in-flight/queued jobs
  do not crash on either side of the transition.
- **Async job absent/deferred** — nothing to unwind for it.

## Verdict

**SOURCE-READY / operationally NO-GO (BLOCKED).**

Every source-level and behavioral contract the blueprint defines is verified green: the
complete Marine suite runs **886 examples, 0 failures, 5 environment-gated pending** (the OCR
smoke skips above), including the realigned scenarios controller specs. This is a source-level
PASS only; no live runtime was exercised. A production GO additionally requires push, a
Development deployment, live catalog
privileges/config/records, a native attachment smoke test, a matching runtime/image SHA,
and a rollback image — all explicitly prohibited or unavailable in this environment, plus
the deferred async delivery-failure fallback. Those remain the exact outstanding blockers.
