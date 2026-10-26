# Marine AI MVP Refactor — Phase 1 / Opsi B Architecture Correction

**Status:** PLAN ONLY (uncommitted). No source/test/config/DB/runtime/commit/push/deploy action was taken to produce this document. All paths are repo-relative from `/home/stef/chatwoot`.
**Repo:** `/home/stef/chatwoot` · **Branch:** `devbot` · **Remote:** `git@github.com:hokgt/chatwoot.git`
**Scope:** battery-local Marine (`custom/wijaya/batteries/marine_ai/`), shadow/non-delivering, PRICE-ONLY.
**Author task:** read-only architecture audit + decisive, implementation-ready plan (no alternatives left open).

Hard flags (restated, authoritative for this plan):

| Mutation | Phase 1 |
|---|---|
| Database mutation | **NO** |
| InstallationConfig mutation | **NO** |
| ENV addition | **NO** |
| Migration | **NO** |
| Seed | **NO** |
| Shadow activation | **NO** |
| Cutover activation | **NO** |

No `scenario_5 -> price` (or any deployed scenario id) is materialized anywhere. The prior
`scenario_5 -> price` approval is business approval only and is NOT consumed by this plan.

This revision makes every architecture choice FINAL. There are no 6-A/6-B options, no "modify-v1 vs
v2" question, and no "reviewer may choose" language. The design below is the single **proposed
implementation design for review** (the Opsi B architecture itself was previously approved; this
artifact proposes its Phase-1 implementation and is submitted for a blocking read-only review before
any code is written).

---

## 1. Executive Summary

Today the Marine backend derives **execution authorization** from a per-scenario capability map
(`Scenario -> Capability`). That map is read from `MARINE_DECISION_SCENARIO_CAPABILITIES`
(`ShadowConfig.scenario_capabilities`), injected into every scenario the Decision Maker (Model 1)
sees, and then used as the authorization gate in four independent places: the Product Authority Seam
adapter, the `AuthorityCoordinator`, the `ProductExecutionPlanner`, and inside the Evidence Packet
schema itself. This couples *what the backend may execute* to *scenario configuration*, which is the
dependency Opsi B corrects.

Target chain (no scenario capability mapping):

```
Scenario                → identity / context / provenance only (scenario_<id> key + description/instruction)
Candidate Intent (M1)   → untrusted classification over the policy-derived classification vocabulary
Backend ExecutionPolicy → the ONLY execution authorization; Phase 1 executable == exactly ["price"]
Backend Authority       → fact validation + execution (Exact Price Authority → Evidence Packet → Model 2 shadow)
```

The single new unit of work is a tiny, **pure backend leaf**, battery-local
**`Marine::Backend::ExecutionPolicy`** owning the frozen executable set `["price"]` and the derived
classification set `["price", "unsupported"]`. It has NO production dependency on any other module
(not even `Marine::Decision::Schema`); its membership inside the Schema vocabulary is proven by its
spec, not enforced by a production alias. Every place that formerly consulted scenario capabilities —
both for
*backend execution authorization* AND for the *Model 1 classification vocabulary* — is re-grounded on
that one source. The misnamed scenario `capabilities` field is **removed entirely** (not repurposed)
from `ScenarioAdapter`, `InputContract`, `RequestBuilder`, the adapter `Result`, and the Evidence
Packet. Scenario keeps only identity/provenance (`scenario_<id>`), re-resolved to an ENABLED row by
`ScenarioResolver` exactly as today.

**Final decisions (no open design questions):**

1. **Model 1 classification vocabulary = policy-derived.** Both protocols offer exactly
   `["price", "unsupported"]` (executable `price` + the non-executable fallback `unsupported`). Neither
   protocol exposes `stock`/`catalog`/`order_status`/etc in Phase 1. `unsupported` is classification-only
   and can never pass backend execution authorization.
2. **Execution-policy owner = `Marine::Backend::ExecutionPolicy`** (a pure leaf), NOT
   `AuthorityCoordinator::PRICE_ONLY`, which would invert layering. Contract constants are
   `EXECUTABLE_INTENTS = %w[price]` and `CLASSIFICATION_INTENTS = (EXECUTABLE_INTENTS + %w[unsupported])`.
   `authorized?` requires the **exact canonical array** `intents == EXECUTABLE_INTENTS` — NO
   dedupe/sort/normalization, so a duplicated, reordered, or malformed direct call can never be
   normalized into authorization.
3. **Main-shadow composition root = `Marine::Decision::ShadowJob`** (the only production unit that already
   references both `Marine::Decision` and `Marine::Backend`). It injects
   `ExecutionPolicy::CLASSIFICATION_INTENTS` as a plain frozen array down
   `ShadowJob → ShadowExecution → Runner → InputContract/RequestBuilder`. No Decision-layer class gains a
   direct `Marine::Backend` constant reference (preserving isolation). Backend services ground directly on
   `ExecutionPolicy`. **One source of truth; zero duplicate allowlists.** `git grep` finds FOUR
   `Marine::Decision::Runner.new` sites plus ONE direct `InputContract.build` acceptance site that could
   consume the classification vocabulary. THREE Runner sites (main shadow, product-parity shadow, the
   direct structured-candidate proof spec) plus the one `InputContract.build` acceptance surface are the
   Phase-1 consumers and are each handled explicitly. The FOURTH Runner site — the default Decision Runner
   inside `cutover_scenario_selector.rb` — is **audited but INACTIVE in Phase 1** (cutover stays closed, so
   that lazy default Runner is never reached) and is therefore **VERIFY-ONLY / MUST-NOT-CHANGE**, not a
   modification (see §6.1 Consumer Inventory and §8.10). None is omitted.
4. **Evidence Packet = new version `marine_evidence_v2`.** Removing `scenario.capabilities` is a breaking
   closed-schema change; version honesty wins. The packet chain is ephemeral/in-process, so this is an
   **atomic in-tree switch with NO dual-read and NO compatibility projection**. The v1 string is retained
   only as a forbidden leak marker; current packet acceptance requires v2.

The chain stays **shadow / non-delivering**: it is reached only from
`Marine::Backend::AuthorityShadowExecution` (inside the default-OFF Decision shadow) and
`Marine::Backend::Model2ShadowExecution`, both of which produce no customer output and mutate no
state. This plan activates nothing.

---

## 2. Current Architecture & Call Flow

### 2.1 Where "scenario capabilities" originate and flow

Source of truth today = a per-scenario capability map keyed by `scenario_<id>`:

- `custom/wijaya/batteries/marine_ai/app/services/marine/decision/shadow_config.rb`
  - `CAPABILITIES_KEY = 'MARINE_DECISION_SCENARIO_CAPABILITIES'` (`:39`).
  - `scenario_capabilities` (`:99-103`) → `parse_capabilities` (`:113-122`) → `build_map`/`normalize_capabilities`
    (`:132-163`); fails CLOSED to frozen `EMPTY` on any anomaly.
  - `read(name)` (`:106-108`) → `Marine::Llm::Config.installation_value(name)`.
- `custom/wijaya/batteries/marine_ai/app/services/marine/llm/config.rb`
  - `installation_value(name)` (`:49-50`) → `InstallationConfig.find_by(name:)&.value.to_s` (read-only).

Config chain confirmed: `MARINE_DECISION_SCENARIO_CAPABILITIES → ShadowConfig.scenario_capabilities
→ Marine::Llm::Config.installation_value → InstallationConfig`.

### 2.2 Current call flow (price turn, shadow)

```
Marine::Decision::ShadowJob
  └─ Marine::Decision::ShadowExecution.new(**records)  → { legacy_scenario_key:, candidate_plan: }   (Model 1, untrusted)
       ├─ ScenarioAdapter#scenarios reads ShadowConfig.scenario_capabilities  (scenario_adapter.rb:43,57-65)  ◀── scenario→capability
       └─ Runner.new.call(...) → InputContract.build(... capabilities per scenario)                 ◀── scenario→capability (vocabulary)
  └─ Marine::Backend::AuthorityShadowExecution#call  (authority_shadow_execution.rb:51-57)
       ├─ scenario = ScenarioResolver.resolve(assistant:, key:)             (identity/provenance)
       ├─ scenario_key          = "scenario_#{scenario.id}"                 (:53)
       ├─ scenario_capabilities = ShadowConfig.scenario_capabilities        (:54)  ◀── scenario→capability
       └─ AuthorityCoordinator#call(candidate_plan:, scenario_key:, scenario_capabilities:, …)  (:51-57)
            authority_coordinator.rb:107-117
            ├─ Adapter#call(plan:, scenario_key:, scenario_capabilities:)   (:108)
            │     candidate_plan_to_product_intent_adapter.rb
            │     ├─ capabilities_for(map, key)                 (:79, :118-128)  ◀── scenario→capability
            │     └─ (intents - capabilities).empty?            (:88)            ◀── scenario→capability (AUTHZ)
            ├─ unless authorized.intents == PRICE_ONLY → phase_not_executable  (:33, :110)
            ├─ Resolver#call(trigger:, flow_state:)              (catalog identity, read-only)
            ├─ ProductExecutionPlanner#call(product_intent:, intents:, scenario:)
            │     product_execution_planner.rb
            │     └─ executable?(intents, scenario) → (intents - scenario[:capabilities]).empty?  (:91-98)  ◀── scenario→capability (AUTHZ)
            └─ EvidencePacketBuilder#build(evidence_input:)
                  evidence_packet_builder.rb
                  ├─ scenario = { key, intents, capabilities }  (:173-184)      ◀── scenario→capability IN SCHEMA
                  └─ raise invalid unless (intents - capabilities).empty?       (:181)  ◀── scenario→capability (AUTHZ)
  └─ Marine::Backend::Model2ShadowExecution#call                               (NON-DELIVERING shadow)
       model2_shadow_execution.rb:83-157
       ├─ accepted_exact_price? → OUTCOME_EVIDENCE_PACKET + REASON_ACCEPTED + result.intents == Coordinator::PRICE_ONLY + evidence_packet?  (:133-140)  ◀── coordinator allowlist
       ├─ valid_packet?         → frozen Hash && evidence_version == 'marine_evidence_v1'  (:145-147)
       ├─ exact_price_packet?   → response_goals == %w[answer_price] && facts.keys == %i[price]  (:154-157)
       └─ presenter → generator + deterministic fact gate + semantic verifier; returns {status, reason} ONLY (never text)
```

### 2.3 Model 1 (two protocols) today

- `InputContract` (`decision/input_contract.rb`): scenario entry closed keys
  `SCENARIO_ENTRY_KEYS = %w[key description instruction capabilities]` (`:34`), `MAX_SCENARIOS = 20`
  (`:44`), `MAX_CAPABILITIES = Schema::INTENTS.length` (`:47`), `ALWAYS_ALLOWED_INTENT = 'unsupported'`
  (`:52`). `capabilities` is a deduped subset of `Schema::INTENTS` (`:136-145`). The runner's
  **classification vocabulary** is `allowed_intents` = union of every scenario's `capabilities` +
  `'unsupported'` (`:68`, `:153-156`).
- `RequestBuilder` (`decision/request_builder.rb`): static `SYSTEM_PROMPT` (`:38-52`) forbids facts/
  actions. Chat mode: `intents_schema` enum = **full `Schema::INTENTS`** (`:117-120`); scenario envelope
  carries `{key, description, instruction, capabilities}` (`:205-212`). Decisions mode asks one `choice`
  scenario question + one `noul` question **per `allowed_intents`** (`:164-168`).
- `Runner` (`decision/runner.rb`): `intersect_capabilities(raw, input[:allowed_intents])` (`:143`,
  `:158-168`) drops any intent outside the vocabulary union before `CandidatePlan.normalize`;
  `enforce_chat_scenario_allowlist!` (`:120-130`) rejects an un-offered scenario key. Constructed by
  `ShadowExecution#candidate_plan` with no injected vocabulary (`shadow_execution.rb:88-90`).
- `DecisionsResponseMapper` (question mode): selects a scenario from offered keys, selects intents by
  NOUL threshold from `allowed_intents`; **`slot_operations` always `[]`, `customer_language` always
  `nil`** (`decisions_response_mapper.rb:46-47`) — question mode cannot emit arbitrary slot text.
- `ChatResponseParser` (structured chat mode): yields an untrusted hash; may carry raw candidate
  slot strings, but each stays a bounded `{raw_candidate, candidate_type}` (normalizer), never a fact.
