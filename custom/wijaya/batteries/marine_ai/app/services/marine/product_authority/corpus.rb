# Fase 3A-2 — BOUNDED, SANITIZED, battery-owned synthetic labelled corpus for the product-authority
# evaluator. Every value here is CLEARLY SYNTHETIC: there is NO customer text/data, no real ID,
# credential, provider body, or real product secret. Family/variant/price values are invented tokens
# (SYN-*) and languages are format-only codes.
#
# Each case is one turn expressed as an UNTRUSTED raw marine_decision_v1 candidate plan plus the
# backend inputs (the scenario provenance key, injected read-only repository fixtures) and a
# BACKEND-OWNED label — the expected NORMALIZED product intent/slot outcome and the expected planner
# response goals (the action outcome). Labels are the acceptance truth; they are NOT derived from any
# legacy output. The Evaluator folds each plan through the real Fase 3A-1 adapter + ProductExecutionPlanner
# (with the injected fixtures) and checks the outcome against the label.
#
# PHASE 1 (OPTION B) POLICY SEMANTICS: execution authorization is owned by
# the backend execution policy (executable == exactly ["price"]). A case whose plan carries a
# supported but non-executable product intent set (stock / price+stock / catalog / product_overview)
# fails closed at the adapter with the closed reason `phase_not_executable` BEFORE the planner and
# BEFORE any repository read — its label is the blocked outcome, and the populated repository fixtures
# prove (via the Evaluator's mutation probe) that no repository was ever consulted. Scenarios carry
# identity/provenance ONLY (scenario_<n> keys); there is NO per-scenario capability map.
#
# Coverage: price; stock; compatible price+stock; product overview; catalog; ambiguous/unresolved
# variant; product replacement; variant correction; stock vs order_status; malformed/unknown plans;
# unsupported mixed intent; stock repository outage fail-closed (policy-blocked before any read);
# scenario mismatch; the phase-not-executable policy block; exact-code-only variant authority (a
# display candidate never resolves); a CRITICAL exact-stock-quantity safety case that must fail
# closed to blocked/handoff BEFORE any adapter/planner/stock execution; and a surface-aware
# Conversation-vs-Playground parity case (`parity: true`) the Evaluator runs through two distinct
# surface adapters.
#
# A case MAY additionally carry two explicitly-optional metadata keys the Evaluator honours: `safety`
# (a bounded { exact_quantity_request: Boolean } evaluation-only safety signal) and `parity` (Boolean,
# selecting the dual-surface parity harness). A label MAY carry an optional `block_reason`.
#
# This file is PURE DATA: NO provider call, settings/DB/Redis access, or state mutation.
# rubocop:disable Metrics/ModuleLength -- one cohesive, fully-declarative labelled data table.
module Marine::ProductAuthority::Corpus
  # Fixed acceptance policy (the deliverable's fixed thresholds), in integer basis points where a
  # rate applies. The Evaluator is advisory only and NEVER activates anything from these.
  BASIS = 10_000
  MIN_SUPPORTED_ACCURACY_BPS = 9_500 # overall supported-intent accuracy >= 95%
  CRITICAL_ACCURACY_BPS = 10_000     # critical safety cases 100%
  SCHEMA_VALID_BPS = 10_000          # valid slot-operation schema + repository revalidation 100%

  # A synthetic price fixture reused across price cases.
  PRICE_ALPHA = { status: :available, price_list_rate: 125_000, currency: 'IDR', uom: 'pcs' }.freeze

  CASES = [
    {
      id: 'price_resolved', category: 'price', critical: false, surface: 'both',
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'high' },
        'intents' => ['price'],
        'slot_operations' => [
          { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => 'SYN-FAM-ALPHA', 'candidate_type' => 'family_code' } },
          {
            'operation' => 'set', 'slot' => 'variant_input',
            'value' => { 'raw_candidate' => 'SYN-VAR-ALPHA-01', 'candidate_type' => 'variant_code' }
          }
        ],
        'customer_language' => 'en', 'confidence' => 'high'
      },
      repositories: {
        family: { 'SYN-FAM-ALPHA' => { code: 'SYN-FAM-ALPHA', name: 'Synthetic Alpha' } },
        variant: { 'SYN-VAR-ALPHA-01' => { status: :resolved, code: 'SYN-VAR-ALPHA-01' } },
        price: { 'SYN-VAR-ALPHA-01' => PRICE_ALPHA },
        stock: {}
      },
      label: { status: 'product', intents: ['price'], slot_ops: %w[product variant_code], response_goals: ['answer_price'] }
    },
    {
      # Phase 5: stock is an executable single-intent product read — the adapter accepts ["stock"], the
      # planner resolves the exact family + variant and the StockRepository returns the BINARY
      # availability (never a quantity), yielding answer_stock.
      id: 'stock_available', category: 'stock', critical: false, surface: 'both',
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'high' },
        'intents' => ['stock'],
        'slot_operations' => [
          { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => 'SYN-FAM-ALPHA', 'candidate_type' => 'family_code' } },
          {
            'operation' => 'set', 'slot' => 'variant_input',
            'value' => { 'raw_candidate' => 'SYN-VAR-ALPHA-01', 'candidate_type' => 'variant_code' }
          }
        ],
        'customer_language' => 'en', 'confidence' => 'high'
      },
      repositories: {
        family: { 'SYN-FAM-ALPHA' => { code: 'SYN-FAM-ALPHA', name: 'Synthetic Alpha' } },
        variant: { 'SYN-VAR-ALPHA-01' => { status: :resolved, code: 'SYN-VAR-ALPHA-01' } },
        price: {}, stock: { 'SYN-VAR-ALPHA-01' => :available }
      },
      label: { status: 'product', intents: ['stock'], slot_ops: %w[product variant_code], response_goals: ['answer_stock'] }
    },
    {
      # Phase 1: a compatible price+stock set is NOT the exact executable array ["price"], so the
      # whole plan fails the policy gate (exact-array authorization, never a partial execution).
      id: 'price_stock_compatible', category: 'price_stock', critical: false, surface: 'both',
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'high' },
        'intents' => %w[price stock],
        'slot_operations' => [
          { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => 'SYN-FAM-ALPHA', 'candidate_type' => 'family_code' } },
          {
            'operation' => 'set', 'slot' => 'variant_input',
            'value' => { 'raw_candidate' => 'SYN-VAR-ALPHA-01', 'candidate_type' => 'variant_code' }
          }
        ],
        'customer_language' => 'en', 'confidence' => 'high'
      },
      repositories: {
        family: { 'SYN-FAM-ALPHA' => { code: 'SYN-FAM-ALPHA', name: 'Synthetic Alpha' } },
        variant: { 'SYN-VAR-ALPHA-01' => { status: :resolved, code: 'SYN-VAR-ALPHA-01' } },
        price: { 'SYN-VAR-ALPHA-01' => PRICE_ALPHA }, stock: { 'SYN-VAR-ALPHA-01' => :available }
      },
      label: { status: 'blocked', intents: [], slot_ops: [], response_goals: nil, block_reason: 'phase_not_executable' }
    },
    {
      # Phase 1: product_overview is an informational product intent but not executable; the plan
      # fails closed at the adapter's policy gate before the planner.
      id: 'product_overview', category: 'overview', critical: false, surface: 'both',
      scenario_key: 'scenario_2',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_2', 'confidence' => 'medium' },
        'intents' => ['product_overview'],
        'slot_operations' => [
          { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => 'SYN-FAM-BETA', 'candidate_type' => 'display_name' } }
        ],
        'customer_language' => 'en', 'confidence' => 'medium'
      },
      repositories: {
        family: { 'SYN-FAM-BETA' => { code: 'SYN-FAM-BETA', name: 'Synthetic Beta' } },
        variant: {}, price: {}, stock: {}
      },
      label: { status: 'blocked', intents: [], slot_ops: [], response_goals: nil, block_reason: 'phase_not_executable' }
    },
    {
      # Phase 1: catalog is a supported product intent but not executable; the plan fails closed at
      # the adapter's policy gate before the planner.
      id: 'catalog_document', category: 'catalog', critical: false, surface: 'both',
      scenario_key: 'scenario_3',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_3', 'confidence' => 'high' },
        'intents' => ['catalog'],
        'slot_operations' => [
          { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => 'SYN-FAM-ALPHA', 'candidate_type' => 'family_code' } }
        ],
        'customer_language' => 'id', 'confidence' => 'high'
      },
      repositories: {
        family: { 'SYN-FAM-ALPHA' => { code: 'SYN-FAM-ALPHA', name: 'Synthetic Alpha' } },
        variant: {}, price: {}, stock: {}
      },
      label: { status: 'blocked', intents: [], slot_ops: [], response_goals: nil, block_reason: 'phase_not_executable' }
    },
    {
      id: 'clarify_family_missing', category: 'unresolved_family', critical: false, surface: 'both',
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'low' },
        'intents' => ['price'],
        'slot_operations' => [
          { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => 'SYN-FAM-UNKNOWN', 'candidate_type' => 'display_name' } }
        ],
        'customer_language' => 'en', 'confidence' => 'low'
      },
      repositories: { family: {}, variant: {}, price: {}, stock: {} },
      label: { status: 'product', intents: ['price'], slot_ops: %w[product], response_goals: ['clarify_product'] }
    },
    {
      id: 'ambiguous_variant', category: 'ambiguous_variant', critical: true, surface: 'both',
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'medium' },
        'intents' => ['price'],
        'slot_operations' => [
          { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => 'SYN-FAM-ALPHA', 'candidate_type' => 'family_code' } },
          { 'operation' => 'set', 'slot' => 'variant_input', 'value' => { 'raw_candidate' => 'SYN-VAR-AMBIG', 'candidate_type' => 'variant_code' } }
        ],
        'customer_language' => 'en', 'confidence' => 'medium'
      },
      repositories: {
        family: { 'SYN-FAM-ALPHA' => { code: 'SYN-FAM-ALPHA', name: 'Synthetic Alpha' } },
        variant: { 'SYN-VAR-AMBIG' => { status: :ambiguous, reason: :ambiguous } },
        price: {}, stock: {}
      },
      label: { status: 'product', intents: ['price'], slot_ops: %w[product variant_code], response_goals: ['clarify_ambiguous_variant'] }
    },
    {
      id: 'display_candidate_never_resolves', category: 'variant_correction', critical: true, surface: 'both',
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'medium' },
        'intents' => ['price'],
        'slot_operations' => [
          { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => 'SYN-FAM-ALPHA', 'candidate_type' => 'family_code' } },
          { 'operation' => 'set', 'slot' => 'variant_input', 'value' => { 'raw_candidate' => 'the blue one', 'candidate_type' => 'display_label' } }
        ],
        'customer_language' => 'en', 'confidence' => 'medium'
      },
      repositories: {
        family: { 'SYN-FAM-ALPHA' => { code: 'SYN-FAM-ALPHA', name: 'Synthetic Alpha' } },
        variant: {}, price: {}, stock: {}
      },
      label: { status: 'product', intents: ['price'], slot_ops: %w[product], response_goals: ['clarify_variant'] }
    },
    {
      id: 'variant_correction_replace', category: 'variant_correction', critical: false, surface: 'both',
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'high' },
        'intents' => ['price'],
        'slot_operations' => [
          { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => 'SYN-FAM-ALPHA', 'candidate_type' => 'family_code' } },
          {
            'operation' => 'replace', 'slot' => 'variant_input',
            'value' => { 'raw_candidate' => 'SYN-VAR-ALPHA-02', 'candidate_type' => 'variant_code' }
          }
        ],
        'customer_language' => 'en', 'confidence' => 'high'
      },
      repositories: {
        family: { 'SYN-FAM-ALPHA' => { code: 'SYN-FAM-ALPHA', name: 'Synthetic Alpha' } },
        variant: { 'SYN-VAR-ALPHA-02' => { status: :resolved, code: 'SYN-VAR-ALPHA-02' } },
        price: { 'SYN-VAR-ALPHA-02' => PRICE_ALPHA }, stock: {}
      },
      label: { status: 'product', intents: ['price'], slot_ops: %w[product variant_code], response_goals: ['answer_price'] }
    },
    {
      # Phase 5: a stock turn with replace-style slot operations resolves the replaced family + variant
      # and returns the BINARY availability (here the variant is empty -> unavailable), still answer_stock.
      id: 'product_replacement', category: 'product_replacement', critical: false, surface: 'both',
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'high' },
        'intents' => ['stock'],
        'slot_operations' => [
          { 'operation' => 'replace', 'slot' => 'product', 'value' => { 'raw_candidate' => 'SYN-FAM-GAMMA', 'candidate_type' => 'family_code' } },
          {
            'operation' => 'set', 'slot' => 'variant_input',
            'value' => { 'raw_candidate' => 'SYN-VAR-GAMMA-01', 'candidate_type' => 'variant_code' }
          }
        ],
        'customer_language' => 'en', 'confidence' => 'high'
      },
      repositories: {
        family: { 'SYN-FAM-GAMMA' => { code: 'SYN-FAM-GAMMA', name: 'Synthetic Gamma' } },
        variant: { 'SYN-VAR-GAMMA-01' => { status: :resolved, code: 'SYN-VAR-GAMMA-01' } },
        price: {}, stock: { 'SYN-VAR-GAMMA-01' => :empty }
      },
      label: { status: 'product', intents: ['stock'], slot_ops: %w[product variant_code], response_goals: ['answer_stock'] }
    },
    {
      # CRITICAL Phase-5 fail-closed proof: an executable stock turn whose stock fixture is an OUTAGE
      # resolves the family + variant but the StockRepository raises — the planner fails CLOSED by
      # omitting the fact and handing off, so no quantity and no status are ever emitted.
      id: 'stock_outage_failclosed', category: 'stock_failclosed', critical: true, surface: 'both',
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'high' },
        'intents' => ['stock'],
        'slot_operations' => [
          { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => 'SYN-FAM-ALPHA', 'candidate_type' => 'family_code' } },
          {
            'operation' => 'set', 'slot' => 'variant_input',
            'value' => { 'raw_candidate' => 'SYN-VAR-ALPHA-01', 'candidate_type' => 'variant_code' }
          }
        ],
        'customer_language' => 'en', 'confidence' => 'high'
      },
      repositories: {
        family: { 'SYN-FAM-ALPHA' => { code: 'SYN-FAM-ALPHA', name: 'Synthetic Alpha' } },
        variant: { 'SYN-VAR-ALPHA-01' => { status: :resolved, code: 'SYN-VAR-ALPHA-01' } },
        price: {}, stock: { 'SYN-VAR-ALPHA-01' => :unavailable }
      },
      label: { status: 'product', intents: ['stock'], slot_ops: %w[product variant_code], response_goals: ['handoff'] }
    },
    {
      id: 'stock_vs_order_status', category: 'stock_vs_order_status', critical: true, surface: 'both',
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'high' },
        'intents' => %w[stock order_status],
        'slot_operations' => [
          { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => 'SYN-FAM-ALPHA', 'candidate_type' => 'family_code' } }
        ],
        'customer_language' => 'en', 'confidence' => 'high'
      },
      repositories: { family: {}, variant: {}, price: {}, stock: {} },
      label: { status: 'blocked', intents: [], slot_ops: [], response_goals: nil, block_reason: 'unsupported_intent' }
    },
    {
      id: 'unsupported_mixed_intent', category: 'unsupported_mixed', critical: true, surface: 'both',
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'high' },
        'intents' => %w[price sample],
        'slot_operations' => [],
        'customer_language' => 'en', 'confidence' => 'high'
      },
      repositories: { family: {}, variant: {}, price: {}, stock: {} },
      label: { status: 'blocked', intents: [], slot_ops: [], response_goals: nil, block_reason: 'unsupported_intent' }
    },
    {
      # CRITICAL policy proof: a SUPPORTED but non-executable intent set (variant_info) fails the
      # backend-owned execution policy — the adapter rejects the whole plan with the closed reason
      # `phase_not_executable` before the planner and before any repository read. (Phase 5 activated
      # price_range/stock, so variant_info is the remaining single supported-but-unauthorized exemplar.)
      id: 'phase_not_executable', category: 'phase_not_executable', critical: true, surface: 'both',
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'high' },
        'intents' => ['variant_info'],
        'slot_operations' => [],
        'customer_language' => 'en', 'confidence' => 'high'
      },
      repositories: { family: {}, variant: {}, price: {}, stock: {} },
      label: { status: 'blocked', intents: [], slot_ops: [], response_goals: nil, block_reason: 'phase_not_executable' }
    },
    {
      id: 'scenario_mismatch', category: 'scenario_mismatch', critical: true, surface: 'both',
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_9', 'confidence' => 'high' },
        'intents' => ['price'],
        'slot_operations' => [],
        'customer_language' => 'en', 'confidence' => 'high'
      },
      repositories: { family: {}, variant: {}, price: {}, stock: {} },
      label: { status: 'blocked', intents: [], slot_ops: [], response_goals: nil, block_reason: 'scenario_mismatch' }
    },
    {
      id: 'malformed_unknown_field', category: 'malformed', critical: true, surface: 'both',
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'high' },
        'intents' => ['price'],
        'slot_operations' => [],
        'validated_price' => 999, # out-of-contract key -> normalizer rejects the whole plan
        'customer_language' => 'en', 'confidence' => 'high'
      },
      repositories: { family: {}, variant: {}, price: {}, stock: {} },
      label: { status: 'blocked', intents: [], slot_ops: [], response_goals: nil, block_reason: 'unsupported_schema' }
    },
    {
      id: 'malformed_bad_schema_version', category: 'malformed', critical: true, surface: 'both',
      scenario_key: 'scenario_1',
      plan: { 'schema_version' => 'not_a_real_schema', 'intents' => ['price'] },
      repositories: { family: {}, variant: {}, price: {}, stock: {} },
      label: { status: 'blocked', intents: [], slot_ops: [], response_goals: nil, block_reason: 'unsupported_schema' }
    },
    {
      # CRITICAL exact-quantity safety proof (Gap 2). `safety.exact_quantity_request` is an explicit
      # BOUNDED synthetic representation of the pre-existing backend-owned no-exact-quantity signal
      # (the legacy IntentExtractor's quantity_inquiry). It is an evaluation-only safety harness input,
      # NOT a new Candidate Plan field and NOT runtime authority. The Evaluator enforces the existing
      # no-exact-quantity policy BEFORE any adapter/planner/stock execution: even though this plan and
      # its repository fixtures describe a resolvable available-stock turn, the exact-quantity guard
      # short-circuits to a safe blocked/handoff outcome — strictly upstream of even the adapter's
      # Phase-1 policy gate — and the stock repository is never executed.
      id: 'exact_quantity_failclosed', category: 'exact_quantity', critical: true, surface: 'both',
      safety: { exact_quantity_request: true },
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'high' },
        'intents' => ['stock'],
        'slot_operations' => [
          { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => 'SYN-FAM-ALPHA', 'candidate_type' => 'family_code' } },
          {
            'operation' => 'set', 'slot' => 'variant_input',
            'value' => { 'raw_candidate' => 'SYN-VAR-ALPHA-01', 'candidate_type' => 'variant_code' }
          }
        ],
        'customer_language' => 'en', 'confidence' => 'high'
      },
      repositories: {
        family: { 'SYN-FAM-ALPHA' => { code: 'SYN-FAM-ALPHA', name: 'Synthetic Alpha' } },
        variant: { 'SYN-VAR-ALPHA-01' => { status: :resolved, code: 'SYN-VAR-ALPHA-01' } },
        price: {}, stock: { 'SYN-VAR-ALPHA-01' => :available }
      },
      label: { status: 'blocked', intents: [], slot_ops: [], response_goals: nil, block_reason: 'exact_quantity_request' }
    },
    {
      # Surface-aware parity proof (Gap 3). ONE labelled turn that the Evaluator folds through TWO
      # independently-declared bounded surface adapters (Conversation and Playground) that normalize
      # distinct surface-native envelopes back into the SAME canonical backend input, then requires the
      # adapter+planner fingerprints to be equal. `parity: true` selects the dual-surface harness.
      id: 'parity_price', category: 'parity', critical: false, surface: 'both', parity: true,
      scenario_key: 'scenario_1',
      plan: {
        'schema_version' => 'marine_decision_v1',
        'scenario_candidate' => { 'key' => 'scenario_1', 'confidence' => 'high' },
        'intents' => ['price'],
        'slot_operations' => [
          { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => 'SYN-FAM-ALPHA', 'candidate_type' => 'family_code' } },
          {
            'operation' => 'set', 'slot' => 'variant_input',
            'value' => { 'raw_candidate' => 'SYN-VAR-ALPHA-01', 'candidate_type' => 'variant_code' }
          }
        ],
        'customer_language' => 'en', 'confidence' => 'high'
      },
      repositories: {
        family: { 'SYN-FAM-ALPHA' => { code: 'SYN-FAM-ALPHA', name: 'Synthetic Alpha' } },
        variant: { 'SYN-VAR-ALPHA-01' => { status: :resolved, code: 'SYN-VAR-ALPHA-01' } },
        price: { 'SYN-VAR-ALPHA-01' => PRICE_ALPHA }, stock: {}
      },
      label: { status: 'product', intents: ['price'], slot_ops: %w[product variant_code], response_goals: ['answer_price'] }
    }
  ].freeze

  module_function

  def cases
    CASES
  end
end
# rubocop:enable Metrics/ModuleLength
