# Marine AI — Model 1 Structured Product Candidate (Step 2)

Date: 2026-10-02 · Branch: devbot · Scope: `custom/wijaya/batteries/marine_ai/` + one focused spec + this plan.

## Goal
Prove Model 1 (the battery-local `Marine::Decision::Runner`) can emit a structured,
product-related **candidate plan** that (1) conforms to the frozen Step 1 contract,
(2) retains candidate intents + product/variant slot operations + language through
normalization, (3) uses explicit scenario/capability configuration, (4) is structurally
consumable by `Marine::Backend::CandidatePlanToProductIntentAdapter`, and (5) stays
untrusted/non-authoritative — **without** wiring Model 1 to Backend Authority or any
customer-facing runtime.

## Root-cause audit (verified against source, not assumed)

**A. Does the closed CandidatePlan schema already represent a product candidate?** YES —
no schema change.
`Marine::Decision::Schema` already carries `scenario_candidate{key,confidence}`,
`intents` (closed allowlist incl. price/stock/parent_info/variant_info/catalog/product_overview),
`slot_operations` on the `product` and `variant_input` slots with `{raw_candidate,
candidate_type}` (product→display_name/family_code; variant_input→variant_code/display_label/
attribute_value), `customer_language`, `confidence`, `reason`. The backend adapter reads
exactly these fields (`normalized[:scenario_candidate][:key]`, `[:intents]`,
`[:slot_operations]{operation,slot,value{raw_candidate,candidate_type}}`, `[:confidence]`,
`[:customer_language]`). **Contract is sufficient; do not extend.**

**B. Why does `openrouter_decisions` lose slot_operations / language?** PROTOCOL
IMPOSSIBILITY — not a mapper/request/code bug.
Jev Decisions returns only typed primitives (`choice` / `noul`); it never generates free
text. `RequestBuilder#decisions_questions` therefore asks only a scenario CHOICE + per-intent
NOUL questions, and `DecisionsResponseMapper#map` hardcodes `slot_operations => []`,
`customer_language => nil` *by design*. A structured product/variant candidate is impossible
in this mode by construction. This is correct fail-safe behavior; do not change it.

**C. Why is the live scenario capability map empty?** MISSING OPERATOR CONFIGURATION — not a
code bug.
`ScenarioAdapter#scenarios` sources capabilities only from
`Marine::Decision::ShadowConfig.scenario_capabilities`, which reads InstallationConfig key
`MARINE_DECISION_SCENARIO_CAPABILITIES` and fails CLOSED to `{}` when unset/blank/malformed.
With the key unset, every scenario declares `[]` capabilities → the adapter rejects a
candidate as `capability_unconfigured`. The configuration surface exists and works; it is
simply unpopulated in the deployment. (Per the mandate, operator keys are reported, not
guessed/populated here.)

**D. Does a generic chat-completions structured-output path already support the full
CandidatePlan?** YES — reuse it.
The `chat_completions` mode (`RequestBuilder#chat_request` + closed `chat_schema`
incl. `slot_operations_schema` with per-slot write variants carrying `raw_candidate`+
`candidate_type`, + `customer_language`; `ChatResponseParser`; `ChatCompletionsClient#with_schema`)
already produces a full structured product candidate. `Runner#interpret → ChatResponseParser →
enforce_chat_scenario_allowlist! → normalize(intersect_capabilities)` already round-trips it.
No provider/client architecture change. Any mode selection stays config-driven
(`SettingsStore#api_mode`, default `chat_completions`).

**E. Which product intents exist and are adapter-accepted?** `Schema::INTENTS` =
price, stock, parent_info, variant_info, catalog, product_overview, order_status, sample,
unsupported. The adapter's `SUPPORTED_INTENTS` = `IntentExtractor::ALLOWED_PRODUCT_INTENTS`
(price/stock/parent_info/variant_info/catalog/product_overview); order_status/sample/unsupported
fail closed. No new business intents added.