- `ScenarioResolver` (`decision/scenario_resolver.rb`): re-queries `assistant.scenarios.enabled` by
  `scenario_<id>` at resolution time — the real row authority. Model 1's key is only a nomination.

Neither protocol derives authorization from Scenario today; the coupling is that the **classification
vocabulary** (`allowed_intents`) is the *union of per-scenario capabilities*.

### 2.4 ProductAuthority (Fase 3A-2) acceptance/parity — isolation

- `product_authority_isolation_spec.rb`: the live path (`Agent::Runner`,
  `Conversation::ResponseBuilderJob`, `Catalog::ProductQueryOrchestrator`, etc.) must have ZERO
  `'Marine::Backend'` references (`:14-26`). The ONLY permitted `Marine::Backend` namers are
  `app/services/marine/backend/**` plus the allowlisted product-authority files
  `product_authority/{shadow_execution,evaluator,acceptance_pipeline_coordinator,acceptance_case_result}.rb`
  and the **decision bridge** `app/jobs/marine/decision/shadow_job.rb` (`:35-55`).
- `candidate_gate.rb`: `PHASE_LOCKED = true` (`:36`); `#open?` returns `false` as its FIRST statement;
  no config can open it (`:81-90` in spec).
- **The acceptance pipeline folds PREBUILT `CandidatePlan`s through the Coordinator — it does NOT build
  a Decision `InputContract`.** `AcceptancePipelineCoordinator.run` feeds `Adapter → Planner →
  EvidencePacketBuilder` only (`acceptance_pipeline_coordinator.rb:9-11,31-33,95`); `Evaluator` and
  `AcceptanceRunner` likewise fold prebuilt plans. The capability map rides to those surfaces as
  `scenario_capabilities:` and is consumed ONLY by the adapter:
  - `acceptance_pipeline_coordinator.rb` `run(…, scenario_capabilities:, …)` (`:61`) →
    `@adapter.call(…, scenario_capabilities:)` (`:95`). No `InputContract`.
  - `evaluator.rb` `canonical_input` `{ …, capabilities: kase[:capabilities] }` (`:302-303`) →
    `run_coordinator` `scenario_capabilities: input[:capabilities]` (`:326`). No `InputContract`.
  - `acceptance_runner.rb` `scenario_capabilities: kase[:capabilities]` (`:170`), `executable_case?`
    requires `kase[:capabilities].is_a?(Hash)` (`:112-113`). No `InputContract`.
- **The ONLY `InputContract.build` acceptance surface is `parity/intake_adapters.rb` `ConversationIntake.adapt`**
  (`:55`), which builds the REAL `Marine::Decision::InputContract` with a synthetic scenario entry
  carrying `'capabilities' => Array(kase.dig(:capabilities, kase[:scenario_key]))` (`:91-97`). This is
  the sole ProductAuthority composition point that must receive the injected classification vocabulary;
  the parallel `case_input`/`run_coordinator` `scenario_capabilities:` plumbing (`:149-150,:306`) is a
  coordinator (adapter) path, not an `InputContract` path. `Evaluator#score_parity` drives this surface
  via `surface.adapt(turn)` (`evaluator.rb:272-274`, default `SURFACES`).
  - `corpus.rb`: each case declares `scenario_key:` + `capabilities: { 'scenario_<n>' => [...] }`
    (e.g. `:41` `%w[price stock]`, `:298` `capability_mismatch { 'scenario_1' => %w[stock] }`).

### 2.5 Mandatory audit — repository-authoritative fact sources (NOT scenario-capability consumers)

Two source units the reviewer explicitly required be audited. **Neither consumes scenario capabilities
and neither changes in Phase 1** (both are verify-only / must-not-change):

- **`Marine::Backend::CatalogCandidateResolver`** (`backend/catalog_candidate_resolver.rb`) resolves
  exact catalog identity BEFORE the planner using `Marine::Catalog::ProductFamilyRepository` and
  `Marine::Catalog::VariantRepository` (`:67-68`). It returns a closed status
  `exact_family`/`exact_child`/`ambiguous`/`no_catalog_match`/`unavailable`
  (`STATUS_* :44-48`; `:82-101`). It reads NO scenario-capability map and takes NO `scenario_capabilities`
  argument; an ambiguous/duplicate identity fails closed to `ambiguous`, a repository outage to
  `unavailable`, and an exact DB no-match to `no_catalog_match` (never "invalid"). It preserves
  **repository-authoritative exact identity** independent of intent authorization, so Opsi B leaves it
  byte-for-byte unchanged.
- **`Marine::Catalog::PriceRepository#price_for`** (`catalog/price_repository.rb:26-41`) is the SOLE
  exact-price fact source. It queries only the `'User Price'` price list (`USER_PRICE_LIST`, `:15`) with
  a general (no-customer) lookup and returns `{ status: :available, price_list_rate:, currency:, uom: }`,
  `{ status: :unavailable }`, or `{ status: :conflict }` (two+ tuples) (`:18-41`); a blank code
  short-circuits to `:unavailable` without a DB touch (`:28`). It reads NO scenario capabilities. It is
  must-not-change; its repository doubles must receive ZERO calls on any unauthorized intent (the planner
  fails closed BEFORE the price read — §8.2).

### 2.6 Model 2 validator chain (accurate classification)

`Model2ShadowExecution` (`backend/model2_shadow_execution.rb`) injects `EvidencePacketPresenter`
(`:70`, which owns generation + the deterministic fact/persona gates + the separate semantic
verification), `EvidenceReplyGenerator` (`:76`, the Model 2 provider wording), and `EvidenceFactVerifier`
(the semantic verifier). The deterministic leak gate is `PostGenerationFactValidator`. The full chain is
Presenter → Generator (Model 2) → `PostGenerationFactValidator` (deterministic fact/leak gate) →
`EvidenceFactVerifier` (semantic). Of these, only `EvidencePacketBuilder`, `EvidencePacketPresenter`,
`EvidencePromptBuilder`, and `Model2ShadowExecution` carry a real `EVIDENCE_VERSION` constant/check
(§5-E, §9).

---

## 3. Problem & Evidence

The `Scenario -> Capability` coupling exists in **two dimensions**: backend execution authorization
(five source sites) and the Model 1 classification vocabulary (the `InputContract` union).

**Backend execution-authorization coupling (five sites):**

1. **Config/provenance leak** — `shadow_config.rb:99-163` turns a config key into a per-scenario
   authorization map; `scenario_adapter.rb:43,57-65` stamps that map onto every scenario entry
   (`'capabilities' => Array(capabilities[key])`).
2. **Adapter authorization** — `candidate_plan_to_product_intent_adapter.rb:79-88` + `capabilities_for`
   (`:118-128`): plan intents authorized against the scenario's capability list
   (`(intents - capabilities).empty?`, `:88`); reasons `REASON_CAPABILITY_UNCONFIGURED/MALFORMED/MISMATCH`
   (`:54-56`).
3. **Coordinator gate** — `authority_coordinator.rb:33,110`: `PRICE_ONLY = %w[price]` is a second,
   independent allowlist in the orchestrator; it also threads `scenario_capabilities:` to the adapter
   (`:107-108`). `ADAPTER_FAILURE` (`:63-71`) encodes capability outcomes.
4. **Planner defense** — `product_execution_planner.rb:91-98`: `executable?` authorizes
   `(intents - scenario[:capabilities]).empty?` — a scenario-sourced capability array.
5. **Evidence Packet schema** — `evidence_packet_builder.rb:170-196`: the packet `scenario` block is
   `{ key, intents, capabilities }`, requires **non-empty** capabilities (`:189`), and enforces
   `(intents - capabilities).empty?` (`:181`). Authorization embedded in the presentation schema; the
   builder spec freezes this shape. `model2_shadow_execution.rb:137` additionally keys acceptance on
   `result.intents == Coordinator::PRICE_ONLY`.

**Model 1 classification-vocabulary coupling (one site):** `input_contract.rb:153-156`
(`allowed_intents` = union of scenario capabilities + `unsupported`), consumed by
`request_builder.rb` (chat enum is full `Schema::INTENTS`; decisions NOUL per `allowed_intents`) and
`runner.rb:143,158-168` (`intersect_capabilities`).

Consequence: whether the backend may answer a price turn — and what intents Model 1 may classify —
both depend on scenario configuration rather than a backend-owned policy. Opsi B requires
authorization AND the Phase-1 classification offer to be backend-policy-owned, and scenario to be
provenance-only.

**Honest limits preserved (not bugs to "fix"):**
- Model 1 already does NOT read execution authority from scenario; the only Model-1 coupling is the
  classification-vocabulary source.
- Decisions/question mode genuinely cannot emit arbitrary slot text (`decisions_response_mapper.rb:46-47`).
  The plan does not claim otherwise.

---

## 4. Target Phase 1 Architecture

```
Marine::Decision::ShadowJob  (COMPOSITION ROOT — references Marine::Decision AND Marine::Backend)
  reads  Marine::Backend::ExecutionPolicy::CLASSIFICATION_INTENTS  (== ["price","unsupported"])
  └─ ShadowExecution.new(**records, classification_intents: <frozen array>)   ← injected VALUE, not the constant
       └─ Runner.new(classification_intents: <frozen array>).call(...)
            └─ InputContract.build(... classification_intents: <frozen array>)  → allowed_intents == ["price","unsupported"]
            └─ RequestBuilder.build(...)  → chat intents enum == allowed_intents; decisions NOUL per allowed_intent; scenario carries NO capabilities
  └─ AuthorityShadowExecution#call
       ├─ scenario = ScenarioResolver.resolve(...)             → identity/provenance ONLY (scenario_<id>)
       └─ AuthorityCoordinator#call(candidate_plan:, scenario_key:, trigger:, history:, phase:, flow_state:, configured_language:)
            │                                                   (NO scenario_capabilities: parameter)
            ├─ Adapter#call(plan:, scenario_key:)               → untrusted translation; ExecutionPolicy.authorized? (exact ["price"])
            ├─ Resolver#call(...)                                → catalog identity (unchanged)
            ├─ ProductExecutionPlanner#call(... scenario: {key})→ executable? grounded on ExecutionPolicy (pre-repo fail-closed)
            └─ EvidencePacketBuilder#build(...)                  → marine_evidence_v2 scenario {key, intents}; the packet's COMPLETE top-level intents array must satisfy ExecutionPolicy.authorized? (exactly ["price"])
  └─ Model2ShadowExecution  → accepts ONLY a v2 exact-price packet; ExecutionPolicy.authorized?(result.intents); NON-DELIVERING {status,reason}
```

Single source of truth: **`Marine::Backend::ExecutionPolicy`** (a pure leaf; NO production dependency —
not on `Marine::Decision::Schema` nor anything else). Its membership inside the Schema vocabulary is a
spec assertion, not a production alias. Dependency direction is one-way:

```
Marine::Backend::ExecutionPolicy  →  (nothing; pure leaf. Schema-subset membership asserted in its spec only)
Marine::Backend::{adapter,coordinator,planner,builder,model2}  →  Marine::Backend::ExecutionPolicy   (direct)
Marine::ProductAuthority::ShadowExecution (allowlisted)  →  Marine::Backend::ExecutionPolicy   (direct; already names Backend)
Marine::Decision::ShadowJob (main-shadow composition root)  →  Marine::Backend::ExecutionPolicy  +  Marine::Decision::ShadowExecution
Marine::ProductAuthority::{Evaluator} (allowlisted)  →  Marine::Backend::ExecutionPolicy  (reads CLASSIFICATION_INTENTS, threads a plain Array into the parity intake)
Marine::Decision::{ShadowExecution,Runner,InputContract,RequestBuilder}  →  (receive a plain frozen Array; NO Marine::Backend reference)
Marine::Decision::CutoverScenarioSelector  →  (UNCHANGED in Phase 1 — audited INACTIVE default Runner site; its lazy default Runner is never reached while cutover stays closed; NO Marine::Backend reference)
Marine::ProductAuthority::{AcceptancePipelineCoordinator,AcceptanceRunner,corpus}  →  (NO Marine::Backend reference; fold prebuilt CandidatePlans and receive NO classification array)
Marine::ProductAuthority::parity/intake_adapters  →  (NO Marine::Backend reference; only this surface receives a plain classification Array, threaded in from Evaluator at the sole InputContract.build)
```

