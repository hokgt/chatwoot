# Closed vocabulary + bounds for the battery-local Marine Decision Maker candidate
# plan (v1). This is the SINGLE source of truth for what an untrusted Decision Maker
# response is allowed to PROPOSE — and nothing more.
#
# Trust boundary: a candidate plan is a bounded suggestion only. It may nominate a
# scenario, name candidate (never validated) product/variant strings, and flag intent
# categories. It may NEVER assert a validated fact or an executable action:
# validated_variant_code, validated_family, price, stock, quantity, warehouse, a final
# action, reply text, a tool, SQL, or arbitrary state are all outside this contract and
# are rejected as unknown fields by the normalizer. No repository/DB/provider access
# lives here; this file is pure data.
module Marine::Decision::Schema
  # Only this exact version is accepted; any other value fails closed.
  SCHEMA_VERSION = 'marine_decision_v1'.freeze

  CONFIDENCE_LEVELS = %w[low medium high].freeze

  # Closed allowlist of CANDIDATE intent categories. These mirror Marine's currently
  # supported semantic categories (price/stock/parent_info/variant_info/catalog), the
  # informational product_overview, and the explicit unsupported bucket. order_status
  # and sample are included as CANDIDATE-ONLY, NON-EXECUTABLE intents: their presence in
  # a plan is a suggestion the runtime may act on in a later phase, never an authority to
  # fulfil an order or ship a sample here. product_listing/product_information are the Phase 3
  # bounded-catalog reads (a names-only listing vs listing+descriptions); price_range is the Phase 5
  # family-level selling-price-range read; they are executable only as SINGLE-intent sets on the
  # backend packet path (the backend-owned execution policy), never combined here. Array order is the
  # CANONICAL rendering order so a deduped intent set is deterministic regardless of the provider's ordering.
  INTENTS = %w[price price_range stock parent_info variant_info catalog product_overview product_listing product_information
               order_status sample unsupported].freeze

  # Contractually mutually-exclusive candidate-intent groups. product_listing and
  # product_information describe DISJOINT requests — a names/catalog availability listing
  # (no descriptions requested) vs an EXPLICIT request for a description/explanation/details —
  # so a single turn can propose at most ONE of them. Each inner array is one exclusive group;
  # the Decisions mapper enforces this over the typed NOUL probabilities (strictly-higher wins,
  # a tie fails closed), which is what keeps ExecutionPolicy's single-intent product
  # authorization reachable for these turns. This is a semantic protocol contract, never a
  # language-specific phrase list, and never widens authority.
  MUTUALLY_EXCLUSIVE_INTENTS = [%w[product_listing product_information].freeze].freeze

  # Slot mutation verbs and the two slots a plan may propose to change. A slot value is
  # always a CANDIDATE (raw string + a declared candidate_type), never a resolved or
  # validated selection.
  SLOT_OPERATIONS = %w[set replace clear].freeze
  SLOTS = %w[product variant_input].freeze

  # Per-slot allowlist of candidate types. A product candidate is either a display name
  # or a family_code candidate; a variant_input candidate is a variant_code, display_label,
  # or attribute_value candidate. Nothing else is accepted.
  CANDIDATE_TYPES = {
    'product' => %w[display_name family_code].freeze,
    'variant_input' => %w[variant_code display_label attribute_value].freeze
  }.freeze

  # Outcome reason codes. REASON_NORMALIZED marks a successfully normalized plan.
  # UNKNOWN_REASONS are the ONLY reasons a safe unknown/failure plan may carry — all are
  # opaque, allowlisted codes, never raw exception or provider prose.
  REASON_NORMALIZED = 'normalized'.freeze
  UNKNOWN_REASONS = %w[malformed_response unsupported_schema timeout provider_error unconfigured].freeze
  REASONS = ([REASON_NORMALIZED] + UNKNOWN_REASONS).freeze

  # Bounded, allowlisted FORMAT for the untrusted customer-language code: a 2–3 letter
  # primary subtag with an optional single subtag (e.g. "id", "en", "zh-hans"). This is a
  # format allowlist, not a language list. Mirrors the IntentExtractor shape.
  LANGUAGE_PATTERN = /\A[a-z]{2,3}(?:-[a-z0-9]{2,8})?\z/

  # Bounded, allowlisted FORMAT for a scenario key: canonical lowercase snake_case — a
  # leading letter then up to 119 more [a-z0-9_] chars (so 120 max, encoding the length
  # bound). A present, nonblank key must ALREADY match this; uppercase, hyphen, whitespace,
  # and punctuation forms are rejected fail-closed and never silently transformed.
  SCENARIO_KEY_PATTERN = /\A[a-z][a-z0-9_]{0,119}\z/

  # Exhaustive allowed key sets. Any key outside these — at the top level or nested —
  # fails the plan closed, so a plan can never smuggle an out-of-contract field (e.g.
  # price, stock, reply, action, validated_variant_code) past the boundary. `reason` is a
  # normalizer-owned OUTCOME code: it is an allowed top-level key but any value the
  # provider supplies for it is ignored (the normalizer sets it itself).
  TOP_LEVEL_KEYS = %w[schema_version scenario_candidate intents slot_operations customer_language confidence reason].freeze
  SCENARIO_KEYS = %w[key confidence].freeze
  SLOT_OPERATION_KEYS = %w[operation slot value].freeze
  VALUE_KEYS = %w[raw_candidate candidate_type].freeze

  # Conservative bounds so hostile/oversized input can never blow up downstream. The
  # scenario key's length bound is enforced by SCENARIO_KEY_PATTERN above.
  MAX_RAW_CANDIDATE_LENGTH = 120
  # Distinct intents that may survive in one plan (mirrors IntentExtractor's cap of 4).
  MAX_INTENTS = 4
  # Anti-DoS guard on the RAW length of the intents / slot_operations arrays before any
  # per-element work; distinct-count and duplicate rules narrow further.
  MAX_RAW_ARRAY = 32
end