## Conclusion: the capability already exists in code
End-to-end trace (chat mode, provider returns a product candidate with product family_code +
variant_code slots + `customer_language`, intents ⊆ scenario capabilities): the Runner
normalizes it losslessly to a deep-frozen `marine_decision_v1` plan, and
`CandidatePlanToProductIntentAdapter` ACCEPTS it with a matching configured capability map,
yielding `family_mention` / `explicit_child_code` / `customer_language` / `requires_exact_variant`
— with every slot staying a raw candidate (never a validated fact). **There is NO genuine code
gap.** The Step 2 deliverable is therefore a focused PROOF of this capability plus a precise
report that live enablement is bounded OPERATOR CONFIGURATION.

The genuine gaps are proof gaps: `runner_spec` only exercises chat with EMPTY slot_operations,
and `candidate_plan_to_product_intent_adapter_spec` builds its plan via
`CandidatePlan.normalize` directly, never from a Runner output. No existing spec proves the
Runner(chat) → normalized plan → Backend adapter round-trip for a *populated* product/variant
candidate.

## Changes (minimal)
1. NEW focused spec: `spec/custom/wijaya/batteries/marine_ai/decision/model1_structured_product_candidate_spec.rb`
   driving the real Runner (injected settings + client double; WebMock blocks network) and the
   real backend adapter, with SYNTHETIC values (`SYN-FAMILY`, `SYN-VARIANT-01`, `scenario_4242`).
   Proves: (#1) a product candidate is a valid plan; (#2) populated product+variant slots +
   language survive normalization + capability intersection; (#3) a slot/candidate stays raw and
   an injected authority field (top-level or inside a slot value) fails closed; (#4) malformed/
   unknown/unsupported structured output folds closed; (#5) capability intersection is config-
   driven and unconfigured/malformed maps fail closed at the adapter; (#6) the Runner's plan is
   accepted by `CandidatePlanToProductIntentAdapter` with a matching configured capability map and
   produces no repository call; (#8) a source scan proves the structured-candidate path activates
   no gate/shadow/cutover and wires nothing to Agent::Runner/ResponseBuilderJob/backend runtime.
2. Register the new spec in `custom/wijaya/patches/patch_registry.yml` (Stage 3 Runner group),
   following the established convention that battery spec files are inventoried there.

No app/service code changes. (#7 Decisions fallback/compat + openrouter empty-slot behavior are
already green in `runner_spec`/`decisions_response_mapper_spec`; left untouched.)

## Out of scope (forbidden)
No CandidateGate/Cutover/shadow/ProductAuthority activation; no flags/allowlists set; no
Agent::Runner/ResponseBuilderJob/customer-delivery/routing/core-hook changes; no Model 1→Backend
runtime wiring; no Planner/EvidencePacketBuilder/Presenter call; no Model 2; no Catalog/ERP/KB/
repository changes; no schema/normalizer relaxation; no hardcoded product/alias/phrase/price/
stock/scenario-id/product→intent mapping; no live DB/InstallationConfig/ENV mutation.

## Operator dependency (report only — do NOT set here)
To let Model 1 actually emit structured product candidates in a (future, separately-authorized)
runtime, the operator must:
- `MARINE_DECISION_LLM_API_MODE = chat_completions` (default already; must NOT be
  `openrouter_decisions`, which cannot emit slots/language).
- `MARINE_DECISION_SCENARIO_CAPABILITIES` = bounded JSON `{ "scenario_<id>": [<allowlisted
  intents>] }` for the scenarios that may execute product intents (empty/unset ⇒
  `capability_unconfigured`). Values are business config and are intentionally not guessed here.

## Verification
`WIJAYA_TEST_SERVICE=vite custom/wijaya/batteries/test_database_safety/bin/run_test_specs.sh
bundle exec rspec` on: the new spec; the full `decision` suite; the backend adapter + isolation
specs. Plus targeted RuboCop on the new file, `bash check_custom_patches.sh`, `git diff --check`,
and forbidden-reference scans.
