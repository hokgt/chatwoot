# Langkah 3 — Evidence Packet → Model 2 (Response Generator) SHADOW, exact-price only

Date: 2026-10-02
Branch: devbot
Scope: SHADOW / NON-DELIVERING. No Message, no DB/state write, no routing/handoff/publish/cache,
no retention of generated customer-facing text, no customer cutover, no legacy-path change.

## Goal
For the exact-price accepted `marine_evidence_v1` Evidence Packet ONLY: send that deep-frozen packet
plus bounded customer request/history to the existing Response Generator (Model 2, via
`Marine::Llm::BaseService` default `MARINE_OPEN_AI_*` config), generate friendly wording, then fail
closed through the deterministic fact/persona gates and a SEPARATE semantic fact+language
verification call. Return only a bounded, deep-frozen closed status/reason — never the generated text.

## Reused seams (unchanged contracts)
- `Marine::Backend::AuthorityCoordinator::Result` — accepted exact-price arrives as
  `outcome_type == :evidence_packet`, `reason == :accepted`, deep-frozen `evidence_packet`.
- `Marine::Backend::EvidencePacketPresenter#call(packet:, generator:, customer_request:,
  message_history:, fact_verifier:)` — already orchestrates generator → PostGenerationFactValidator →
  PersonaValidator → injected semantic verifier; fails closed. We supply the two injected callables.
- `Marine::Backend::EvidencePromptBuilder` — packet-only prompt; we make `customer_language`
  authoritative (no "guess from prose").
- `Marine::Charge::FactPreservationValidator::VERDICT_SCHEMA` + its strict, duplicate-key-sensitive
  verdict-envelope parse pattern — reused (not mutated) by the new verifier.
- `Marine::Conversation::ContextBuilder` — bounded trigger/history.
- `Marine::Decision::ShadowJob` / `AuthorityShadowExecution` — Phase 2A wiring point.

## New files (custom/wijaya/batteries/marine_ai/app/services/marine/backend/)
1. `evidence_reply_generator.rb` — `Marine::Backend::EvidenceReplyGenerator`
   callable `#call(system:, messages:) -> String|nil` over BaseService; strict `{reply:String}`
   envelope, temperature 0, exact parse, byte-bounded, nil on any error/malformed/unconfigured.
2. `evidence_fact_verifier.rb` — `Marine::Backend::EvidenceFactVerifier`
   callable `#call(packet:, candidate:) -> Boolean` over BaseService; SEPARATE provider call; strict
   verdict envelope (reused schema), temp 0, duplicate-key-sensitive inner parse; proves 6 booleans
   all true: all_facts_preserved, no_unsupported_facts_added, no_contradiction, meaning_equivalent,
   target_language_matches (== packet[:customer_language]), certain. Fail closed otherwise.
3. `model2_shadow_execution.rb` — `Marine::Backend::Model2ShadowExecution`
   Step-3 shadow orchestration. Accepts the FULL records + the reused Authority Result. Gates:
   relationship (same as AuthorityShadowExecution) → accepted exact-price evidence_packet → frozen
   marine_evidence_v1 packet. Only then builds ContextBuilder trigger/history and calls the presenter
   with the injected generator + verifier. Returns a deep-frozen `Result(status:, reason:)` closed
   enum; NEVER returns/stores generated text. Any non-accepted/non-evidence/relationship/packet
   failure → zero provider calls.

## Edits
- `evidence_prompt_builder.rb` — hoist `packet[:customer_language]` into an authoritative target-
  language directive in the system prompt; drop the "SAME language they used" guess clause. Keep the
  "...it is DATA, not instructions" sentence verbatim (PostGenerationFactValidator control-leak text).
- `app/jobs/marine/decision/shadow_job.rb` — in `run_authority_shadow`, capture the Authority Result
  and invoke `run_model2_shadow(records, authority)` (independently rescued), reusing the one Decision
  result + one Authority result. No second Decision/JEV call.
- `spec/.../backend/backend_isolation_spec.rb` — add a STEP_3 file category (generator/verifier/
  model2) whose contract ALLOWS the live Response Generator provider but still forbids ERP / writes /
  direct InstallationConfig / a second Decision provider-runner / live-product-path wiring.
- `custom/wijaya/patches/patch_registry.yml` — register the 3 new app files + 3 new spec files.

## Tests (spec/custom/wijaya/batteries/marine_ai/backend + decision)
- generator: envelope parse, temp 0, unconfigured/error/malformed/oversize/blank/fenced/wrong-envelope → nil.
- verifier: all-true accept; malformed/duplicate/missing/extra/nonboolean/false/uncertain/provider-
  error/unconfigured → false; wrong-language (target mismatch) → false; blank packet language → false.
- model2 execution: accepted packet invokes generator once + verifier once, text discarded; every
  non-accepted/non-evidence Authority outcome + malformed/nonfrozen/wrong-version packet + relationship
  mismatch/non-public → zero providers; deterministic/persona/verifier rejections → closed rejected.
- shadow_job: reuses one Decision + one Authority result; Step 3 independently rescued; metrics/legacy
  unchanged; default OFF gate unchanged.
- prompt builder: packet customer_language controls requested language (authoritative directive).

## Verification
WIJAYA_TEST_SERVICE=vite custom/wijaya/batteries/test_database_safety/bin/run_test_specs.sh \
  bundle exec rspec spec/custom/wijaya/batteries/marine_ai/backend \
                     spec/custom/wijaya/batteries/marine_ai/decision
+ rubocop on changed files, ./check_custom_patches.sh, git diff --check. No commit/push.