No Decision-layer class references `Marine::Backend`, so the ProductAuthority isolation allowlist is
unchanged (only `app/jobs/marine/decision/shadow_job.rb` — already allowlisted — and the backend
services name `Marine::Backend`). Scenario capabilities are gone from both the authorization path and
the classification-vocabulary path. Scenario identity/provenance (`scenario_<id>`) is preserved end to
end.

---

## 5. Execution Policy Decision

**Decision:** introduce the leaf module `Marine::Backend::ExecutionPolicy` as the one source of truth
for BOTH the executable set and the Phase-1 classification vocabulary. `AuthorityCoordinator::PRICE_ONLY`
is removed; nothing keeps an independent allowlist.

**Why a leaf (not `AuthorityCoordinator::PRICE_ONLY`):** the coordinator already references the adapter
(`authority_coordinator.rb:28`). If the adapter/planner/builder/model2 referenced
`AuthorityCoordinator::PRICE_ONLY`, those leaves would depend on the orchestrator (inverted layering +
const-resolution/load-order risk). The adapter, planner, and builder are also invoked **directly** by
the ProductAuthority acceptance harness via allowlisted seams; they must ground on a leaf policy without
pulling in the coordinator.

**Final contract:**
```ruby
# custom/wijaya/batteries/marine_ai/app/services/marine/backend/execution_policy.rb
module Marine::Backend::ExecutionPolicy
  # Phase 1: the ONLY executable intents. A frozen, closed vocabulary. No production alias/dependency
  # on Marine::Decision::Schema — membership inside Schema::INTENTS is asserted by this module's spec.
  EXECUTABLE_INTENTS = %w[price].freeze
  # The Phase-1 classification vocabulary offered to Model 1: executables + the non-executable
  # fallback. unsupported is classification-only and NEVER authorizes execution.
  CLASSIFICATION_INTENTS = (EXECUTABLE_INTENTS + %w[unsupported]).freeze

  module_function

  def executable_intents = EXECUTABLE_INTENTS         # immutable frozen projection
  def classification_intents = CLASSIFICATION_INTENTS # immutable frozen projection

  # Whole-set authorization (fail closed): the intent set must be the EXACT canonical executable array
  # — NOT a deduped/sorted subset. A duplicated (["price","price"]), reordered, empty, mixed, or
  # non-price set fails, so a malformed direct call can never be normalized into authorization. For
  # Phase 1 this is exactly ["price"].
  def authorized?(intents)
    intents == EXECUTABLE_INTENTS
  end

  # Single-intent membership, for fact-level defense in the planner / packet builder / model2.
  def executable?(intent) = EXECUTABLE_INTENTS.include?(intent)
end
```

**Dependency direction & immutability:** `ExecutionPolicy` is a **pure leaf** — it depends on nothing
(not even `Marine::Decision::Schema`); nothing depends back on it except through the public
constants/methods. Both constants are frozen and the projections return the frozen arrays, so callers
cannot mutate them and no per-call state exists. No cycles: coordinator→adapter and
coordinator→planner→builder all additionally →ExecutionPolicy (a leaf). Because authorization compares
against the exact canonical array, callers that legitimately hold a candidate set must pass it as-is;
the policy deliberately refuses to launder duplicates/reordering into a pass.

**Policy-derived classification, not a second allowlist:** the Model 1 vocabulary is NOT a new constant
— it IS `CLASSIFICATION_INTENTS`, injected (see §6). Production and acceptance both derive the
classification offer from this one constant; there is no duplicate list anywhere.

**The grounding points (same policy, no duplicate allowlists):**
1. **Candidate-intent filtering (adapter)** — authorizes translated intents via
   `ExecutionPolicy.authorized?` (replaces `(intents - capabilities).empty?`), whole-plan reject on
   failure (no partial execution).
2. **AuthorityCoordinator** — removes `PRICE_ONLY`/`== PRICE_ONLY` (`:33,:110`) and the
   `scenario_capabilities:` parameter; authorizes via `ExecutionPolicy`; `planner_input` stamps
   `requested_intents: ExecutionPolicy::EXECUTABLE_INTENTS.dup`.
3. **ProductExecutionPlanner defense** — `executable?` grounds on `ExecutionPolicy` (not
   `scenario[:capabilities]`); a direct call with empty/non-price/mixed intents fails closed BEFORE any
   repository read (guard already runs before `resolve_family`, `:70-72`).
4. **Evidence Packet validation (builder)** — rejects the packet unless its complete top-level `intents`
   set is `ExecutionPolicy.authorized?` (exact `["price"]`), NOT merely a per-member `executable?`
   check. The per-fact coherence checks (`ensure_coherent!`) are preserved as extra defense in depth, and
   a non-price fact still cannot ride in a price-only packet — but the authoritative gate is the
   whole-set `authorized?` on the packet's `intents`.
5. **Model2ShadowExecution** — replaces `result.intents == Coordinator::PRICE_ONLY` with
   `ExecutionPolicy.authorized?(result.intents)` (a backend service may name `ExecutionPolicy`).

**Membership validation (spec-only, not a production dependency):** `execution_policy_spec.rb` asserts
`(ExecutionPolicy::EXECUTABLE_INTENTS - Marine::Decision::Schema::INTENTS).empty?`,
`(ExecutionPolicy::CLASSIFICATION_INTENTS - Marine::Decision::Schema::INTENTS).empty?` (both policy
arrays are subsets of `Schema::INTENTS`), and
`ExecutionPolicy::CLASSIFICATION_INTENTS == %w[price unsupported]`, so the policy can never drift
outside the vocabulary — proven in the test, never aliased into the production leaf.

---

## 6. Model 1 Protocol Parity

**Core rule (final):** both protocols classify over exactly the policy-derived vocabulary
`["price", "unsupported"]` — nothing else is offered. Neither protocol derives authorization from
Scenario. Scenario becomes identity/context (key + description/instruction) with NO capabilities field.

### 6.1 Consumer Inventory (EXHAUSTIVE — every Runner / InputContract site)

