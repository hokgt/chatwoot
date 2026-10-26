# Marine AI Phase 2A — PRICE-ONLY JEV → Backend Authority Shadow Bridge

Date: 2026-10-02
Source HEAD: a6ce15ac1b (devbot). Design: /tmp/Marine_AI_Step_2_..._v1_2.{docx,md}.

## Scope (implementation readiness ONLY — NOT activation/cutover)

Default-OFF, read-only, PRICE-ONLY bridge from the already-computed JEV CandidatePlan
(reused from `Decision::ShadowExecution`) to the Backend Authority, inside the existing
Decision shadow job, behind the existing `ShadowConfig.enabled_for?` gate. No new runtime
flag. No customer output, no Model 2, no state write, no second provider/Runner call, no
gate/config change. `CandidateGate::PHASE_LOCKED` stays true; Shadow/Cutover stay OFF.

Technical allowlist: adapter-authorized intents EXACTLY `["price"]`. Every other single
intent and every multi-intent (incl. price+stock) returns bounded
`legacy_preserved/phase_not_executable` BEFORE any fact repository call. `order_status /
sample / unsupported` fail closed at the adapter. StockRepository is never called.

## New files (battery `custom/wijaya/batteries/marine_ai/app/services/marine/backend/`)

1. `catalog_candidate_resolver.rb` — `Marine::Backend::CatalogCandidateResolver`
   - Bounded candidate generation (MAX 32 = Schema::MAX_RAW_ARRAY; each <= 120 bytes =
     Schema::MAX_RAW_CANDIDATE_LENGTH). Deterministic order: full trigger → single tokens
     (punctuation preserved) → multi-token spans longest-first, deduped, original-order
     tie-break. Neither bound can yield a false pick: count overflow is NEVER truncated — once
     the complete allowed set would exceed MAX_CANDIDATES it fails closed to
     `candidate_context_insufficient` rather than resolve from a partial set; an over-120-byte
     value is DROPPED (never prefix-sliced into a different identifier) and is anyway unmatchable
     because the resolver and the batched repositories enforce the SAME 120-byte structural bound.
   - Batched parameterized exact lookup (single SELECT, IN-list binds; no N-query).
   - §7.4 precedence (grounded in ProductQueryOrchestrator#family_decision /
     #resolved_variant_code): current exact family wins; switch never reuses stale variant;
     same current family may reuse revalidated saved child only when no current child; state
     family usable only when a current exact child resolves under it; otherwise
     `no_catalog_match`/`candidate_context_insufficient`. State is never sole family authority.
   - One-token display-name collision guard: a single-token NAME match is authoritative only
     when it equals the whole normalized turn; single-token CODE match always authoritative;
     multi-token name match authoritative.
   - Closed deep-frozen Result: status (exact_family|exact_child|ambiguous|no_catalog_match|
     unavailable), source (current_turn|flow_state|none), family_code, family_name, child_code,
     reason. No raw text/rows/lists.

2. `family_price_range_authority.rb` — `Marine::Backend::FamilyPriceRangeAuthority`
   - Thin read-only wrapper over `PriceRangeRepository#range_for`. Bounded immutable canonical
     result {status, min, max, currency, uom, source, checked_at}; source/checked_at stamped
     by the adapter. :unavailable/:conflict → range_unavailable; outage → catalog_unavailable.

3. `authority_coordinator.rb` — `Marine::Backend::AuthorityCoordinator`
   - `call(candidate_plan:, scenario_key:, scenario_capabilities:, trigger:, history:, phase:,
     flow_state:, configured_language:)`.
   - Uses `CandidatePlanToProductIntentAdapter` for schema/scenario/intent/capability
     authorization (never mutates its Result); then enforces exact `["price"]`.
   - Builds a FRESH IntentExtractor-shaped planner input sourced only from the resolver /
     revalidated state / language resolver (family_mention<-resolver.family_code,
     explicit_child_code<-resolver.child_code, attribute_candidates<-[], customer_language<-
     language resolver, intent<-"price", requested_intents<-["price"],
     requires_exact_variant<-true, quantity_inquiry<-false). JEV slot_operations never source it.
   - Resolves language via `ConversationLanguageResolver` BEFORE the planner; nil language on
     exact-price => handoff/language_unresolved (no silent EN/ID).
   - Dispatch: exact family+child → ProductExecutionPlanner → EvidencePacketBuilder
     (evidence_packet); exact family-only → FamilyPriceRangeAuthority (family_price_range);
     ambiguous → clarify; outage → handoff; no-match → legacy_preserved.
   - Closed deep-frozen Result (outcome_type / reason / scenario_key / intents / source /
     evidence_packet?/price_range? at most one). Reasons from §8 closed enum.

4. `authority_shadow_execution.rb` — `Marine::Backend::AuthorityShadowExecution`
   - `new(account:, assistant:, conversation:, message:, candidate_plan:).call`.
   - Revalidates scoped relationship + public-incoming (same as Decision::ShadowExecution).
   - Rebuilds ContextBuilder only (no Runner). Reads `ProductFlowStateStore#current_for_planning`
     only. Loads `ShadowConfig.scenario_capabilities`.
   - Accepts only medium/high candidate confidence using public
     `CutoverScenarioSelector::ACCEPT_CONFIDENCE` + `Schema` constants (no private selector call,
     no Runner, no provider). Resolves the enabled scenario via `ScenarioResolver`.
   - Calls the coordinator; returns only the bounded immutable Result.

## Modified files

- `app/jobs/marine/decision/shadow_job.rb` — additive, independently-rescued hook AFTER
  `record_metrics(records, result)`, inside `enabled_for?`, reusing `result[:candidate_plan]`
  (NO second Runner/provider call). Existing metrics signature/behavior unchanged.
- `app/services/marine/catalog/product_family_repository.rb` — `#resolve_exact_any(candidates)`
  (exact item_code OR case-insensitive exact item_name, active templates, batched, LIMIT 2).
- `app/services/marine/catalog/variant_repository.rb` — `#resolve_child_any(family_code,
  candidates)` (exact active child item_code only, batched, LIMIT 2).

No adapter/planner/builder/presenter signatures change. No core Chatwoot file touched (the hook
lives inside the battery), so no WIJAYA_CUSTOM markers and no core_hook_touchpoints entry.

## Registry

`custom/wijaya/patches/patch_registry.yml` marine_ai: the 4 new service files are added to
`custom_files`, and the 5 new spec files
(`backend/catalog_candidate_resolver_spec.rb`, `backend/family_price_range_authority_spec.rb`,
`backend/authority_coordinator_spec.rb`, `backend/authority_shadow_execution_spec.rb`,
`catalog/resolve_any_spec.rb`) are added to the `tests:` list (the registry schema uses `tests:`,
not `test_files`). The edited `shadow_job.rb`, `product_family_repository.rb`,
`variant_repository.rb`, `backend/backend_isolation_spec.rb`,
`decision/shadow_job_spec.rb`, and `product_authority/product_authority_isolation_spec.rb` are
already-registered battery files and are not re-listed. `check_custom_patches.sh` (repo root)
tracks only a curated marker subset of CORE touchpoints and does not enumerate battery services,
so it needs no edit (this feature adds no core touchpoint; the hook lives inside the battery).

## Tests (synthetic only; safety wrapper)

Focused specs under `spec/custom/wijaya/batteries/marine_ai/backend/`:
`catalog_candidate_resolver_spec.rb`, `family_price_range_authority_spec.rb`,
`authority_coordinator_spec.rb`, `authority_shadow_execution_spec.rb`; repo method specs folded
into new `*_resolve_any_spec.rb`; shadow_job hook assertions appended to the decision spec area
via `authority_shadow_execution_spec.rb` + a focused `shadow_job` hook example.

Delivered coverage (synthetic doubles only):

- `catalog_candidate_resolver_spec.rb`: blank-trigger short-circuit; deterministic bounded
  generation (full trigger → tokens → longest-first spans, punctuation preserved, within the byte
  budget); **overflow fails closed** — a >31-token turn (full+tokens already over the cap) AND a
  span-driven overflow both return `no_catalog_match`/`candidate_context_insufficient` with NO
  repository call (never a truncated family range/evidence); a short tail code still resolves when
  the complete set is within budget; an oversized candidate is DROPPED, never prefix-truncated;
  §7.4 precedence (exact current family by code/multi-token name; switch clears the stale variant;
  same family reuses a revalidated saved child; bare exact child under a revalidated state family;
  state never sole family authority → candidate_context_insufficient); one-token display-name
  collision guard; exact-child preference over range; ambiguous exact child fails closed;
  **saved-child revalidation ambiguity → variant_ambiguous (never the range)**; **state-family
  revalidation ambiguity → family_ambiguous (not no_catalog_match)**; family/child outage →
  unavailable; deep-frozen immutable Result.
- `resolve_any_spec.rb`: typed `resolved/missing/ambiguous/unavailable` outcomes; a SINGLE
  parameterized SELECT (no N-query); every candidate/family a bind (never interpolated); code OR
  case-insensitive name (family) and exact child code only (variant, never display/attribute);
  dedupe + cap at MAX_ANY_CANDIDATES; an over-120-**byte** multibyte candidate is dropped (byte,
  not char, bound), never sliced to a queryable prefix.
- `authority_coordinator_spec.rb`: adapter authorization fail-closed matrix; exact `["price"]`
  allowlist (every other single/multi intent + price+stock → `legacy_preserved`/
  `phase_not_executable` BEFORE any resolver/fact call — StockRepository never reached); fresh
  resolver-sourced planner input (JEV slot_operations never authoritative); language injection +
  nil fail-closed; exact family+child packet vs clean family-only range; planner handoff/clarify
  mapping; resolver fail-closed statuses; **unknown/malformed resolver status → stop/internal_error
  (never the range)**; collaborator failure → stop/internal_error; **deep-frozen intents array AND
  every intent String** (accepted price + multi-intent phase_not_executable).
- `family_price_range_authority_spec.rb`: available range canonical immutable result with the
  adapter-stamped (and **frozen**) source/checked_at; `:unavailable`/`:conflict` → range_unavailable;
  outage → `:outage`.
- `authority_shadow_execution_spec.rb`: plan reuse (no second Runner/ShadowExecution/provider);
  scoped relationship + public-incoming validation; medium/high canonical acceptance; enabled
  scenario re-resolution; read-only flow snapshot; returns only the bounded Result.
- `decision/shadow_job_spec.rb`: the hook runs AFTER the metrics attempt with the full records +
  reused plan; never a second Runner; an authority failure is swallowed without disturbing metrics;
  nil execution skips the hook.
- `backend/backend_isolation_spec.rb` + `product_authority/product_authority_isolation_spec.rb`:
  the Phase 2A files are held to the wired-but-read-only contract (no live provider/ERP/write/direct
  InstallationConfig/second Decision provider-Runner/live-path wiring); ShadowJob is the single new
  allowed Marine::Backend consumer.

Not separately asserted (documented scope limit, not a gap): adapter empty-slot handling and
one-Decision-provider-call-per-ShadowJob are owned by the existing `shadow_execution_spec.rb` /
`candidate_plan_to_product_intent_adapter_spec.rb`; this phase only proves the authority hook
reuses the already-computed plan.

RED first (classes/methods absent) → GREEN after implementation.

### Verify
```
WIJAYA_TEST_SERVICE=vite custom/wijaya/batteries/test_database_safety/bin/run_test_specs.sh \
  bundle exec rspec <new specs> ; then the broader backend/decision/catalog/conversation/
  product_authority dirs
bundle exec rubocop <changed ruby files>
bash check_custom_patches.sh   # repo-root curated check
git diff --check
```

## Activation exclusions (NOT in 2A)

P1 scenario→capability map approval; stock/availability typed safety; KB/RAG parity; catalog
attachment delivery; range→evidence vNext; Model 2 presenter + semantic/fact/persona validation;
dynamic listing visibility + producer/freshness; aggregate acceptance on Dev conversations. All
cutover gates stay OFF. CandidateGate PHASE_LOCKED stays true.
