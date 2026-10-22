require 'securerandom'

# Fase 3A-2 — DEFAULT-OFF, asynchronous, fire-and-forget PRODUCT-authority shadow. Enqueued ONLY by
# Marine::ProductAuthority::ShadowEnqueuer after the normal Marine response job was scheduled, and only
# when the product shadow is explicitly enabled for the assistant.
#
# Its arguments are SCALAR IDs only. At execution time it re-checks the assistant-scoped product
# shadow flag (ShadowConfig.shadow_enabled_for?) with the SCALAR id, loads each record account-scoped,
# and re-checks with the LOADED assistant id BEFORE running the execution — so the legacy extractor /
# Decision Runner / adapter is never exercised for an assistant that is not allowlisted (or after a
# rollback). Every check fails closed (silent return).
#
# It then runs Marine::ProductAuthority::ShadowExecution and converts a successful comparison into a
# privacy-safe Marine::ProductAuthority::ShadowObservation, recording AGGREGATE counters via
# Marine::ProductAuthority::ShadowMetricsStore. A nil execution records NO fake comparison. The metrics
# result is ignored and every observation/metrics failure is swallowed. The shadow result NEVER
# influences the primary reply/routing/state/action/handoff/delivery path; no retry, raise, log, or
# raw error/customer text is emitted.
#
# AGGREGATE recording is made IDEMPOTENT against a duplicate/redelivered ActiveJob using this job's
# stable, non-customer ActiveJob `job_id` (a UUID) as a versioned Redis NX completion marker. AFTER a
# valid observation but BEFORE the metrics increment the marker is claimed with a random owner token; a
# duplicate/failed claim skips the increment, so the same delivery can never count twice. If the record
# then fails the marker is released (compare-and-delete of this owner) so a safe retry can still
# record; on success the marker is retained until its bounded TTL. The marker key carries ONLY the
# job_id — never an account/message/conversation/contact/inbox id.
class Marine::ProductAuthority::ShadowJob < ApplicationJob
  Config = Marine::ProductAuthority::ShadowConfig

  queue_as :low

  COMPLETION_KEY_PREFIX = 'marine:product_authority:shadow:done:v1'.freeze
  COMPLETION_TTL_SECONDS = Marine::ProductAuthority::ShadowMetricsStore::TTL_SECONDS
  JOB_ID_PATTERN = /\A[0-9a-zA-Z-]{8,64}\z/

  def perform(account_id, assistant_id, conversation_id, message_id)
    return unless Config.shadow_enabled_for?(assistant_id)

    records = load_records(account_id, assistant_id, conversation_id, message_id)
    return if records.nil?

    # Re-check with the LOADED assistant id after the scoped load so nothing runs for an assistant
    # that is no longer allowlisted (or after a rollback).
    return unless Config.shadow_enabled_for?(records[:assistant].id)

    result = Marine::ProductAuthority::ShadowExecution.new(**records).call
    return if result.nil? # nil execution: record NO fake comparison.

    record_metrics(records, result)
    nil
  rescue StandardError
    # Fire-and-forget: swallow everything so the shadow can never affect the primary flow. No
    # exception tracker / logger call — no raw error or customer text is emitted.
    nil
  end

  private

  def record_metrics(records, result)
    observation = Marine::ProductAuthority::ShadowObservation.build(
      result: result,
      account_id: records[:account].id,
      assistant_id: records[:assistant].id
    )
    record_once(observation)
    nil
  rescue StandardError
    nil
  end

  # Record the AGGREGATE counters at most once per ActiveJob delivery.
  def record_once(observation)
    key = completion_key(job_id)
    return if key.nil? # invalid job id: no idempotent marker, so record NOTHING.

    owner = SecureRandom.hex(16)
    return unless claim_marker(key, owner) # duplicate/failed claim: skip the increment.

    release_marker(key, owner) unless record_metric(observation)
  end

  def claim_marker(key, owner)
    Redis::Alfred.set(key, owner, nx: true, ex: COMPLETION_TTL_SECONDS) ? true : false
  rescue StandardError
    false
  end

  def record_metric(observation)
    Marine::ProductAuthority::ShadowMetricsStore.record(observation) == true
  rescue StandardError
    false
  end

  def release_marker(key, owner)
    Redis::Alfred.delete_if_equals(key, owner)
  rescue StandardError
    nil
  end

  def completion_key(identifier)
    return nil unless identifier.is_a?(String) && identifier.match?(JOB_ID_PATTERN)

    "#{COMPLETION_KEY_PREFIX}:#{identifier}"
  end

  # Account-scoped, fail-closed record load. Returns the four records as a keyword-arg hash for
  # ShadowExecution, or nil when any is missing or the message is not a public incoming turn. Scoping
  # runs account -> assistant -> conversation -> message so a mismatched id can never cross an account
  # boundary.
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
