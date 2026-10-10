# Marine Phase 2 — exact-price end-to-end activation

## Scope and invariant

Activate only the already-authorized exact-variant price path. Model 1 remains an untrusted classifier; Backend Authority remains the sole repository/fact owner; Model 2 sees only a frozen `marine_evidence_v2` packet plus bounded canonical conversation context. Every uncertainty falls back to the unchanged legacy path. This phase does not use `CutoverGate`, does not read `MARINE_DECISION_SCENARIO_CAPABILITIES`, and does not create a global cutover.

## Checkpoint A — execution seam

Add a synchronous, side-effect-free battery service that:

1. validates account/assistant/conversation/public-incoming-message ownership before collaborators;
2. builds bounded canonical context and the complete enabled-scenario seam, rejecting empty/overflow;
3. calls `Decision::Runner` exactly once with `ExecutionPolicy::CLASSIFICATION_INTENTS`;
4. passes that same CandidatePlan to existing `AuthorityShadowExecution`;
5. accepts only a genuine accepted, policy-authorized exact-price coordinator result with a deeply frozen v2 packet, exact `answer_price` goals, and exactly one `:price` fact;
6. calls `EvidencePacketPresenter` with the existing generator and semantic verifier; and
7. returns only a deeply frozen closed result containing status, reason, and validated text (or fallback with nil text).

The seam creates no messages, state, metrics, logs, repository objects, or provider responses. Backend Authority alone owns repository access. Tighten the deterministic Model 2 fact guard so validated product code, variant code, amount, currency, and UOM must all survive literally.

## Checkpoint B — customer-facing job wiring

Wire one target attempt inside `ResponseBuilderJob` after claim ownership/eligibility and before the unchanged legacy `AssistantChatService` call. On nil/fallback/exception, run legacy locally. Keep final message creation, usage increment, and claim completion in the existing lock/transaction so exactly one outgoing message is possible. The delivery metadata identifies `marine_exact_price_evidence_v2` / `exact_price_target`; no second sender or state path is introduced.

## Fallback matrix

| Condition | Model 1 | Authority/repositories | Model 2 | Result |
| --- | ---: | ---: | ---: | --- |
| relationship invalid | 0 | 0 | 0 | legacy fallback |
| scenarios empty/overflow | 0 | 0 | 0 | legacy fallback |
| malformed/unauthorized/non-price/multi plan | 1 | bounded authority gate; facts 0 | 0 | legacy fallback |
| no match/range/clarify/handoff/repository failure | 1 | bounded authority attempt | 0 | legacy fallback |
| malformed/wrong-version/non-exact packet | 1 | 1 attempt | 0 | legacy fallback |
| generation/deterministic/persona/semantic rejection | 1 | 1 attempt | presenter only | legacy fallback |
| accepted exact price + presenter accepted | 1 | 1 attempt | generator + verifier | deliverable validated text |
| any exception | at most 1 | at most 1 | at most 1 | legacy fallback |

## Verification

Use only `custom/wijaya/batteries/test_database_safety/bin/run_test_specs.sh` for RSpec and RuboCop. Run the new focused spec, ResponseBuilderJob spec, isolation specs, existing backend/decision/product-authority regression, post-generation validator spec, RuboCop on changed Ruby, `bash check_custom_patches.sh`, and `git diff --check`. Specs use synthetic inputs and prove plan reuse, closed result shape, packet-only Model 2 input, zero-collaborator early exits, fallback, exactly-one delivery, and product/variant/price/currency/UOM integrity. Runtime acceptance uses a non-persistent synthetic probe; no DB, InstallationConfig, ENV, provider, cutover, or gate mutation is permitted.
