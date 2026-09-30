# DEFAULT-OFF, asynchronous, fire-and-forget shadow of the isolated Marine Decision Runner
# (Phase 2 / Stage 4). Enqueued ONLY by Marine::Decision::ShadowEnqueuer after the normal
# Marine response job was scheduled, and only when the shadow is explicitly enabled.
#
# Its arguments are SCALAR IDs only. At execution time it re-checks the shadow flag, loads
# each record account-scoped, and validates the message is a public incoming turn — every
# check fails closed (silent return). It runs Marine::Decision::ShadowExecution purely to
# exercise the comparison and INTENTIONALLY DISCARDS the result: Stage 4 persists, logs,
# publishes, or metrics NOTHING. Any failure is swallowed without re-raising and without
# touching any reply/routing/state path; no raw error or customer text is logged.
class Marine::Decision::ShadowJob < ApplicationJob
  queue_as :low

  def perform(account_id, assistant_id, conversation_id, message_id)
    return unless Marine::Decision::ShadowConfig.enabled?

    records = load_records(account_id, assistant_id, conversation_id, message_id)
    return if records.nil?

    # Result deliberately discarded — Stage 4 is shadow-only (no persist/log/metric).
    Marine::Decision::ShadowExecution.new(**records).call
    nil
  rescue StandardError
    # Fire-and-forget: swallow everything so the shadow can never affect the primary flow.
    # No exception tracker / logger call — no raw error or customer text is emitted.
    nil
  end

  private

  # Account-scoped, fail-closed record load. Returns the four records as a keyword-arg hash
  # for ShadowExecution, or nil when any is missing or the message is not a public incoming
  # turn. Scoping runs account -> assistant -> conversation -> message so a mismatched id can
  # never cross an account boundary.
  def load_records(account_id, assistant_id, conversation_id, message_id)
    account = Account.find_by(id: account_id)
    return if account.nil?

    assistant = Marine::Assistant.find_by(id: assistant_id, account_id: account.id)
    return if assistant.nil?

    conversation = account.conversations.find_by(id: conversation_id)
    return if conversation.nil?

    message = conversation.messages.find_by(id: message_id)
    return unless message && public_incoming?(message)

    { account: account, assistant: assistant, conversation: conversation, message: message }
  end

  def public_incoming?(message)
    message.incoming? && !message.private?
  end
end
