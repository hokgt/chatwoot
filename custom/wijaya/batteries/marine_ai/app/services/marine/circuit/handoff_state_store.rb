# Phase 1 — Namespaced handoff lifecycle marker for a single Conversation. Owns the
# durable, allowlisted, bounded record that makes Marine's circuit handoff idempotent,
# stored ENTIRELY inside the Conversation's own additional_attributes under the same
# Marine-owned namespace ProductFlowStateStore uses:
#
#   additional_attributes['wijaya_marine_ai']['handoff_v1']
#
# Design contract / trust boundary:
#   * Only lifecycle metadata persists — status, version, an announced_at timestamp,
#     and the ids of the messages the handoff created. No raw customer text, raw error,
#     secret, or business fact is ever stored. Anything outside FIELDS is dropped.
#   * Once announced, the marker stays active for the whole applicable channel messaging
#     window. Resolving or reopening the same Conversation does NOT clear it. It is cleared
#     ONLY by #reset!, and only when a new inbound customer turn arrives after that window
#     has lapsed with no human takeover (see Marine::Circuit::HandoffWindow and
#     Wijaya::Marine::Hooks) — never by a timer, so window expiry alone emits nothing.
#   * The mutation runs under a Conversation row lock that reloads the latest
#     additional_attributes first, preserving every UNRELATED top-level key and every
#     SIBLING under wijaya_marine_ai (e.g. product_flow_v1); only handoff_v1 is written.
#   * activate! is idempotent: an already-active marker is returned untouched, never
#     re-versioned, so a replayed or concurrent handoff can never overwrite it.
class Marine::Circuit::HandoffStateStore
  FEATURE_KEY = 'wijaya_marine_ai'.freeze
  HANDOFF_KEY = 'handoff_v1'.freeze

  STATUS_ACTIVE = 'active'.freeze
  STATUSES = [STATUS_ACTIVE].freeze

  # Bounded lifecycle keys. Nothing outside this set persists.
  FIELDS = %w[version status announced_at message_ids].freeze

  # A first handoff creates at most two messages: an optional private reason note and
  # the public handoff message. Cap the stored ids to that evidence-based maximum.
  MAX_MESSAGE_IDS = 2

  def initialize(conversation:, clock: nil)
    @conversation = conversation
    @clock = clock || -> { Time.current }
  end

  # Side-effect-free read of the current allowlisted marker, or nil when there is
  # none / it is malformed.
  def current
    sanitize(raw_marker)
  end

  # Fail closed. Presence of the handoff_v1 KEY is detected separately from its value:
  # an ABSENT key is inactive (Marine may still act); any PRESENT key is terminal -- a
  # well-formed active marker AND a present-but-unusable value (null, malformed hash,
  # non-hash, or unknown version/status) all read active, so a corrupted marker can
  # never let Marine re-engage or re-announce a handed-off conversation. Reading never
  # repairs it.
  def active?
    return false unless marker_present?

    marker = sanitize(raw_marker)
    marker.nil? || marker['status'] == STATUS_ACTIVE
  end

  # Persist the active handoff marker (version 1) under a row lock, preserving every
  # sibling namespace/key. Presence of the handoff_v1 KEY is authoritative: only a
  # truly ABSENT key creates a fresh marker. A present valid-active marker is returned
  # sanitized and untouched (same version, announced_at, message_ids); a present-but-
  # unusable value (null / malformed) is returned as-is and never written or repaired,
  # so a replay -- or a direct call over corrupt state -- can never overwrite it.
  def activate!(message_ids: [])
    conversation.with_lock do
      if marker_present?
        existing = sanitize(raw_marker)
        next existing if existing && existing['status'] == STATUS_ACTIVE

        next raw_marker
      end

      persist!(fresh_marker(message_ids))
    end
  end

  # Clear the handoff marker so a new customer turn can start a fresh Marine interaction once
  # the applicable channel messaging window has lapsed. Removes ONLY the handoff_v1 key under
  # the Conversation row lock, preserving every unrelated top-level key and every Marine
  # sibling (e.g. product_flow_v1). Idempotent: a no-op when the key is absent. Never creates
  # a message or any outbound content — it is a pure lifecycle reset, invoked only by an
  # inbound turn (Wijaya::Marine::Hooks), so window expiry by itself can never trigger it.
  def reset!
    conversation.with_lock do
      next unless marker_present?

      attributes = deep_dup_attributes
      feature = attributes[FEATURE_KEY]
      feature = feature.is_a?(Hash) ? feature.dup : {}
      feature.delete(HANDOFF_KEY)
      attributes[FEATURE_KEY] = feature
      conversation.update!(additional_attributes: attributes)
    end
  end

  private

  attr_reader :conversation

  def persist!(marker)
    attributes = deep_dup_attributes
    feature = attributes[FEATURE_KEY]
    feature = feature.is_a?(Hash) ? feature.dup : {}
    feature[HANDOFF_KEY] = marker
    attributes[FEATURE_KEY] = feature
    conversation.update!(additional_attributes: attributes)
    marker
  end

  def fresh_marker(message_ids)
    {
      'version' => 1,
      'status' => STATUS_ACTIVE,
      'announced_at' => now.iso8601,
      'message_ids' => bounded_ids(message_ids)
    }
  end

  def raw_marker
    additional = conversation.additional_attributes
    feature = additional[FEATURE_KEY] if additional.is_a?(Hash)
    feature[HANDOFF_KEY] if feature.is_a?(Hash)
  end

  # True only when the handoff_v1 KEY is present under the Marine namespace, whatever
  # its value. Distinguishes an absent key (inactive) from a present null/malformed one
  # (terminal), which raw_marker alone cannot: both surface as nil there.
  def marker_present?
    additional = conversation.additional_attributes
    return false unless additional.is_a?(Hash)

    feature = additional[FEATURE_KEY]
    feature.is_a?(Hash) && feature.key?(HANDOFF_KEY)
  end

  # Fold an untrusted marker hash into the strict, bounded contract, or nil when it is
  # not a usable hash OR is missing/invalid on a required lifecycle field. Reading
  # never fabricates lifecycle values: a malformed blob reads as nil.
  def sanitize(marker)
    return nil unless marker.is_a?(Hash)

    source = marker.transform_keys(&:to_s)
    version = bounded_integer(source['version'])
    status = valid_status(source['status'])
    announced_at = safe_time(source['announced_at'])&.iso8601
    return nil unless lifecycle_valid?(version, status, announced_at)

    {
      'version' => version,
      'status' => status,
      'announced_at' => announced_at,
      'message_ids' => bounded_ids(source['message_ids'])
    }
  end

  # All required lifecycle fields present and in range. Mirrors the original guard's
  # fail-closed semantics: a nil/sub-1 version, nil status, or nil announced_at is invalid.
  def lifecycle_valid?(version, status, announced_at)
    !version.nil? && version >= 1 && !status.nil? && !announced_at.nil?
  end

  def valid_status(value)
    value if STATUSES.include?(value)
  end

  def bounded_ids(value)
    Array(value).filter_map { |id| bounded_integer(id) }.select(&:positive?).uniq.first(MAX_MESSAGE_IDS)
  end

  def bounded_integer(value)
    case value
    when Integer then value
    when String then value.match?(/\A-?\d+\z/) ? value.to_i : nil
    end
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
