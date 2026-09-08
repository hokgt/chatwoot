# Phase 3 — Per-incoming-message processing claim. Guarantees that exactly one
# worker becomes the OWNER of a given incoming Message, so a duplicate delivery
# or a re-enqueued job cannot trigger a second round of catalog processing.
#
# The claim lives ENTIRELY inside the Message's own additional_attributes under a
# Marine-owned, versioned namespace:
#
#   additional_attributes['wijaya_marine_ai']['processing_claim_v1']
#
# It is deliberately NOT a generic top-level key. No Redis, cache, table, or
# migration is involved — only the existing Message row lock and public
# ActiveRecord APIs.
#
# A claim carries a lifecycle status: it is written 'processing' when acquired
# or reclaimed, and only its current owner may later mark it 'completed' via
# #complete! (a Phase 5 concern; not wired anywhere yet).
#
# Atomic compare-under-lock semantics (see #acquire!):
#   * no claim              -> acquire and become owner         (:acquired)
#   * fresh processing claim-> duplicate; NO second ownership   (:duplicate, owner: false)
#   * completed claim       -> permanent duplicate; NEVER reclaimed, regardless
#                              of age                            (:completed, owner: false)
#   * stale processing claim-> reclaim atomically, new identity (:reclaimed)
#   * malformed claim       -> reclaim, replacing only the claim namespace (:reclaimed)
#
# Completion (see #complete!) is tied to BOTH the exact incoming message.id and
# the current owner's claim_id, under the Message row lock. A stale old owner
# whose claim was reclaimed can never complete the new claim; a wrong claim_id,
# mismatched message_id, or missing/malformed claim fails safely (:conflict)
# without touching the claim or its siblings. Repeat completion by the current
# owner is idempotent.
#
# The result is a strict value object exposing only an allowlisted claim payload
# (claim_id, claimed_at, message_id, status, and completed_at once completed) —
# never a raw error. A reload/save failure propagates so a future job can retry.
class Marine::Conversation::ProcessingClaim
  FEATURE_KEY = 'wijaya_marine_ai'.freeze
  CLAIM_KEY = 'processing_claim_v1'.freeze

  # Result-level outcomes returned to the caller.
  STATUS_ACQUIRED = 'acquired'.freeze
  STATUS_DUPLICATE = 'duplicate'.freeze
  STATUS_RECLAIMED = 'reclaimed'.freeze
  STATUS_COMPLETED = 'completed'.freeze
  STATUS_CONFLICT = 'conflict'.freeze

  # Persisted claim lifecycle values (additional_attributes 'status').
  LIFECYCLE_PROCESSING = 'processing'.freeze
  LIFECYCLE_COMPLETED = 'completed'.freeze
  LIFECYCLE_STATUSES = [LIFECYCLE_PROCESSING, LIFECYCLE_COMPLETED].freeze

  MAX_CLAIM_ID_LENGTH = 120
  DEFAULT_STALE_AFTER = (5 * 60) # seconds

  Result = Struct.new(:status, :owner, :claim, keyword_init: true) do
    def owner?
      owner
    end

    def acquired?
      status == STATUS_ACQUIRED
    end

    def duplicate?
      status == STATUS_DUPLICATE
    end

    def reclaimed?
      status == STATUS_RECLAIMED
    end

    def completed?
      status == STATUS_COMPLETED
    end

    def conflict?
      status == STATUS_CONFLICT
    end
  end

  def initialize(message:, clock: nil, id_generator: nil, stale_after: DEFAULT_STALE_AFTER)
    @message = message
    @clock = clock || -> { Time.current }
    @id_generator = id_generator || -> { SecureRandom.uuid }
    @stale_after = stale_after
  end

  # Attempt to claim the message under its row lock, comparing against the latest
  # persisted claim. Returns a strict Result. Only an incoming Message may be
  # claimed; anything else fails explicitly WITHOUT writing a claim.
  def acquire!
    raise ArgumentError, 'ProcessingClaim requires an incoming Message' unless incoming_message?

    message.with_lock do
      raw = raw_claim
      existing = sanitize(raw)

      if raw.nil?
        write_claim(STATUS_ACQUIRED)
      elsif existing && completed?(existing)
        # A completed claim is a permanent duplicate: never reclaimed, even if stale.
        Result.new(status: STATUS_COMPLETED, owner: false, claim: existing)
      elsif existing && fresh?(existing)
        Result.new(status: STATUS_DUPLICATE, owner: false, claim: existing)
      else
        write_claim(STATUS_RECLAIMED)
      end
    end
  end

  # Mark this message's processing complete. Only the current owner (matching
  # claim_id on the latest persisted claim) may complete, under the Message row
  # lock. A wrong/replaced claim_id, mismatched message_id, or missing/malformed
  # claim yields STATUS_CONFLICT without any write. Repeat completion by the
  # current owner is idempotent (no second write). Suitable for Phase 5 to call;
  # deliberately not wired anywhere yet.
  def complete!(claim_id:)
    raise ArgumentError, 'ProcessingClaim requires an incoming Message' unless incoming_message?

    message.with_lock do
      existing = sanitize(raw_claim)

      if existing.nil? || existing['claim_id'] != claim_id
        Result.new(status: STATUS_CONFLICT, owner: false, claim: existing)
      elsif completed?(existing)
        Result.new(status: STATUS_COMPLETED, owner: true, claim: existing)
      else
        write_completion(existing)
      end
    end
  end

  # Side-effect-free read of the current allowlisted claim, or nil.
  def current
    sanitize(raw_claim)
  end

  private

  attr_reader :message, :stale_after

  def incoming_message?
    message.is_a?(::Message) && message.incoming?
  end

  def write_claim(status)
    Result.new(status: status, owner: true, claim: persist_claim(new_claim))
  end

  # Promote the current owner's processing claim to completed, preserving its
  # identity/claimed_at and stamping a completion time.
  def write_completion(existing)
    claim = existing.merge('status' => LIFECYCLE_COMPLETED, 'completed_at' => now.iso8601)
    Result.new(status: STATUS_COMPLETED, owner: true, claim: persist_claim(claim))
  end

  # Replace ONLY the claim namespace, preserving every top-level and Marine
  # sibling key.
  def persist_claim(claim)
    attributes = deep_dup_attributes
    feature = attributes[FEATURE_KEY]
    feature = feature.is_a?(Hash) ? feature.dup : {}
    feature[CLAIM_KEY] = claim
    attributes[FEATURE_KEY] = feature
    message.update!(additional_attributes: attributes)
    claim
  end

  def new_claim
    {
      'claim_id' => @id_generator.call.to_s[0, MAX_CLAIM_ID_LENGTH],
      'claimed_at' => now.iso8601,
      'message_id' => message.id,
      'status' => LIFECYCLE_PROCESSING
    }
  end

  def completed?(claim)
    claim['status'] == LIFECYCLE_COMPLETED
  end

  def raw_claim
    additional = message.additional_attributes
    return nil unless additional.is_a?(Hash)

    feature = additional[FEATURE_KEY]
    feature.is_a?(Hash) ? feature[CLAIM_KEY] : nil
  end

  # A claim is fresh while its age is under the stale window.
  def fresh?(claim)
    claimed_at = safe_time(claim['claimed_at'])
    claimed_at.present? && (now - claimed_at) < stale_after
  end

  # Fold an untrusted claim hash into the strict, allowlisted contract, or nil
  # when it is not a usable claim. A claim is bound to exactly one message: a
  # missing, invalid, or mismatched message_id is malformed and yields nil so the
  # caller reclaims (missing id / unparseable time / unknown lifecycle status do
  # the same — a claim without a valid 'status' is legacy/malformed and reclaimed,
  # never mistaken for completed). A completed claim additionally requires a
  # parseable completed_at.
  def sanitize(claim)
    return nil unless claim.is_a?(Hash)

    source = claim.transform_keys(&:to_s)
    base = base_claim(source)
    base && finalize_lifecycle(base, source)
  end

  # The required processing-claim shape bound to this exact message, or nil when a
  # required field is missing/invalid, the status is not an allowlisted lifecycle
  # value, or the message_id does not match this message.
  def base_claim(source)
    claim_id = bounded_string(source['claim_id'], MAX_CLAIM_ID_LENGTH)
    claimed_at = safe_time(source['claimed_at'])
    message_id = bounded_integer(source['message_id'])
    status = source['status'] if LIFECYCLE_STATUSES.include?(source['status'])
    return nil if claim_id.nil? || claimed_at.nil? || message_id != message.id || status.nil?

    { 'claim_id' => claim_id, 'claimed_at' => claimed_at.iso8601, 'message_id' => message_id, 'status' => status }
  end

  # A completed claim additionally requires a parseable completed_at, otherwise it
  # is malformed (nil); a processing claim passes through unchanged.
  def finalize_lifecycle(base, source)
    return base unless base['status'] == LIFECYCLE_COMPLETED

    completed_at = safe_time(source['completed_at'])
    return nil if completed_at.nil?

    base.merge('completed_at' => completed_at.iso8601)
  end

  def bounded_string(value, limit)
    return nil unless value.is_a?(String) || value.is_a?(Numeric)

    cleaned = value.to_s.gsub(/[[:cntrl:]]/, ' ').strip
    cleaned.empty? ? nil : cleaned[0, limit]
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
    attributes = message.additional_attributes
    (attributes.is_a?(Hash) ? attributes : {}).deep_dup
  end

  def now
    @clock.call
  end
end