`git grep "Marine::Decision::Runner.new"` and `grep InputContract.build` over
`custom/wijaya/batteries/marine_ai/` show EXACTLY these consumers of the classification vocabulary.
Each is handled and none is omitted. Four are Phase-1 modify/consume sites (A, B, D, E); ONE (site C,
the cutover selector's default Runner) is **VERIFY-ONLY / MUST-NOT-CHANGE** because, under the binding
closed-cutover Phase-1 constraint, its lazy default Runner is never reached:

| # | Site | Role | Phase-1 handling |
|---|---|---|---|
| A | `app/services/marine/decision/shadow_execution.rb:89` (`Marine::Decision::Runner.new`) | **Main Phase-1 Decision shadow** | Policy value injected `ShadowJob → Decision::ShadowExecution → Runner`. `Runner.new(classification_intents: @classification_intents)`. |
| B | `app/services/marine/product_authority/shadow_execution.rb:145` (`Marine::Decision::Runner.new`) | Allowlisted existing `Marine::Backend` consumer (product parity shadow) | **MODIFY:** remove the adapter's `scenario_capabilities: capability_map(scenarios)` argument (`:115`) and the `capability_map` helper (`:130-132`); construct `Marine::Decision::Runner.new(classification_intents: Marine::Backend::ExecutionPolicy::CLASSIFICATION_INTENTS)` (it already names `Marine::Backend`, so this is allowed). `ProductAuthority::ShadowJob` itself does NOT change. |
| C | `app/services/marine/decision/cutover_scenario_selector.rb:198` (`Marine::Decision::Runner.new`) | Customer-path scenario selection: `Agent::Runner` creates this selector, but its default `Marine::Decision::Runner` is **LAZY** and is reached ONLY after a nonblank query, `CutoverGate.open?`, a non-overflow scenario seam, and a non-empty seam | **VERIFY-ONLY / MUST-NOT-CHANGE.** There is NO concrete Phase-1 runtime or test dependency requiring this file to change. Phase 1 keeps cutover **closed** and never activates/configures it, so the selector's default Decision Runner is NOT part of the active Phase-1 runtime flow (gate closed ⇒ legacy selector runs directly; ScenarioAdapter/Decision Runner/metrics/provider are never touched). Do NOT thread `classification_intents:` here; do NOT modify this file, `agent/runner.rb`, or `CutoverGate`/`CutoverConfig`/activation state. The previous MODIFY classification came only from static Runner call-site/interface analysis, not a real dependency. VERIFY (read-only) the closed-gate short-circuit; any future policy injection to activate cutover is a FUTURE, separately-approved scope — not Phase 1. |
| D | `spec/custom/wijaya/batteries/marine_ai/decision/model1_structured_product_candidate_spec.rb:17` (`Marine::Decision::Runner.new(client:, settings:)`) | Direct Model 1 structured-candidate proof spec | **MODIFY:** construct `Runner.new(client:, settings:, classification_intents: Marine::Backend::ExecutionPolicy::CLASSIFICATION_INTENTS)` (the policy-derived list) so the proof runs over the Phase-1 vocabulary. |
| E | `app/services/marine/product_authority/parity/intake_adapters.rb:55` (`InputContract.build`, `ConversationIntake.adapt`) | **Sole ProductAuthority `InputContract` composition point** | **MODIFY:** drop the synthetic scenario `'capabilities'` entry (`:91-97`); pass the injected plain `classification_intents:` array (threaded in by the allowlisted `Evaluator`) to `InputContract.build`. Keeps ZERO `Marine::Backend` references. |

(Site C's default Runner is the only audited-but-INACTIVE/out-of-scope call site: it is listed for
completeness but is NOT a Phase-1 modification — see §8.10. All other `Runner.new` hits are
`Marine::Agent::Runner` — the live agent, out of scope — or unrelated test fakes; see §2.4 for the
Coordinator/Evaluator/AcceptanceRunner surfaces that fold prebuilt plans and therefore have NO
Runner/InputContract and receive NO classification array.)

**Injection design (main-shadow composition root = `ShadowJob`):**

```
ShadowJob#perform
  classification = Marine::Backend::ExecutionPolicy::CLASSIFICATION_INTENTS   # frozen ["price","unsupported"]
  Marine::Decision::ShadowExecution.new(**records, classification_intents: classification).call
```

`ShadowJob` is the only production unit that already references both namespaces (it calls
`Marine::Backend::AuthorityShadowExecution`) and is already on the isolation allowlist. It reads the
constant and passes the **array VALUE** onward — no downstream Decision class names `Marine::Backend`.

Exact signatures and fail-closed validation:

| Unit | New signature | Fail-closed behavior |
|---|---|---|
| `ShadowJob#perform` | `ShadowExecution.new(**records, classification_intents: Marine::Backend::ExecutionPolicy::CLASSIFICATION_INTENTS)` | n/a (constant is frozen & validated by the policy spec) |
| `ShadowExecution#initialize` | `initialize(account:, assistant:, conversation:, message:, classification_intents:)` | `#call` returns `nil` (no comparison) unless `@classification_intents` is a non-empty Array of Strings — never runs the Runner on a missing/garbage vocabulary |
| `ShadowExecution#candidate_plan` | `Marine::Decision::Runner.new(classification_intents: @classification_intents).call(message:, scenarios:, context:)` | — |
| `Runner#initialize` | `initialize(client: nil, settings: nil, classification_intents: nil)` | threads `@classification_intents` to `InputContract.build`; an invalid list raises `InputContract::Invalid`, which the Runner already folds to `malformed_response` (safe unknown plan) |
| `InputContract.build` | `build(message:, context:, state:, scenarios:, classification_intents:)` | `classification_intents` is validated like any contract input and REJECTS a missing / non-Array / non-String-member / unknown (not in `Schema::INTENTS`) / duplicate list → `Invalid` (NOT deduped). It preserves the injected canonical order as `allowed_intents`; the spec proves the production projection is exactly `["price","unsupported"]` |
| `RequestBuilder.build` | unchanged arity `(mode:, input:)`; consumes `input[:allowed_intents]` | chat `intents_schema` enum = `input[:allowed_intents]`; decisions NOUL questions already iterate `input[:allowed_intents]` |

**Acceptance/parity classification plumbing (accurate to source):** the ProductAuthority acceptance
pipeline folds PREBUILT `CandidatePlan`s through the Coordinator and does NOT build a Decision
`InputContract` (§2.4) — so `acceptance_pipeline_coordinator.rb`, `evaluator.rb`'s coordinator path, and
`acceptance_runner.rb` DO NOT inject a classification vocabulary; they simply DROP the
`scenario_capabilities:`/`capabilities` plumbing and let the adapter ground on `ExecutionPolicy`. The
**sole** acceptance surface that builds an `InputContract` is `parity/intake_adapters.rb`
`ConversationIntake.adapt` (`:55`), driven by `Evaluator#score_parity` via `surface.adapt(turn)`
(`evaluator.rb:272-274`). `Evaluator` is allowlisted (it may name `Marine::Backend`), so it reads
`Marine::Backend::ExecutionPolicy::CLASSIFICATION_INTENTS` and threads it as a **plain frozen array
parameter** into the parity surface; `parity/intake_adapters.rb` receives that plain array (replacing its
old scenario `'capabilities'` entry at `:91-97`) and keeps its ZERO `Marine::Backend` references intact.
There is no second classification list — acceptance derives from the same one constant.

| Aspect | Decisions / question mode (`decisions_response_mapper.rb`) | Structured chat mode (`chat_response_parser.rb`) |
|---|---|---|
| Vocabulary source | `allowed_intents` = injected `["price","unsupported"]` (policy-derived); one `choice` scenario question + one NOUL per allowed intent (`request_builder.rb:164-168`) | `intents_schema` enum = `input[:allowed_intents]` = `["price","unsupported"]` (`request_builder.rb:117-120`); `Runner#restrict_to_classification_vocabulary` filters to that list |
| Offered intents | EXACTLY `price`, `unsupported` (NOUL per intent). `stock`/`catalog`/`order_status`/etc NOT offered | EXACTLY `price`, `unsupported` in the enum. `stock`/`catalog`/`order_status`/etc NOT in the schema |
| Slot text | `slot_operations` always `[]`, `customer_language` always `nil` (`:46-47`) — cannot emit slot text (**unchanged**) | raw `{raw_candidate, candidate_type}` only; never a validated fact (**unchanged**) |
| Authorization from Scenario? | **No** — scenario key is a nomination; `ScenarioResolver` is the row authority; scenario carries no capabilities | **No** — static `SYSTEM_PROMPT` forbids facts; scenario text is DATA only |

Honesty constraints preserved: question mode's `slot_operations`/`customer_language` remain `[]`/`nil`;
`enforce_chat_scenario_allowlist!` (`runner.rb:120-130`) and the closed Normalizer vocabulary remain the
authority-smuggling guards. The `Runner#intersect_capabilities` helper is **renamed**
`restrict_to_classification_vocabulary` (same body: it intersects raw intents with
`input[:allowed_intents]`) so the name reflects policy/candidate-vocabulary semantics, not scenario
capabilities. No protocol is claimed to generate slot text it cannot.

A forged provider payload carrying `stock`/`order_status` is filtered out by
`restrict_to_classification_vocabulary` before normalization (chat), or is un-selectable because no NOUL
question exists for it (decisions); either way it never reaches a CandidatePlan. Any forged intent that
nonetheless reaches a CandidatePlan is rejected downstream fail-closed (§8).

---

## 7. Candidate Plan Changes

`Marine::Decision::CandidatePlan` / `Normalizer` / `Schema` stay **UNTRUSTED, CLOSED, and
MUST-NOT-CHANGE** — no change to the plan contract, closed key sets, or authority-smuggling rejection
(`schema.rb:64-67`, `candidate_plan.rb`, `normalizer.rb:196-200`). `Schema::INTENTS` **retains the full
future vocabulary** (`price stock parent_info variant_info catalog product_overview order_status sample
unsupported`); Phase 1 merely OFFERS a narrower subset via the injected classification list. A plan may
still only nominate a scenario key, candidate slot strings, intent categories, and a language hint.

The semantic contract change is at the **Product Authority Seam adapter**
(`custom/wijaya/batteries/marine_ai/app/services/marine/backend/candidate_plan_to_product_intent_adapter.rb`),
not in the plan schema:

- Remove the `scenario_capabilities:` keyword from `#call` (`:71`) and the `capabilities_for`
  helper (`:118-128`).
- Remove `REASON_CAPABILITY_UNCONFIGURED/MALFORMED/MISMATCH` (`:54-56`) and the capability branch at
  `:79-88` (keep `:72-77` schema-normalize + scenario-key provenance match; keep `:84-87` non-empty +
  `SUPPORTED_INTENTS` whole-plan reject).
- Add candidate-intent authorization grounded on `ExecutionPolicy.authorized?` (whole-plan reject, new
  closed reason `REASON_PHASE_NOT_EXECUTABLE` — opaque, allowlisted, never provider prose). A stock,
  mixed, or `order_status` set fails closed here; only the exact `["price"]` set is authorized.
- `Result.scenario` becomes provenance `{ key: }` only (drop `capabilities:`, `:141`). `product_intent`
  and `operations` shaping unchanged; slot candidates stay untrusted; `attribute_candidates` stays `[]`
  (exact-code-only authority).

Preserved: closed-schema normalization (`:98-102`), scenario-key format/provenance match (`:75-77`),
whole-plan rejection of non-product/mixed intents (`:87`), deep-immutable `Result`. A directly
constructed/forged `CandidatePlan` carrying `stock`/`mixed`/`order_status` is rejected at the adapter
(`SUPPORTED_INTENTS` and/or `authorized?`) BEFORE the resolver and any repository read.

---

## 8. Backend Authority Changes (defense in depth)

Defense in depth is strengthened, not removed. Every layer grounds on the ONE `ExecutionPolicy`.
All paths below are under `custom/wijaya/batteries/marine_ai/app/services/marine/backend/`.

**8.1 `authority_coordinator.rb`**
- Drop the `scenario_capabilities:` parameter from `#call` (`:107`); drop the `Adapter#call(…,
  scenario_capabilities:)` pass-through (`:108`).
- Remove `PRICE_ONLY = %w[price]` (`:33`) and `authorized.intents == PRICE_ONLY` (`:110`); authorize via
  `ExecutionPolicy.authorized?`. `planner_input` stamps `intent: 'price'` /
  `requested_intents: Marine::Backend::ExecutionPolicy::EXECUTABLE_INTENTS.dup` (`:191-192`).
- Simplify `ADAPTER_FAILURE` (`:63-71`): remove the three capability reasons; keep schema/scenario/intent
  terminal mappings; add the adapter's `REASON_PHASE_NOT_EXECUTABLE` terminal mapping.
- `self.stop`, `terminal`, `build`, deep-freeze behavior (`:88-245`) unchanged.

**8.2 `product_execution_planner.rb`**
- `executable?` (`:91-98`) authorizes `ExecutionPolicy.authorized?(intents)` instead of intersecting
  `scenario[:capabilities]`; keep the `SUPPORTED_INTENTS` subset check and the non-empty/array guards.
  The fail-closed guard stays BEFORE `resolve_family` (`:70-72`): a direct programmer call with
  empty/non-price/mixed intents returns a factless handoff before any repository read.
- `scenario` parameter is now provenance `{ key: }` (no `:capabilities` read). `Context`/`evidence_input`
  (`:87`, `:231-242`) carry `context.scenario` unchanged into the packet; update the doc comments at
  `:60-61,:90` that reference "scenario capabilities".
- Preserve repository re-resolution (`resolve_family`→`ProductFamilyRepository#resolve_exact`,
  `resolve_variant`→`VariantResolver`, `price_fact`→`PriceRepository#price_for` +
  `PriceDisplayFormatter`) and whole-plan handoff-on-any-missing-fact semantics (`:146-208`).

**8.3 `evidence_packet_builder.rb`** — new version `marine_evidence_v2` (see §9)
- `EVIDENCE_VERSION = 'marine_evidence_v2'.freeze` (`:26`).
- `scenario(scenario, intents)` (`:173-184`) becomes `{ key, intents }`: keep the
  `Schema::SCENARIO_KEY_PATTERN` validated key and the candidate `intents` (provenance). Remove the
  `capabilities` subkey, the `capabilities` helper (`:188-196`), the `(intents - capabilities).empty?`
  check (`:181`), `MAX_CAPABILITIES` (`:75`), and narrow `reject_unknown_keys!(scenario, %i[key])`
  (`:176`) so a `capabilities` subkey is rejected as unknown.
- Add policy grounding: reject the packet unless the **complete top-level `intents` set**
  (`build`'s `intents = intents(input[:intents])`, `:114`) is `ExecutionPolicy.authorized?` (exact
  `["price"]`) — NOT merely a per-member `executable?` pass. A stock/catalog/mixed intent set therefore
  fails closed at the whole-set gate. The per-fact coherence checks (`ensure_coherent!`, `:369-375`) are
  PRESERVED as extra defense — keep all fact/goal/intent/slot coherence checks (they key on top-level
  `intents`, not scenario).
- Every other field, bound, formatter-reconstruction, and deep-freeze/ceiling logic unchanged.

**8.4 `model2_shadow_execution.rb`**
- `EVIDENCE_VERSION = 'marine_evidence_v2'.freeze` (`:28`); `valid_packet?` (`:146`) requires v2.
- `accepted_exact_price?` (`:133-140`): replace `result.intents == Coordinator::PRICE_ONLY` with
  `Marine::Backend::ExecutionPolicy.authorized?(result.intents)` (exact `["price"]`). `OUTCOME_EVIDENCE_PACKET`
  + `REASON_ACCEPTED` + `evidence_packet?` unchanged.
- `exact_price_packet?` (`:154-157`) unchanged (`response_goals == %w[answer_price]` &&
  `facts.keys == %i[price]`). The non-delivering `{status, reason}` result, observation projection, and
  metrics store are untouched. Model 2 accepts ONLY a v2 exact-price packet and stays non-delivering.

**8.5 `authority_shadow_execution.rb`**
- Remove the `scenario_capabilities: Marine::Decision::ShadowConfig.scenario_capabilities` argument from
  the coordinator call (`:54`); keep `scenario_key: "scenario_#{scenario.id}"` (`:53`, provenance), and
  all relationship/acceptance/resolver gates (`:42-58`) unchanged. Update the class doc comment (`:19-20`)
  that mentions loading `ShadowConfig.scenario_capabilities`.

**8.6 `decision/scenario_adapter.rb`**
- `scenarios`/`entry` (`:42-65`) stop reading `ShadowConfig.scenario_capabilities` and stop stamping a
  per-scenario capabilities list. `entry` emits `{ 'key', 'description', 'instruction' }` only. Keep the
  overflow/ordering discipline (`:35-54`) and the `clean` bound. Update the class doc comment (`:14-16`).

**8.7 `decision/shadow_config.rb`**
- Remove `scenario_capabilities` (`:99-103`), `CAPABILITIES_KEY` (`:39`), `parse_capabilities`/
  `valid_root?`/`build_map`/`valid_key?`/`normalize_capabilities`/`allowed_capability?` (`:113-163`), and
  the capability-specific bounds/constants (`:46-57`). Keep `enabled?`/`enabled_for?`/`assistant_allowlist`
  and the assistant-id parsing (`:70-197`). `MARINE_DECISION_SCENARIO_CAPABILITIES` is simply no longer
  read (no DB touch).

**8.8 Evidence consumers — version flip to v2 (atomic, §9). Each classified from `git grep marine_evidence_v1`:**
- **Real production `EVIDENCE_VERSION` constants/checks** — flip to `'marine_evidence_v2'`:
  `evidence_packet_builder.rb:26`, `evidence_packet_presenter.rb:25` (+ assertion `:95`),
  `evidence_prompt_builder.rb:17` (+ assertion `:89` region), `model2_shadow_execution.rb:28`
  (+ `valid_packet?` `:146`). These are the ONLY four files with a production version constant/check.
- **`evidence_fact_verifier.rb` — NO production version constant/check.** The v1 string appears ONLY in
  class/doc comments (`:9,:57`); its spec serializes the packet and asserts the version STRING in the
  built prompt text (`evidence_fact_verifier_spec.rb:12,:54`). Handling: update the comments to v2 and
  update the spec fixture/assertion to v2, verifying the serialized **sole-fact-source** behavior — do
  NOT invent a nonexistent version constant/check in the production file.
- **`family_price_range_authority.rb` — v1 COMMENT only (`:9`).** Update the comment wording if desired;
  no behavior change, no constant.
- **`evidence_reply_generator.rb` — NO v1 literal in production.** Only the spec fixture carries it
  (`evidence_reply_generator_spec.rb:12` `'{"evidence_version":"marine_evidence_v1"}'`). Handling:
  update the **test fixture only** to v2.
- **`post_generation_fact_validator.rb:45` `LEAK_MARKERS`:** ADD `marine_evidence_v2`; KEEP
  `marine_evidence_v1` AND keep `capabilities` (and `canonical`) — all remain forbidden tokens in
  generated TEXT, independent of the packet key.
- `evidence_packet_presenter.rb` scenario handling is a Hash type-check only; confirm it tolerates the
  `{key, intents}` shape (verify, no logic change beyond the version string).
- **Spec fixtures that embed the version string** (not production): `authority_coordinator_spec.rb:119`,
  `evidence_packet_builder_spec.rb:56`, `model2_shadow_execution_spec.rb:41,:101,:111,:202`,
  `post_generation_fact_validator_spec.rb:84`, plus the three already named above — all flip to v2.

**8.9 `product_authority/shadow_execution.rb` (allowlisted Backend consumer — Runner site B)**
- Remove the `scenario_capabilities: capability_map(scenarios)` argument to the adapter (`:115`) and
  delete the `capability_map` helper (`:130-132`).
- Construct the Decision Runner with the policy classification:
  `@decision_runner ||= Marine::Decision::Runner.new(classification_intents: Marine::Backend::ExecutionPolicy::CLASSIFICATION_INTENTS)`
  (`:145`). This file already names `Marine::Backend` and is on the isolation allowlist, so the direct
  `ExecutionPolicy` reference is permitted.
- Update the doc comments at `:103-106,:128-129` that describe the "per-scenario capability map". The
  adapter still runs under the SAME legacy-selected `scenario_<id>` provenance key (`:113`).
  `ProductAuthority::ShadowJob` itself does NOT change.

**8.10 `decision/cutover_scenario_selector.rb` (customer-path selector — Runner site C; VERIFY-ONLY / MUST-NOT-CHANGE)**
- **Do NOT modify this file.** There is NO concrete Phase-1 runtime or test dependency requiring it to
  change. Verified evidence: `Marine::Agent::Runner` creates `CutoverScenarioSelector`, but the selector's
  default `Marine::Decision::Runner` is **LAZY** and is reached ONLY after a nonblank query,
  `CutoverGate.open?` returning true, a non-overflow scenario seam, and a non-empty seam
  (`cutover_scenario_selector.rb` header + `:198`). Phase 1 keeps cutover **closed** and never activates or
  configures it, so the default Decision Runner in this selector is NOT part of the active Phase-1 runtime
  flow. The previous MODIFY classification came only from static Runner call-site/interface analysis, not a
  concrete Phase-1 dependency. There is therefore NO optional `classification_intents:` keyword to add, and
  no absent→legacy threading to introduce in Phase 1.
- **Do NOT modify `custom/wijaya/batteries/marine_ai/app/services/marine/agent/runner.rb` for this
  dependency.** **Do NOT modify `decision/cutover_gate.rb` (`CutoverGate`), `decision/cutover_config.rb`,
  cutover configuration, or activation state.** No file in the live `Agent::Runner` path is touched for
  Phase 1.
- **VERIFY (read-only) the existing closed-gate path** prevents the `ScenarioAdapter` / default Decision
  Runner / metrics snapshot / provider work from running: with cutover closed, `CutoverGate.open?` is false,
  so `select` short-circuits to the byte-for-byte legacy selector BEFORE constructing or calling the default
  Runner (source confirms: "Query blank OR gate closed => the legacy selector runs directly; the
  ScenarioAdapter, the Decision Runner, the metrics snapshot … and the provider are NEVER touched").
- **Specs are VERIFY-ONLY, not test-change targets.** `cutover_scenario_selector_spec.rb` already injects a
  Runner double in its builder; the Agent specs stub the selector, exercise the closed-gate path, or assert
  the product flow never instantiates it. Do NOT add or change a selector spec (or any new/changed spec) to
  test optional policy threading or absent-vocabulary behavior — that behavior does not exist in Phase 1.
- Any future policy injection required to activate cutover (threading a classification vocabulary into the
  live customer path) is a **FUTURE, separately-approved scope** requiring a dedicated composition seam. It
  is a future-scope dependency, NOT a current Phase-1 blocker.

---

## 9. Evidence Packet Versioning Decision

**Current `marine_evidence_v1` shape** (`evidence_packet_builder.rb:132-145`): top-level
`evidence_version, generated_at, response_goals, scenario, validated_slots, facts, missing_slots,
variant_candidates, prohibited_claims, response_constraints` (+ optional `customer_language`). The
`scenario` block is `{ key, intents, capabilities }` (`:183`). A real `EVIDENCE_VERSION =
'marine_evidence_v1'` production constant exists in EXACTLY four files —
`evidence_packet_builder.rb:26`, `evidence_packet_presenter.rb:25`, `evidence_prompt_builder.rb:17`,
`model2_shadow_execution.rb:28` — asserted at presenter `:95`, prompt_builder `:89` region, model2
`:146`, and the builder spec. It is ALSO a leak marker in `post_generation_fact_validator.rb:45`. The
string additionally appears as **comments only** in `evidence_fact_verifier.rb` (`:9,:57`) and
`family_price_range_authority.rb` (`:9`), and in **spec fixtures only** for
`evidence_fact_verifier.rb`, `evidence_reply_generator.rb`, and several backend specs (§8.8). There is
NO production version constant in `evidence_fact_verifier.rb`, `evidence_reply_generator.rb`, or
`family_price_range_authority.rb`.

**Decision (final): new version `marine_evidence_v2`.** The `scenario` block becomes provenance
`{ key, intents }` (drop `capabilities`) and the builder gains the executable-fact check.

**Rationale:** removing `scenario.capabilities` and changing packet semantics is a breaking closed-schema
change. Version honesty — a different shape earns a different version string — outweighs the small
touch-surface savings of mutating v1 in place. Because the packet chain is **ephemeral / in-process**
(the builder has zero persistence; a packet lives only within a single shadow job invocation,
`AuthorityCoordinator::Result → Model2ShadowExecution`), there is NO stored packet and NO cross-version
reader. Therefore the switch is **atomic and in-tree with NO dual-read and NO compatibility projection**:
every producer/consumer/spec moves to v2 together, in one change. No separate persistent v1 reader/class
is created (source proves none exists).

**Atomic migration surface (all move together):**
- Producer: `evidence_packet_builder.rb` (`EVIDENCE_VERSION`, `scenario` block, drop
  `capabilities`/subset/`MAX_CAPABILITIES`, add executable-fact check).
- Production version-const consumers (flip const + assertion): `evidence_packet_presenter.rb`,
  `evidence_prompt_builder.rb`, `model2_shadow_execution.rb`. (`evidence_fact_verifier.rb` has NO
  production const — comments + spec fixture only; see §8.8.)
- Comment-only: `evidence_fact_verifier.rb` (`:9,:57`), `family_price_range_authority.rb` (`:9`) — update
  wording, no behavior/constant.
- Leak markers: `post_generation_fact_validator.rb:45` adds `marine_evidence_v2`, keeps
  `marine_evidence_v1` and `capabilities` (and `canonical`).
- Fixtures/specs (string embedded in test data — flip to v2): `evidence_packet_builder_spec.rb:56`,
  `evidence_packet_presenter_spec.rb:95`, `evidence_prompt_builder_spec.rb:35`,
  `evidence_fact_verifier_spec.rb:12,:54`, `evidence_reply_generator_spec.rb:12` (fixture only — no
  production change), `model2_shadow_execution_spec.rb:41,:101,:111,:202`,
  `authority_coordinator_spec.rb:119` packet fixture, `post_generation_fact_validator_spec.rb:84`, and the
  ProductAuthority specs/fixtures that build packets — all assert `marine_evidence_v2` and the
  `{key, intents}` scenario shape.

**Scenario provenance in the packet:** `scenario[:key]` is identity/provenance; `scenario[:intents]` is
the turn's candidate classification (provenance of what was asked, not authorization). Execution
authorization is entirely backend-policy-owned (§5) and no longer appears in the packet.

---

## 10. File-Level Change Plan

Legend: **M**=modify · **C**=create · **T**=test-only · **V**=verify-only · **N**=must-not-change. All
source paths are full repo-relative paths beginning `custom/wijaya/batteries/marine_ai/…`; registry
entries use repo-root script names.

### 10.1 Source — Backend (must-change / create)

| # | File | Kind | Responsibility / change | Reason | Test impact |
|---|---|---|---|---|---|
| 1 | `custom/wijaya/batteries/marine_ai/app/services/marine/backend/execution_policy.rb` | **C** | New leaf: frozen `EXECUTABLE_INTENTS=%w[price]`, `CLASSIFICATION_INTENTS=(EXECUTABLE_INTENTS+%w[unsupported])`, `executable_intents`, `classification_intents`, `authorized?` (exact set), `executable?` | Single source of truth for execution authz + Phase-1 classification | New `execution_policy_spec.rb` |
| 2 | `custom/wijaya/batteries/marine_ai/app/services/marine/backend/candidate_plan_to_product_intent_adapter.rb` | **M** | Drop `scenario_capabilities:`+`capabilities_for`+`REASON_CAPABILITY_*`; add `ExecutionPolicy.authorized?` with `REASON_PHASE_NOT_EXECUTABLE`; `Result.scenario`→`{key}` | Candidate-intent authz grounded on policy, not scenario | adapter spec, model1_structured_product_candidate spec |
| 3 | `custom/wijaya/batteries/marine_ai/app/services/marine/backend/authority_coordinator.rb` | **M** | Drop `scenario_capabilities:` param/pass-through; remove `PRICE_ONLY`; authorize via `ExecutionPolicy`; trim/retarget `ADAPTER_FAILURE`; `planner_input` uses `EXECUTABLE_INTENTS.dup` | Coordinator authorizes via the one policy | coordinator spec, pipeline integration spec |
| 4 | `custom/wijaya/batteries/marine_ai/app/services/marine/backend/product_execution_planner.rb` | **M** | `executable?` grounds on `ExecutionPolicy`; `scenario` param=`{key}` provenance; drop `:capabilities` read | Planner fails closed before repo read, policy-sourced | planner spec |
| 5 | `custom/wijaya/batteries/marine_ai/app/services/marine/backend/evidence_packet_builder.rb` | **M** | `EVIDENCE_VERSION`→`marine_evidence_v2`; `scenario`→`{key,intents}`; drop `capabilities`/subset/`MAX_CAPABILITIES`; require whole top-level intents exact policy authorization | v2 scenario provenance-only; policy-grounded packet | builder spec |
| 6 | `custom/wijaya/batteries/marine_ai/app/services/marine/backend/model2_shadow_execution.rb` | **M** | `EVIDENCE_VERSION`→v2; `result.intents == Coordinator::PRICE_ONLY`→`ExecutionPolicy.authorized?(result.intents)` | Accept only v2 exact-price; drop coordinator allowlist | model2 spec |
| 7 | `custom/wijaya/batteries/marine_ai/app/services/marine/backend/evidence_packet_presenter.rb` | **M** | `EVIDENCE_VERSION`→v2 (const `:25` + assertion `:85`) | v2 consumer | presenter spec |
| 8 | `custom/wijaya/batteries/marine_ai/app/services/marine/backend/evidence_prompt_builder.rb` | **M** | `EVIDENCE_VERSION`→v2 (`:17,:89`) | v2 consumer | prompt_builder spec |
| 9 | `custom/wijaya/batteries/marine_ai/app/services/marine/backend/evidence_fact_verifier.rb` | **M** | COMMENTS ONLY (`:9,:57`)→v2. NO production `EVIDENCE_VERSION` constant exists here | Comment honesty; spec asserts serialized sole-fact-source text | fact_verifier spec (fixture `:12,:54`→v2) |
| 9b | `custom/wijaya/batteries/marine_ai/app/services/marine/backend/family_price_range_authority.rb` | **M** | COMMENT ONLY (`:9`)→v2 wording; no behavior/constant | Comment honesty | — (no spec change) |
| 9c | `custom/wijaya/batteries/marine_ai/app/services/marine/backend/evidence_reply_generator.rb` | **V** | NO production v1 literal — unchanged; only its spec fixture flips | Production generator is version-agnostic over the serialized packet | reply_generator spec (fixture `:12`→v2) |
| 10 | `custom/wijaya/batteries/marine_ai/app/services/marine/backend/post_generation_fact_validator.rb` | **M** | `LEAK_MARKERS` (`:45`) add `marine_evidence_v2`; keep `marine_evidence_v1` + `capabilities` (+ `canonical`) | Generated text must leak neither version string nor the word capabilities | post_generation_fact_validator spec |
| 11 | `custom/wijaya/batteries/marine_ai/app/services/marine/backend/authority_shadow_execution.rb` | **M** | Remove `scenario_capabilities:` arg to coordinator (`:54`); doc fix (`:19-20`) | Stop sourcing authz from scenario config | shadow execution spec |
| 11b | `custom/wijaya/batteries/marine_ai/app/services/marine/product_authority/shadow_execution.rb` | **M** | Runner site B: drop adapter `scenario_capabilities: capability_map(scenarios)` (`:115`) + `capability_map` helper (`:130-132`); `Runner.new(classification_intents: Marine::Backend::ExecutionPolicy::CLASSIFICATION_INTENTS)` (`:145`); doc fix (`:103-106,:128-129`) | Allowlisted Backend consumer; policy classification + policy authz via adapter | product_authority shadow_execution spec |

### 10.2 Source — Decision (must-change) + composition root

| # | File | Kind | Responsibility / change | Reason | Test impact |
|---|---|---|---|---|---|
| 12 | `custom/wijaya/batteries/marine_ai/app/jobs/marine/decision/shadow_job.rb` | **M** | Composition root: `ShadowExecution.new(**records, classification_intents: Marine::Backend::ExecutionPolicy::CLASSIFICATION_INTENTS)` (`:54`) | Inject policy classification; only allowlisted unit naming Backend | shadow_job spec |
| 13 | `custom/wijaya/batteries/marine_ai/app/services/marine/decision/shadow_execution.rb` | **M** | `initialize(..., classification_intents:)`; validate non-empty String Array else `call`→nil; pass to `Runner.new(classification_intents:)` (`:21-26,:88-90`) | Thread injected vocabulary; fail closed; NO Backend ref | shadow_execution (decision) spec |
| 14 | `custom/wijaya/batteries/marine_ai/app/services/marine/decision/runner.rb` | **M** | `initialize(client:, settings:, classification_intents:)`; pass to `InputContract.build`; rename `intersect_capabilities`→`restrict_to_classification_vocabulary` (`:143,:158-168`); doc fix (`:20-22`) | Policy-derived classification; honest naming; NO Backend ref | runner spec |
| 15 | `custom/wijaya/batteries/marine_ai/app/services/marine/decision/input_contract.rb` | **M** | `SCENARIO_ENTRY_KEYS`→`%w[key description instruction]`; `build(..., classification_intents:)`; `allowed_intents`=validated injected list (canonical order); remove `capabilities`/`MAX_CAPABILITIES`/`ALWAYS_ALLOWED_INTENT`/union | Explicit policy-derived vocabulary; remove scenario `capabilities` field | input_contract spec |
| 16 | `custom/wijaya/batteries/marine_ai/app/services/marine/decision/request_builder.rb` | **M** | `intents_schema(input[:allowed_intents])` (enum=classification list, `:117-120`); `envelope_scenario` drops `capabilities` (`:205-212`); decisions NOUL already per `allowed_intents` | Both protocols offer exactly `["price","unsupported"]`; scenario carries no capabilities | request_builder spec |
| 17 | `custom/wijaya/batteries/marine_ai/app/services/marine/decision/scenario_adapter.rb` | **M** | `entry`→`{key,description,instruction}`; stop reading `ShadowConfig.scenario_capabilities` (`:43,57-65`); doc fix | Scenario = identity/provenance only | scenario_adapter spec |
| 18 | `custom/wijaya/batteries/marine_ai/app/services/marine/decision/shadow_config.rb` | **M** | Remove `scenario_capabilities`/`CAPABILITIES_KEY`/parse helpers/bounds; keep enabled/assistant-allowlist | `MARINE_DECISION_SCENARIO_CAPABILITIES` no longer read | shadow_config spec |
| 18b | `custom/wijaya/batteries/marine_ai/app/services/marine/decision/cutover_scenario_selector.rb` | **V / N** | Runner site C (customer path): **VERIFY-ONLY / MUST-NOT-CHANGE.** No concrete Phase-1 dependency — its default Decision Runner is LAZY and unreachable while cutover stays closed. Do NOT thread `classification_intents:`; do NOT modify this file, `agent/runner.rb`, `cutover_gate.rb`, or `cutover_config.rb`. VERIFY the closed-gate path short-circuits to legacy before the default Runner | Previous MODIFY came from static call-site analysis only; closed cutover makes it inactive in Phase 1 | `cutover_scenario_selector_spec` is VERIFY-ONLY (not a test-change target) |

### 10.3 Source — ProductAuthority (acceptance-only contract migration; preserve isolation + PHASE_LOCKED)

This is a **deliberate contract migration required by approved Opsi B**, not feature expansion: the
acceptance corpus moves from "respects per-scenario capabilities" to "respects the price-only execution
policy". No component gains a NEW direct `Marine::Backend` reference; existing isolation allowlists and
`PHASE_LOCKED` are preserved; no live runtime wiring is added.

| # | File | Kind | Change | Isolation note |
|---|---|---|---|---|
| 19 | `custom/wijaya/batteries/marine_ai/app/services/marine/product_authority/acceptance_pipeline_coordinator.rb` | **M** | Folds PREBUILT plans — NO `InputContract`. ONLY drop `scenario_capabilities:` from `run`/`execute` + adapter call (`:61,:95`); the adapter now grounds on `ExecutionPolicy`. Does NOT inject a classification vocabulary | Already-allowlisted Backend consumer; no NEW Backend ref; no classification injection (no contract build) |
| 20 | `custom/wijaya/batteries/marine_ai/app/services/marine/product_authority/evaluator.rb` | **M** | `canonical_input` drops `capabilities` (`:302-303`); stop passing `scenario_capabilities:` to `run_coordinator` (`:326`). As the allowlisted driver of the ONLY contract-build surface, read `ExecutionPolicy::CLASSIFICATION_INTENTS` and thread it as a plain array into the parity intake (row 22) via `score_parity`/`SURFACES` | Already-allowlisted; it is the composition point that supplies the plain classification array to the non-allowlisted parity intake |
| 21 | `custom/wijaya/batteries/marine_ai/app/services/marine/product_authority/acceptance_runner.rb` | **M** | Folds PREBUILT plans — NO `InputContract`. Drop `kase[:capabilities]` plumbing (`:170`) + `executable_case?` capability gate (`:112-113`). Do NOT add a classification array param (no contract build here) | Holds NO `Marine::Backend` ref — must stay so |
| 22 | `custom/wijaya/batteries/marine_ai/app/services/marine/product_authority/parity/intake_adapters.rb` | **M** | **Sole `InputContract.build` surface.** `ConversationIntake` scenario entry drops `'capabilities'` (`:91-97`) and `InputContract.build` receives the injected plain `classification_intents:` array (from Evaluator); drop `case_input` `capabilities` (`:149-150`) + `run_coordinator` `scenario_capabilities:` (`:306`) | Holds NO `Marine::Backend` ref — receives a plain array param, never a constant |
| 23 | `custom/wijaya/batteries/marine_ai/app/services/marine/product_authority/corpus.rb` | **M** | Drop per-case `capabilities:` maps; keep `scenario_key:` provenance; re-express `capability_mismatch`/`capability_unconfigured`/`capability_malformed` as policy semantics (price→executable; stock/catalog/product_overview/mixed→`phase_not_executable`/`unsupported`) | Fixtures only; no runtime/Backend ref |

### 10.4 Customization registry

| # | File | Kind | Change |
|---|---|---|---|
| 24 | `custom/wijaya/patches/patch_registry.yml` | **M** | Add `custom/wijaya/batteries/marine_ai/app/services/marine/backend/execution_policy.rb` + its spec to the marine_ai `custom_files` list (near `:1265`). Modified existing files are already listed |
| 25 | `check_custom_patches.sh` | **M** | Add `require_file` lines for `execution_policy.rb` and `execution_policy_spec.rb`, mirroring the existing marine backend `require_file` block. `apply_custom_patches.sh` stays idempotent (file/marker verification; no new marker hooks) |

### 10.5 Tests — test-only (updated atomically with their source)

**T (updated):** `spec/custom/wijaya/batteries/marine_ai/backend/{candidate_plan_to_product_intent_adapter,
authority_coordinator,product_execution_planner,evidence_packet_builder,authority_shadow_execution,
backend_pipeline_integration,model2_shadow_execution,evidence_packet_presenter,evidence_prompt_builder,
evidence_fact_verifier,evidence_reply_generator,post_generation_fact_validator}_spec.rb`
(`evidence_fact_verifier`/`evidence_reply_generator` are FIXTURE-ONLY version-string flips — no
production constant changed);
`spec/custom/wijaya/batteries/marine_ai/decision/{scenario_adapter,shadow_config,input_contract,runner,
request_builder,shadow_execution,model1_structured_product_candidate}_spec.rb`
(`model1_structured_product_candidate_spec.rb:17` constructs the Runner with the policy-derived
classification list — Runner site D). **`cutover_scenario_selector_spec.rb` is NOT a test-change target — it
is VERIFY-ONLY (site C, §10.6).**
`spec/custom/wijaya/batteries/marine_ai/jobs/decision/shadow_job_spec.rb` (injection);
`spec/custom/wijaya/batteries/marine_ai/product_authority/{shadow_execution,acceptance_pipeline_coordinator,evaluator,
acceptance_runner,corpus,parity/intake_adapters,parity/parity_runtime,product_authority_isolation}_spec.rb`
(`product_authority/shadow_execution_spec` covers Runner site B — adapter authz + policy classification).
**T (new):** `spec/custom/wijaya/batteries/marine_ai/backend/execution_policy_spec.rb`.

### 10.6 Verify-only / must-not-change

- **V:** `evidence_packet_presenter.rb` scenario Hash type-check tolerates `{key, intents}`;
  `model2_shadow_observation.rb`, `model2_shadow_metrics_store.rb` (no scenario/version read);
  `evidence_reply_generator.rb` (no production v1 literal — unchanged; spec fixture flips, row 9c);
  `backend/catalog_candidate_resolver.rb` (resolves exact identity before the planner via
  ProductFamilyRepository/VariantRepository; closed statuses `exact_family`/`exact_child`/`ambiguous`/
  `no_catalog_match`/`unavailable`; reads NO scenario capabilities — preserves repository-authoritative
  exact identity; §2.5).
  `decision/cutover_scenario_selector.rb` + `spec/.../decision/cutover_scenario_selector_spec.rb`
  (Runner site C): VERIFY-ONLY — no Phase-1 dependency. Its default Decision Runner is lazy and unreachable
  while cutover stays closed; verify the closed-gate path short-circuits to legacy before that Runner, and
  that the existing selector spec (which injects a Runner double) plus the Agent specs (which stub the
  selector / use the closed gate / assert product flow never instantiates it) pass with the file and spec
  byte-for-byte unchanged. Do NOT modify either (§6.1 C, §8.10).
  *(`product_authority/shadow_execution.rb` is NO LONGER verify-only — it is modified as Runner site B,
  row 11b.)*
- **N (must-not-change):** `decision/cutover_scenario_selector.rb`,
  `decision/cutover_gate.rb` (`CutoverGate`), `decision/cutover_config.rb`, and
  `app/services/marine/agent/runner.rb` — byte-for-byte / source-unchanged for this dependency; cutover
  stays closed and the closed-gate behavior is verified (§6.1 C, §8.10);
  `catalog/price_repository.rb` `#price_for` (sole exact-price fact source;
  `'User Price'`; returns `:available`/`:unavailable`/`:conflict`; reads NO scenario capabilities — its
  repository doubles must receive ZERO calls on unauthorized intents, proven by the planner spec, §11.5,
  and §2.5); `product_authority/candidate_gate.rb` (`PHASE_LOCKED = true`);
  `decision/schema.rb` (closed vocabulary; `INTENTS` retains the full future vocabulary);
  `decision/candidate_plan.rb`, `decision/normalizer.rb` (untrusted closed schema + smuggling rejection);
  `decision/{chat_completions_client,openrouter_decisions_client,chat_response_parser,
  decisions_response_mapper}.rb` transport/parse internals (only the vocabulary *source* may change, never
  a fact/slot capability); `llm/config.rb` `installation_value` (no config-mechanism change); any
  `InstallationConfig`/DB/migration/seed.

---

## 11. Test Plan (phased TDD — no command is run in this planning task)

Each step is **failing spec → minimal implementation → focused verification**. Specs are authored/updated
first; "verify" names the future command (see §15), NOT an executed run. Test counts are deliberately NOT
stated.

1. **ExecutionPolicy (leaf first).** New `execution_policy_spec.rb`: `EXECUTABLE_INTENTS == %w[price]` &
   frozen; `CLASSIFICATION_INTENTS == %w[price unsupported]` & frozen; `authorized?(["price"])` true;
   `authorized?(["price","stock"])`/`([])`/`(["stock"])`/`(["unsupported"])`/non-array false; and
   CRUCIALLY `authorized?(["price","price"])` false and `authorized?(["price"].dup)` true — proving the
   **exact-canonical-array** rule (no dedupe/sort, duplicates/reordering never normalized into a pass);
   `executable?("price")` true, `executable?("unsupported")`/`"stock"` false;
   `(EXECUTABLE_INTENTS - Marine::Decision::Schema::INTENTS).empty?` and
   `(CLASSIFICATION_INTENTS - Marine::Decision::Schema::INTENTS).empty?` (spec-only subset assertion; the
   production leaf has no Schema dependency).
2. **Policy projection → both protocols (parity).** `input_contract_spec`: given injected
   `classification_intents: %w[price unsupported]`, `allowed_intents == %w[price unsupported]` (canonical
   order); a scenario entry with a `capabilities` key is rejected (unknown key). `request_builder_spec`:
   chat `intents_schema` enum == `%w[price unsupported]`; decisions `questions` keys ==
   `%w[scenario_candidate mdq_intent__price mdq_intent__unsupported]`; `envelope_scenario` has NO
   `capabilities` key. This proves **both protocols receive exactly `["price","unsupported"]` from the
   policy projection**.
3. **Injection chain (ALL consumer sites).** `shadow_job_spec` (site A): `ShadowExecution` is constructed
   with `classification_intents: Marine::Backend::ExecutionPolicy::CLASSIFICATION_INTENTS`.
   `shadow_execution_spec` (decision): a nil/empty/non-Array classification → `call` returns nil (Runner
   never invoked); a valid list → Runner receives it. `runner_spec`: an invalid injected list folds to a
   safe unknown plan; `restrict_to_classification_vocabulary` drops `stock`/`order_status` before
   normalization. `product_authority/shadow_execution_spec` (site B): the Decision Runner is built with
   `classification_intents: ExecutionPolicy::CLASSIFICATION_INTENTS` and the adapter is called WITHOUT
   `scenario_capabilities:`. `cutover_scenario_selector_spec` (site C) is **VERIFY-ONLY** — NO new/changed
   assertions: confirm the existing spec (which injects a Runner double in its builder) and the Agent specs
   still pass with the selector, `Agent::Runner`, and `CutoverGate`/`CutoverConfig` byte-for-byte unchanged,
   and that the closed-gate path never reaches the default Decision Runner.
   `model1_structured_product_candidate_spec` (site D): the Runner
   is constructed with the policy-derived classification list and classifies over `["price","unsupported"]`.
   Parity intake (site E) is covered in step 10.
4. **Adapter (forged plans fail closed pre-repo).** `candidate_plan_to_product_intent_adapter_spec`:
   price accepted (`Result.scenario == {key:}`); a directly-constructed/forged `CandidatePlan` carrying
   `stock`/`price+stock`/`order_status` → whole-plan reject (`REASON_PHASE_NOT_EXECUTABLE` or supported-set
   reject) with NO resolver/repository call; scenario-key provenance mismatch still rejects; smuggling
   still folds.
5. **Planner (direct call fails before repositories).** `product_execution_planner_spec`: `executable?`
   via policy; a direct call with `[]`/`["stock"]`/`["price","stock"]` → factless handoff and the
   `ProductFamilyRepository`/`VariantResolver`/`PriceRepository` doubles receive ZERO calls; price happy
   path unchanged; `scenario: {key:}`.
6. **EvidencePacketBuilder (v2).** `evidence_packet_builder_spec`: `evidence_version == 'marine_evidence_v2'`;
   `scenario == {key:, intents:}`; a `capabilities` subkey rejected as unknown; a packet whose top-level
   `intents` set is not `ExecutionPolicy.authorized?` (e.g. `["stock"]`, `["price","stock"]`,
   `["price","price"]`) rejected under the WHOLE-SET gate; the preserved per-fact coherence checks still
   reject a non-price fact as extra defense; price packet + coherence unchanged.
7. **AuthorityCoordinator.** `authority_coordinator_spec`: `#call` without `scenario_capabilities:`; price →
   v2 evidence packet accepted; non-price/mixed → `phase_not_executable`/`legacy_preserved`; capability
   reasons removed; `planner_input` uses `EXECUTABLE_INTENTS`.
8. **Model 2 (v2 exact-price only, non-delivering).** `model2_shadow_execution_spec`: accepts ONLY a v2
   packet with `ExecutionPolicy.authorized?(result.intents)` + `response_goals == %w[answer_price]` +
   `facts.keys == %i[price]`; a v1 packet, a non-price fact packet, or a mixed-intent Result skips with
   ZERO provider calls; result is `{status, reason}` only (never text); no scenario read.
9. **AuthorityShadowExecution + ScenarioAdapter + ShadowConfig.** Specs: coordinator invoked WITHOUT
   `scenario_capabilities:`; `scenario_<id>` still passed; relationship/acceptance/resolver gates intact;
   `scenario_capabilities` removed; `enabled?`/assistant allowlist intact; scenario entries carry
   identity/context only.
10. **ProductAuthority acceptance/parity/corpus (contract migration).** Specs + fixtures to price-only
    policy semantics; the renamed `capability_*` corpus cases assert the policy block reason. The
    coordinator/evaluator/acceptance_runner specs assert the `scenario_capabilities:` plumbing is GONE and
    the adapter grounds on policy (no classification array injected — those surfaces build no contract).
    The parity intake spec (site E) asserts `ConversationIntake` builds the REAL `InputContract` with the
    injected plain classification array and NO scenario `capabilities`, driven by `Evaluator`. Isolation
    spec still green (no NEW `Marine::Backend` consumer; allowlist at
    `product_authority_isolation_spec.rb:14-55` unchanged; `evaluator.rb` already allowlisted);
    `CandidateGate` stays `PHASE_LOCKED`.
11. **Integration + patch registry.** `backend_pipeline_integration_spec` price path green end to end;
    `bash check_custom_patches.sh` green (new files registered; all markers present).

Failure matrix (both-protocol + backend defense):

| Input | Decisions mode | Chat mode | Adapter | Coordinator | Planner | Builder (v2) |
|---|---|---|---|---|---|---|
| candidate `["price"]`, exact variant | NOUL `price` present | enum `price` | accepted `{key}` | `authorized?`→proceed | executes price fact | `answer_price` packet |
| candidate `["stock"]` | **not offered** (no NOUL) | **not in enum** | forged→supported-but-unauth or filtered | `authorized?`→false→`phase_not_executable`/legacy | direct call → factless handoff pre-repo | non-price fact rejected |
| candidate `["price","stock"]` | **stock not offered** | **stock not in enum** | forged→`authorized?`→false (not exact set) | false→legacy | handoff | n/a |
| candidate `["order_status"]` | **not offered** | **not in enum** | forged→whole-plan reject (unsupported) | n/a | n/a | n/a |
| forged duplicate `["price","price"]` | n/a | n/a | `authorized?`→false (exact array, not deduped) | false→legacy | handoff | top-level `intents` rejected |
| empty intents | — | — | reject | — | handoff pre-repo | — |
| forged scenario key (not re-resolved) | nomination only | nomination only | scenario_key provenance mismatch | stop/scenario_mismatch | — | — |
| price unavailable (repo) | — | — | accepted | proceed | no fact → handoff | `handoff` goal |

---

## 12. Chatwoot Customization Impact

- All business logic stays in `custom/wijaya/batteries/marine_ai/` (no OSS/core edit; **no**
  `WIJAYA_CUSTOM_START/END` hook needed — entirely battery-internal). No Enterprise overlay touchpoint.
- New file `execution_policy.rb` + its spec are registered in `custom/wijaya/patches/patch_registry.yml`
  `custom_files` and in `check_custom_patches.sh` `require_file`; `apply_custom_patches.sh` remains
  idempotent (file/marker verification; no new marker hooks).
- **ProductAuthority isolation preserved exactly.** No Decision-layer class gains a `Marine::Backend`
  reference: the main-shadow classification list flows as a plain frozen array injected by `ShadowJob`
  (already allowlisted as the decision bridge); the product-parity shadow `product_authority/shadow_execution.rb`
  (already allowlisted, already names Backend) reads `ExecutionPolicy` directly; and the acceptance
  contract-build surface (`parity/intake_adapters.rb`) receives a plain array threaded in by the
  already-allowlisted `evaluator.rb`. `acceptance_pipeline_coordinator.rb` and `acceptance_runner.rb`
  simply drop the capability plumbing (they build no contract). `acceptance_runner.rb`, `parity/intake_adapters.rb`,
  `corpus.rb`, `candidate_gate.rb` keep ZERO `Marine::Backend` references (they receive a parameter, never
  a constant); `cutover_scenario_selector.rb` is UNCHANGED (VERIFY-ONLY — §8.10) and keeps ZERO
  `Marine::Backend` references. `ExecutionPolicy` is named only from within `app/services/marine/backend/**`, which the
  isolation allowlist already permits; ProductAuthority never names it.
- `CandidateGate` remains `PHASE_LOCKED = true` with no live runtime wiring; `shadow_execution.rb`
  (product_authority) stays adapter-only (must still NOT reference `ProductExecutionPlanner`).

---

## 13. Data / Configuration Impact

- **Database mutation: NO.** No table/row read-write beyond the existing read-only
  `assistant.scenarios.enabled` (ScenarioAdapter/ScenarioResolver) and read-only catalog repositories.
- **InstallationConfig mutation: NO.** `MARINE_DECISION_SCENARIO_CAPABILITIES` is simply no longer read;
  any stored value becomes an inert, unread orphan. It is NOT deleted, written, or used as a solution.
- **ENV addition: NO.** `ExecutionPolicy::EXECUTABLE_INTENTS`/`CLASSIFICATION_INTENTS` are hardcoded frozen
  constants — not config/ENV mechanisms. No new InstallationConfig key.
- **Migration: NO. Seed: NO.**
- **Shadow activation: NO. Cutover activation: NO. Feature flag / customer delivery: NO.** The chain
  stays reachable only from the default-OFF shadow path; this plan flips nothing on.
- No `scenario_<id>` is hardcoded anywhere; `scenario_5 -> price` is NOT materialized.

---

## 14. Risks & Open Questions

**No open design questions remain.** Model 1 vocabulary, the policy owner and contract, the injection
direction, the Evidence Packet version, and the ProductAuthority corpus migration are all decided above.
The items below are genuine operational/implementation risks only.

- **Risk: broad test surface.** ~25 spec files move together with the version flip and the capabilities
  removal. Mitigated by the leaf-first TDD order (§15) and the single policy source (no scattered
  allowlists to keep in sync).
- **Risk: version flip must be complete.** `marine_evidence_v2` is an atomic switch with no dual-read; a
  missed consumer would fail closed (packets skip rather than deliver), which is safe but would surface as
  a red spec. The migration surface in §9 is exhaustive; every version assertion moves to v2 and both
  version strings stay in `LEAK_MARKERS`.
- **Risk: isolation regression.** Any accidental `Marine::Backend` constant reference added to a
  Decision-layer or non-allowlisted ProductAuthority file would break `product_authority_isolation_spec`.
  Mitigated by injecting a plain array (never the constant) everywhere outside the allowlisted composition
  roots; step 10 re-runs the isolation spec.
- **Risk: adapter generality.** The adapter stays a general candidate→product-intent translator
  (`SUPPORTED_INTENTS`); only *authorization* narrows to the exact price set. The acceptance corpus must
  not be read as implying stock/catalog translation is removed — only its execution is non-authorized and
  its classification offer is withheld in Phase 1.
- **Cutover selector is OUT of Phase-1 scope (decided, not open).** There is NO concrete Phase-1 runtime
  or test dependency requiring `cutover_scenario_selector.rb` to change: its default Decision Runner is
  lazy and unreachable while cutover stays closed, so the selector, `agent/runner.rb`, `CutoverGate`, and
  `CutoverConfig` are VERIFY-ONLY / MUST-NOT-CHANGE. The earlier MODIFY idea came only from static
  call-site analysis, not a real dependency. Future cutover activation (threading a classification
  vocabulary into the live customer path) needs a separately approved policy-composition seam — a
  future-scope dependency, NOT a current Phase-1 blocker or unresolved architecture question.
- **Consumer inventory is exhaustive (decided, not open).** The five Runner/`InputContract` sites (§6.1
  A–E) were enumerated by `git grep` over the whole battery. FOUR are Phase-1 consumers handled explicitly
  (A main shadow, B product-parity shadow, D the structured-candidate proof spec, E the sole acceptance
  `InputContract.build`); the FIFTH (C, the cutover selector's default Runner) is audited but INACTIVE
  under the closed-cutover constraint and is VERIFY-ONLY. The coordinator/evaluator/acceptance_runner
  surfaces that fold prebuilt plans build no `InputContract` and therefore take no classification array. No
  omitted call site remains.
- **No source conflict found.** All coupling sites are internally consistent and changeable without
  contradiction; nothing is BLOCKED. (If a future reviewer finds a cross-file contract missed here, treat
  it as a new finding, not a license to invent a workaround.)

---

## 15. Implementation Order

Leaf-first, fail-closed at every step. (Commands below are for the FUTURE implementation; none is run now.)

**0. Fail-closed precondition (BLOCKING).** Before starting — and again after finishing — Phase-1
implementation, VERIFY that cutover is **closed** (i.e. `CutoverGate.open?` is false / `CutoverConfig` is
not enabled for the target account+assistant). If cutover is NOT closed, Phase-1 implementation is
**BLOCKED**: the implementer must STOP and report the conflict. There is no workaround and no cutover
policy wiring in Phase 1 — do not touch `cutover_scenario_selector.rb`, `agent/runner.rb`, `CutoverGate`,
or `CutoverConfig` to proceed.

1. `ExecutionPolicy` (+ spec) — the single source (executable + classification).
2. `EvidencePacketBuilder` v2 scenario/packet-validation (+ spec) — the presentation contract.
3. Evidence consumers version flip: presenter, prompt_builder, model2 (real constants); fact_verifier +
   family_price_range_authority (comments) + evidence_reply_generator (spec fixture only); post_generation
   leak markers (+ specs).
4. `ProductExecutionPlanner` defense (+ spec).
5. `CandidatePlanToProductIntentAdapter` candidate-intent authorization (+ spec).
6. `AuthorityCoordinator` gate + signature (+ spec); `AuthorityShadowExecution` call-site (+ spec).
7. Decision layer + composition root: `InputContract` (classification_intents), `RequestBuilder`
   (enum/envelope), `Runner` (inject + rename), `ShadowExecution` (inject + validate), `ScenarioAdapter`,
   `ShadowConfig`, `ShadowJob` injection (site A), `model1_structured_product_candidate_spec` (site D)
   (+ specs). `cutover_scenario_selector.rb` (site C) is NOT modified — VERIFY-ONLY (§8.10): verify the
   closed-gate path leaves the selector, `Agent::Runner`, `CutoverGate`, and `CutoverConfig` unchanged.
8. ProductAuthority acceptance/parity/corpus contract migration incl. `product_authority/shadow_execution.rb`
   (site B) and `parity/intake_adapters.rb` (site E, classification into the sole contract build) (+ specs);
   re-run isolation spec.
9. Integration + Model 2 non-delivery verification.
10. Patch registry + `check_custom_patches.sh` + `bash check_custom_patches.sh`.

**Future verification commands (DO NOT run in this planning task):**
```bash
# Test-database safety wrapper (containerized; default command `bundle exec rspec`):
custom/wijaya/batteries/test_database_safety/bin/run_test_specs.sh bundle exec rspec \
  spec/custom/wijaya/batteries/marine_ai/backend/execution_policy_spec.rb \
  spec/custom/wijaya/batteries/marine_ai/backend \
  spec/custom/wijaya/batteries/marine_ai/decision \
  spec/custom/wijaya/batteries/marine_ai/jobs/decision \
  spec/custom/wijaya/batteries/marine_ai/product_authority

# RuboCop via the same wrapper (BUNDLE_WITHOUT='' set by the wrapper):
custom/wijaya/batteries/test_database_safety/bin/run_test_specs.sh bundle exec rubocop \
  custom/wijaya/batteries/marine_ai/app/services/marine/backend \
  custom/wijaya/batteries/marine_ai/app/services/marine/decision \
  custom/wijaya/batteries/marine_ai/app/jobs/marine/decision \
  custom/wijaya/batteries/marine_ai/app/services/marine/product_authority

# Patch registry / marker integrity (from repo root):
bash check_custom_patches.sh
```
**Expected outcome categories (not fabricated counts):** policy/adapter/planner/coordinator/builder specs
green; both Model 1 protocol specs offer exactly `["price","unsupported"]` and still reject fact/slot
smuggling; ProductAuthority isolation spec green (no new `Marine::Backend` consumer; gate phase-locked);
Model 2 spec green, v2-only, and non-delivering; RuboCop clean on changed files;
`check_custom_patches.sh` reports all battery files/markers present including the new policy file.

Completed implementation will require a **blocking second read-only review and independent verification**
before any commit/push/build/deploy. This plan itself remains uncommitted.

---

## 16. Phase 1 Acceptance Criteria

1. `Marine::Backend::ExecutionPolicy` is a PURE backend leaf (no production dependency, not on
   `Schema`) and the ONLY execution-authorization AND classification-vocabulary source:
   `EXECUTABLE_INTENTS == ["price"]` and `CLASSIFICATION_INTENTS == ["price","unsupported"]` (frozen;
   both ⊆ `Schema::INTENTS` as proven by the policy spec). `authorized?` requires the EXACT canonical
   array `intents == EXECUTABLE_INTENTS` — no dedupe/sort, so `["price","price"]` and reordered/malformed
   sets fail. No other file keeps an independent price/capability allowlist
   (`AuthorityCoordinator::PRICE_ONLY` removed).
2. Adapter, coordinator, planner, packet builder, and model2 each authorize via `ExecutionPolicy`; none
   reads `scenario[:capabilities]` or a scenario-capability map. The packet builder authorizes the
   complete top-level `intents` set via `authorized?` (whole-set), with per-fact coherence preserved as
   extra defense.
3. `ShadowConfig.scenario_capabilities`, `CAPABILITIES_KEY`, and `MARINE_DECISION_SCENARIO_CAPABILITIES`
   consumption are removed; the misnamed scenario `capabilities` field is gone from `ScenarioAdapter`,
   `InputContract`, `RequestBuilder`, the adapter `Result`, and the Evidence Packet.
4. Scenario is identity/provenance only (`scenario_<id>` via `ScenarioResolver`), threaded unchanged into
   coordinator and into the packet `scenario.key`.
5. Both Model 1 protocols offer EXACTLY `["price","unsupported"]` (policy-derived). ALL FIVE
   Runner/`InputContract` sites (§6.1) are addressed — FOUR wired, site C VERIFY-ONLY: (A) main shadow via
   `ShadowJob`; (B) `product_authority/shadow_execution.rb` builds its Runner with `CLASSIFICATION_INTENTS`
   and drops the capability map; (C) `cutover_scenario_selector.rb` is VERIFY-ONLY / byte-for-byte
   unchanged — its default Runner is lazy and unreached under closed cutover, so NO `classification_intents:`
   is threaded (see criterion 11); (D) the direct `model1_structured_product_candidate_spec` constructs the
   Runner with the policy list; (E) the parity `ConversationIntake` receives the plain array into the sole
   acceptance `InputContract.build`.
   `stock`/`catalog`/`order_status`/etc are offered by neither protocol; `unsupported` never authorizes
   execution; question mode still cannot emit slot text; the closed candidate-plan schema + smuggling
   rejection are intact.
6. Backend fails closed: a direct planner invocation (and a forged CandidatePlan carrying
   `stock`/`mixed`/`order_status`) handoffs/rejects BEFORE any repository read; a packet carrying a
   non-price fact is rejected; whole-plan rejection and repository re-resolution preserved.
7. The Evidence Packet is `marine_evidence_v2` with `scenario == {key, intents}` and no `capabilities`;
   the four real-constant producers/consumers (builder, presenter, prompt_builder, model2) plus all
   comment/fixture occurrences moved atomically (no dual-read, no compat projection);
   `evidence_fact_verifier`/`evidence_reply_generator`/`family_price_range_authority` have NO production
   version constant (comments/fixtures only); both `v1` and `v2` strings remain forbidden `LEAK_MARKERS`;
   current packet acceptance requires v2.
8. ProductAuthority acceptance/parity/corpus migrated to price-only policy semantics; the coordinator/
   evaluator/acceptance_runner surfaces drop capability plumbing without injecting any classification
   array (they build no contract); only the parity `ConversationIntake` contract-build surface receives
   the injected classification array; isolation preserved (no new `Marine::Backend` reference; existing
   allowlist unchanged); `CandidateGate` stays `PHASE_LOCKED`; no live runtime wiring.
   `CatalogCandidateResolver` and `PriceRepository#price_for` are unchanged and provably uncalled on
   unauthorized intents.
9. New file registered in `patch_registry.yml` + `check_custom_patches.sh`; `bash check_custom_patches.sh`
   passes; `apply_custom_patches.sh` idempotent.
10. All §13 flags hold: DB/InstallationConfig/ENV/Migration/Seed/Shadow/Cutover = NO. Chain remains
    shadow / non-delivering / not customer-facing.
11. `cutover_scenario_selector.rb`, `agent/runner.rb` (`Agent::Runner`), `CutoverGate`
    (`decision/cutover_gate.rb`), and `CutoverConfig` (`decision/cutover_config.rb`) are **byte-for-byte /
    source-unchanged** — there is no Phase-1 dependency to change them because the selector's default
    Decision Runner is lazy and unreachable while cutover stays closed. Cutover remains **CLOSED** and the
    closed-gate behavior is verified to prevent `ScenarioAdapter` / default Decision Runner / metrics /
    provider work. **Fail-closed precondition (§15 step 0):** before AND after implementation, verify
    cutover is closed; if it is NOT closed, Phase-1 implementation is BLOCKED and the implementer must
    report the conflict — no workaround and no cutover policy wiring in Phase 1. The existing selector spec
    and the Agent runner specs are VERIFY-ONLY (not test-change targets) and remain green unchanged.

---

## 17. Explicit Non-Goals

- NOT activating the shadow, cutover, any feature flag, or customer delivery.
- NOT editing, deleting, or writing `InstallationConfig` (incl. `MARINE_DECISION_SCENARIO_CAPABILITIES`)
  or any DB row; NO migration/seed.
- NOT adding any ENV/config mechanism; `ExecutionPolicy` is hardcoded frozen constants.
- NOT hardcoding `scenario_5` (or any deployed scenario id) → `price`, nor materializing any
  scenario→capability mapping in DB/config/source.
- NOT expanding the Phase 1 executable set beyond `["price"]` or the classification offer beyond
  `["price","unsupported"]`; NOT removing the full `Schema::INTENTS` future vocabulary.
- NOT adding a new direct `Marine::Backend` reference to any Decision-layer or non-allowlisted
  ProductAuthority component; NOT opening `CandidateGate`; NOT wiring any ProductAuthority code into a live
  runtime path.
- NOT modifying `cutover_scenario_selector.rb`, `agent/runner.rb` (`Agent::Runner`), `CutoverGate`, or
  `CutoverConfig`/cutover configuration/activation state, and NOT threading any `classification_intents:`
  into the cutover selector or the live customer path; those stay byte-for-byte unchanged and cutover stays
  closed. Any future cutover-activation policy-composition seam is separate, future-approved scope.
- NOT creating a persistent `marine_evidence_v1` reader/class or a dual-read/compatibility projection.
- NOT implementing, running tests/RuboCop/builds/migrations/runners/probes/Docker/deploy, and NOT
  committing or pushing. This document is the only artifact produced.
