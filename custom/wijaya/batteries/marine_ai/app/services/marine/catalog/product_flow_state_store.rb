# Phase 3 — Namespaced product-flow state for a single Conversation. Owns the
# durable, allowlisted, bounded state blob that the (not-yet-wired) catalog
# orchestration will reason over, stored ENTIRELY inside the Conversation's own
# additional_attributes under a Marine-owned namespace:
#
#   additional_attributes['wijaya_marine_ai']['product_flow_v1']
#
# Design contract / trust boundary:
#   * Only the keys in FIELDS may persist. Anything else a caller passes — a raw
#     LLM response, a raw error, SQL, a numeric stock/quantity, warehouse detail,
#     or a dynamic price — is silently DROPPED. State is bounded metadata about
#     the flow, never a raw fact.
#   * Every mutation runs under a Conversation row lock that reloads the latest
#     additional_attributes first, so a stale in-memory copy can never clobber a
#     concurrent writer. Every UNRELATED top-level key and every SIBLING under
#     wijaya_marine_ai is preserved; only product_flow_v1 is replaced.
#   * version increments deterministically: a fresh flow is version 1, and each
#     later successful mutation is the previous version + 1.
#   * A reload/merge/save failure propagates (with_lock re-raises); this service
#     never fabricates success, so a future job can retry.
module Marine
  module Catalog
    # rubocop:disable Metrics/ClassLength -- a single cohesive trust boundary: the bounded,
    # allowlisted field set plus its strict read-validation/normalization and row-locked
    # mutations belong together; splitting them would obscure the one-object contract.
    class ProductFlowStateStore
      FEATURE_KEY = 'wijaya_marine_ai'.freeze
      FLOW_KEY = 'product_flow_v1'.freeze

      STATUS_ACTIVE = 'active'.freeze
      STATUS_EXPIRED = 'expired'.freeze
      STATUS_COMPLETED = 'completed'.freeze
      STATUSES = [STATUS_ACTIVE, STATUS_EXPIRED, STATUS_COMPLETED].freeze

      # Phase 3 clarification-progression metadata. clarification_kind is an ENUM (a
      # family-vs-variant clarification), clarification_count a SMALL bounded integer. A
      # persisted value outside this enum/range is dropped on read (treated as no prior
      # occurrence), so malformed/forged clarification state can never be trusted to
      # force a handoff. The orchestrator only ever persists counts 1..MAX (a third
      # occurrence hands off without persisting), so MAX_CLARIFICATION_COUNT bounds it.
      CLARIFICATION_KIND_FAMILY = 'family'.freeze
      CLARIFICATION_KIND_VARIANT = 'variant'.freeze
      CLARIFICATION_KINDS = [CLARIFICATION_KIND_FAMILY, CLARIFICATION_KIND_VARIANT].freeze
      MAX_CLARIFICATION_COUNT = 2

      # Allowlisted, bounded state keys. Nothing outside this set persists.
      # original_intent records the intent the flow opened with; current_intent
      # tracks the (possibly switched) intent the flow is now serving. A legacy
      # singular `intent` key is not allowlisted, so it is dropped like any other
      # unknown key (no silent migration into original/current).
      STRING_FIELDS = %w[flow_id original_intent current_intent validated_family validated_variant].freeze
      INTEGER_FIELDS = %w[origin_message_id last_relevant_message_id catalog_document_id catalog_message_id].freeze
      BOOLEAN_FIELDS = %w[catalog_sent].freeze
      # Bounded clarification metadata, validated/normalized separately (enum + range + bounded
      # code set). clarification_kind/count track the occurrence; clarification_family_codes is the
      # bounded, normalized candidate-family-code SET that gives a FAMILY clarification its durable
      # slot identity (a variant clarification reuses validated_family + expected_attributes). None
      # of these is raw customer text or a fact — the identity never depends on the volatile
      # per-turn current_intent.
      CLARIFICATION_FIELDS = %w[clarification_kind clarification_count clarification_family_codes].freeze
      FIELDS = (%w[version status expires_at expected_attributes] +
                STRING_FIELDS + INTEGER_FIELDS + BOOLEAN_FIELDS + CLARIFICATION_FIELDS).freeze
      # version and flow_id are owned by the store; callers may set everything else.
      CALLER_FIELDS = (FIELDS - %w[version flow_id]).freeze

      DEFAULT_TTL = (24 * 60 * 60) # seconds

      MAX_STRING_LENGTH = 120
      MAX_ATTRIBUTES = 16
      MAX_ATTRIBUTE_LENGTH = 80

      # Canonical, trust-boundary-owned normalization of an expected-attributes list, applying
      # EXACTLY the persisted bounded_array semantics: clean/strip control characters, reject
      # blanks, truncate each item to MAX_ATTRIBUTE_LENGTH, de-duplicate, and cap at
      # MAX_ATTRIBUTES (order preserved). Owned here so the orchestrator can reuse it for
      # clarification identity/comparison AND the state changes it plans, so the structured
      # state it reasons over and the value later persisted here normalize IDENTICALLY — a
      # pathological repository list can never split occurrence 1 from occurrence 2. A
      # non-array normalizes to []. Persistence sanitization (bounded_array) delegates here.
      def self.normalize_expected_attributes(value)
        return [] unless value.is_a?(Array)

        value.filter_map { |item| normalize_bounded_string(item, MAX_ATTRIBUTE_LENGTH) }.uniq.first(MAX_ATTRIBUTES)
      end

      # Shared per-item bounded-string cleaner (control characters -> space, strip, reject
      # blank, truncate): a single trust-boundary definition governs both expected-attribute
      # normalization and per-field string bounds so the two can never drift apart.
      def self.normalize_bounded_string(value, limit)
        return nil unless value.is_a?(String) || value.is_a?(Numeric)

        cleaned = value.to_s.gsub(/[[:cntrl:]]/, ' ').strip
        cleaned.empty? ? nil : cleaned[0, limit]
      end
      private_class_method :normalize_bounded_string

      def initialize(conversation:, clock: nil, id_generator: nil)
        @conversation = conversation
        @clock = clock || -> { Time.current }
        @id_generator = id_generator || -> { SecureRandom.uuid }
      end

      # Side-effect-free read of the current allowlisted flow, or nil when there
      # is none / it is malformed.
      def current
        sanitize(raw_flow)
      end

      # Read-only EFFECTIVE planning snapshot for the orchestrator. Identical to #current,
      # except an ACTIVE flow whose expiry has elapsed against the (injected/current) clock
      # is returned as an in-memory copy with status 'expired' — WITHOUT persisting the
      # transition or bumping the version. Reasoning must never mutate flow state, so the
      # real #expire! transition is deferred to a later finalization phase. A missing/malformed
      # flow stays nil (strict fail-closed), and an already expired/completed flow is returned
      # unchanged (still inactive). Every sibling/top-level key is untouched (no write happens).
      def current_for_planning
        flow = current
        return flow if flow.nil?
        return flow.merge('status' => STATUS_EXPIRED) if flow['status'] == STATUS_ACTIVE && expired?(flow)

        flow
      end

      def active?
        flow = current
        flow.present? && flow['status'] == STATUS_ACTIVE && !expired?(flow)
      end

      def expired?(flow = current)
        return false if flow.blank?

        parsed = safe_time(flow['expires_at'])
        parsed.present? && parsed <= now
      end

      # --- In-memory (NON-PERSISTING) snapshot transforms -----------------------------
      #
      # The source-less Playground preview carries product-flow state in an opaque signed token
      # instead of a persisted Conversation, so it needs the EXACT allowlisting, bounding, and
      # lifecycle semantics of the persisted #current / #current_for_planning / #start! / #update!
      # path WITHOUT any row lock or DB write. These pure methods reuse fresh_flow / allowlist /
      # seed_intent / sanitize / expiry so a preview and a real conversation normalize and
      # transition identical state. A store used ONLY for these may be built with conversation: nil.

      # Fold an untrusted snapshot into the strict bounded contract (identical read-validation to
      # #current), or nil when it is not a usable flow. Nothing outside FIELDS survives.
      def normalize_snapshot(flow)
        sanitize(flow)
      end

      # Read-only EFFECTIVE planning snapshot (the in-memory twin of #current_for_planning): an
      # ACTIVE flow whose expiry has elapsed reads as 'expired' WITHOUT mutating anything, so the
      # orchestrator never reuses an expired flow's validated family/variant/catalog markers.
      def snapshot_for_planning(flow)
        flow = normalize_snapshot(flow)
        return flow if flow.nil?
        return flow.merge('status' => STATUS_EXPIRED) if flow['status'] == STATUS_ACTIVE && expired?(flow)

        flow
      end

      # Apply a deterministic orchestrator state operation to an in-memory snapshot and return the
      # next normalized snapshot — the non-persisting twin of #start! / #update!. :start begins a
      # fresh flow (clearing every prior variant/attribute/catalog marker); :update bumps the
      # version and merges allowlisted changes (original_intent immutable); :none returns the
      # normalized prior snapshot unchanged.
      def apply_snapshot(existing, operation:, changes: {})
        case operation
        when :start then sanitize(fresh_flow.merge(seed_intent(allowlist(changes))))
        when :update then update_snapshot(normalize_snapshot(existing), allowlist(changes))
        else normalize_snapshot(existing)
        end
      end

      # Begin a brand-new flow: version 1, a fresh flow_id, an expiry, status
      # active. Replaces any prior (valid, malformed, or expired) product_flow_v1
      # while preserving every sibling.
      def start!(attrs = {})
        transform! { |_existing| fresh_flow.merge(seed_intent(allowlist(attrs))) }
      end

      # Mutate the current flow: version + 1, merging allowlisted attrs. A missing
      # or malformed current flow resets to a fresh flow (version 1) rather than
      # raising, per the Phase 3 reset contract.
      def update!(attrs = {})
        transform! do |existing|
          changes = allowlist(attrs)
          if existing
            # original_intent is immutable within a flow: only start! (or a fresh
            # reset below) may establish it. current_intent may still change here.
            existing.merge(changes.except('original_intent')).merge('version' => existing['version'].to_i + 1)
          else
            fresh_flow.merge(seed_intent(changes))
          end
        end
      end

      # Transition an existing flow to expired (a version-bumping mutation).
      # No-op returning nil when there is no valid flow to expire.
      def expire!
        transform! do |existing|
          next nil if existing.nil?

          existing.merge('status' => STATUS_EXPIRED, 'version' => existing['version'].to_i + 1)
        end
      end

      # Remove ONLY product_flow_v1, preserving every sibling and top-level key.
      def reset!
        conversation.with_lock do
          attributes = deep_dup_attributes
          feature = attributes[FEATURE_KEY]
          next unless feature.is_a?(Hash)

          feature = feature.dup
          feature.delete(FLOW_KEY)
          attributes[FEATURE_KEY] = feature
          conversation.update!(additional_attributes: attributes)
        end
        nil
      end

      private

      attr_reader :conversation

      # Under a row lock: reload latest attributes, derive the next flow from the
      # latest existing flow, sanitize, and persist while preserving all siblings.
      def transform!
        conversation.with_lock do
          existing = sanitize(raw_flow)
          next_flow = yield(existing)
          next_flow.nil? ? nil : persist!(sanitize(next_flow))
        end
      end

      # In-memory :update twin used by #apply_snapshot: bump the version and merge already-
      # allowlisted changes onto an existing normalized snapshot (original_intent immutable), or
      # seed a fresh flow when there is none — exactly #update!'s block minus the lock/persist.
      def update_snapshot(existing, changes)
        next_flow =
          if existing
            existing.merge(changes.except('original_intent')).merge('version' => existing['version'].to_i + 1)
          else
            fresh_flow.merge(seed_intent(changes))
          end
        sanitize(next_flow)
      end

      def persist!(flow)
        attributes = deep_dup_attributes
        feature = attributes[FEATURE_KEY]
        feature = feature.is_a?(Hash) ? feature.dup : {}
        feature[FLOW_KEY] = flow
        attributes[FEATURE_KEY] = feature
        conversation.update!(additional_attributes: attributes)
        flow
      end

      def fresh_flow
        {
          'version' => 1,
          'flow_id' => @id_generator.call.to_s[0, MAX_STRING_LENGTH],
          'status' => STATUS_ACTIVE,
          'expires_at' => (now + DEFAULT_TTL).iso8601,
          'expected_attributes' => []
        }
      end

      def raw_flow
        additional = conversation.additional_attributes
        feature = additional[FEATURE_KEY] if additional.is_a?(Hash)
        feature[FLOW_KEY] if feature.is_a?(Hash)
      end

      # Caller attrs are untrusted input, normalized before merging into a fresh
      # or existing flow: drop non-allowlisted keys and coerce an unknown/invalid
      # caller status back to active so it never poisons the strict persisted
      # write. This is distinct from persisted-read validation (base_flow), which
      # stays strict and treats an unknown persisted status as malformed.
      def allowlist(attrs)
        return {} unless attrs.is_a?(Hash)

        sliced = attrs.transform_keys(&:to_s).slice(*CALLER_FIELDS)
        sliced['status'] = STATUS_ACTIVE if sliced.key?('status') && valid_status(sliced['status']).nil?
        sliced
      end

      # For a fresh flow, initialize original_intent and current_intent to the SAME
      # value so both open together: current_intent wins when supplied, else
      # original_intent; if a conflicting pair is given, the caller's current_intent
      # is the new-flow intent and therefore seeds both. If neither is supplied, no
      # intent is written. original_intent never changes after this point (update!
      # strips it), so it preserves the intent the flow opened with.
      def seed_intent(changes)
        seed = changes['current_intent'] || changes['original_intent']
        return changes if seed.nil?

        changes.merge('original_intent' => seed, 'current_intent' => seed)
      end

      # Fold an untrusted flow hash into the strict, bounded contract, or nil when
      # it is not a usable hash OR is missing/invalid on any required lifecycle
      # field. Reading persisted state NEVER fabricates identity/lifecycle values
      # (no generated flow_id, no coerced version/status): a malformed blob reads
      # as nil so mutation resets only product_flow_v1 to a fresh version-1 flow.
      # Fresh flows (fresh_flow) already carry a valid required shape, so writes
      # sanitize cleanly. Keys outside FIELDS are dropped entirely.
      def sanitize(flow)
        return nil unless flow.is_a?(Hash)

        source = flow.transform_keys(&:to_s)
        base = base_flow(source)
        return nil if base.nil?

        base.merge(optional_fields(source))
      end

      # The minimum required persisted lifecycle shape, or nil when any required
      # field is missing/invalid. expected_attributes is normalized (never a
      # cause of invalidity).
      def base_flow(source)
        # version is valid only when it parses to an integer >= 1 (nil short-circuits
        # before the comparison, so an unparseable version reads as malformed).
        version = bounded_integer(source['version'])
        flow_id = bounded_string(source['flow_id'], MAX_STRING_LENGTH)
        status = valid_status(source['status'])
        expires_at = safe_time(source['expires_at'])&.iso8601
        return nil if version.nil? || version < 1 || flow_id.nil? || status.nil? || expires_at.nil?

        {
          'version' => version,
          'flow_id' => flow_id,
          'status' => status,
          'expires_at' => expires_at,
          'expected_attributes' => bounded_array(source['expected_attributes'])
        }
      end

      def optional_fields(source)
        fields = {}
        (STRING_FIELDS - %w[flow_id]).each { |k| fields[k] = bounded_string(source[k], MAX_STRING_LENGTH) }
        INTEGER_FIELDS.each { |k| fields[k] = bounded_integer(source[k]) }
        BOOLEAN_FIELDS.each { |k| fields[k] = boolean(source[k]) if source.key?(k) }
        fields.merge(clarification_metadata(source)).compact
      end

      # The bounded clarification-progression metadata, each field strictly validated (enum /
      # range / bounded code set) so a forged/malformed value reads as nil and drops on compact.
      def clarification_metadata(source)
        {
          'clarification_kind' => clarification_kind(source['clarification_kind']),
          'clarification_count' => clarification_count(source['clarification_count']),
          'clarification_family_codes' => clarification_family_codes(source['clarification_family_codes'])
        }
      end

      # A persisted clarification kind is trusted only when it is one of the enum values;
      # anything else reads as nil (dropped by compact -> no prior occurrence).
      def clarification_kind(value)
        value if CLARIFICATION_KINDS.include?(value)
      end

      # A persisted clarification count is trusted only when it parses to an integer within
      # 1..MAX; a forged/out-of-range value reads as nil so it can never force a handoff.
      def clarification_count(value)
        parsed = bounded_integer(value)
        parsed if parsed && parsed >= 1 && parsed <= MAX_CLARIFICATION_COUNT
      end

      # A persisted candidate-family-code set is canonicalized through the same bounded
      # normalization as expected_attributes (control-stripped, blank-rejected, deduplicated,
      # capped); an empty/absent/non-array value reads as nil (dropped by compact), so the field
      # only persists on a genuine FAMILY clarification and never pollutes an unrelated flow.
      def clarification_family_codes(value)
        self.class.normalize_expected_attributes(value).presence
      end

      # A persisted status is valid only when it is one of the allowlisted values.
      def valid_status(value)
        value if STATUSES.include?(value)
      end

      def bounded_string(value, limit)
        self.class.send(:normalize_bounded_string, value, limit)
      end

      def bounded_integer(value)
        case value
        when Integer then value
        when String then value.match?(/\A-?\d+\z/) ? value.to_i : nil
        end
      end

      def boolean(value)
        case value
        when true, false then value
        when String then %w[true yes 1].include?(value.strip.downcase)
        when Numeric then value == 1
        else false
        end
      end

      def bounded_array(value)
        self.class.normalize_expected_attributes(value)
      end

      def safe_time(value)
        return value if value.is_a?(Time)

        Time.iso8601(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def deep_dup_attributes
        attributes = conversation.additional_attributes
        (attributes.is_a?(Hash) ? attributes : {}).deep_dup
      end

      def now
        @clock.call
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
