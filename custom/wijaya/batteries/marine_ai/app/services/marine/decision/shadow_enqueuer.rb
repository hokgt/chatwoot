require 'securerandom'

# DEFAULT-OFF, fail-safe scheduler for the asynchronous Marine Decision shadow (Phase 2 /
# Stage 4). Called by Wijaya::Marine::Hooks ONLY after the normal Marine response job was
# successfully scheduled. It never influences the primary hook: every config/Redis/job error
# returns false and never propagates.
#
#   * Default-off: when the shadow flag is not the exact true representation it does NOTHING —
#     no Redis call and no job enqueue at all.
#   * When enabled it deduplicates per account+message with a feature-specific, bounded-TTL
#     NX marker so the same inbound turn is shadowed at most once per window, passes SCALAR
#     IDs only to the job, and enqueues Marine::Decision::ShadowJob.
#   * It returns true ONLY when the job genuinely enqueued: a false/nil perform_later result,
#     a job whose #successfully_enqueued? is false, or a job carrying a non-nil #enqueue_error
#     all count as a failed enqueue. On any failed OR raised enqueue the NX marker is released
#     with a compare-and-delete of the token THIS attempt wrote (so a safe retry remains
#     possible and no unrelated key is touched) and the method returns false.
#
# No broad Redis scan/delete: only the one prefixed, per-message key is set or released.
class Marine::Decision::ShadowEnqueuer
  # Feature-specific, versioned key prefix — never a broad pattern.
  KEY_PREFIX = 'marine:decision:shadow:v1'.freeze
  # Bounded lifetime for the per-message dedupe marker.
  DEDUPE_TTL_SECONDS = 3600

  def self.enqueue(conversation:, message:)
    new(conversation: conversation, message: message).enqueue
  end

  def initialize(conversation:, message:)
    @conversation = conversation
    @message = message
  end

  # Returns true only when a ShadowJob was enqueued; false on default-off, a duplicate, or
  # ANY config/Redis/job failure. Never raises.
  def enqueue
    return false unless Marine::Decision::ShadowConfig.enabled?

    account = @conversation.account
    assistant = @conversation.inbox&.try(:marine_assistant)
    return false if account.nil? || assistant.nil?

    schedule(account, assistant)
  rescue StandardError
    false
  end

  private

  def schedule(account, assistant)
    key = dedupe_key(account.id, @message.id)
    token = SecureRandom.hex(16)
    # NX+TTL: only the first turn to claim the key proceeds; a duplicate returns falsy.
    return false unless Redis::Alfred.set(key, token, nx: true, ex: DEDUPE_TTL_SECONDS)

    enqueued =
      begin
        Marine::Decision::ShadowJob.perform_later(account.id, assistant.id, @conversation.id, @message.id)
      rescue StandardError
        nil
      end
    return true if enqueue_succeeded?(enqueued)

    # The job did not genuinely enqueue: release ONLY the marker this attempt owns
    # (compare-and-delete) so a safe retry can re-claim it, then fail closed. A delete failure
    # propagates to #enqueue's rescue, which still returns false and touches no other key.
    Redis::Alfred.delete_if_equals(key, token)
    false
  end

  # True only when perform_later's result proves a genuine enqueue: a false/nil result, a job
  # whose #successfully_enqueued? is false, or a job carrying a non-nil #enqueue_error is a
  # failure. A legacy/test truthy object exposing neither API counts as success. Any error while
  # checking fails closed to false.
  def enqueue_succeeded?(enqueued)
    return false unless enqueued
    return enqueued.successfully_enqueued? if enqueued.respond_to?(:successfully_enqueued?)
    return false if enqueued.respond_to?(:enqueue_error) && !enqueued.enqueue_error.nil?

    true
  rescue StandardError
    false
  end

  def dedupe_key(account_id, message_id)
    "#{KEY_PREFIX}:#{account_id}:#{message_id}"
  end
end
