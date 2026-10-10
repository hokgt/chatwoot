require 'securerandom'

# DEFAULT-OFF, asynchronous, fire-and-forget shadow of the isolated Marine Decision Runner
# (Phase 2 / Stage 4 shadow + Stage 5 aggregate metrics). Enqueued ONLY by
# Marine::Decision::ShadowEnqueuer after the normal Marine response job was scheduled, and only
# when the shadow is explicitly enabled for the assistant.
#
# Its arguments are SCALAR IDs only. At execution time it re-checks the assistant-scoped shadow
# flag (ShadowConfig.enabled_for?) with the SCALAR id, loads each record account-scoped, and
# re-checks enabled_for? with the LOADED assistant id BEFORE running the execution — so the
# Decision Runner / provider is never exercised for an assistant that is not allowlisted. Every
# check fails closed (silent return).
#
# It then runs Marine::Decision::ShadowExecution and — this is the ONLY Stage 5 runtime wiring —
# converts a successful comparison into a privacy-safe Marine::Decision::ShadowObservation and
# records AGGREGATE counters via Marine::Decision::ShadowMetricsStore. A nil execution records
# NO fake comparison. The metrics result is ignored and every observation/metrics failure is
# swallowed. The shadow result NEVER influences the primary reply/routing/state path; no retry,
# raise, log, or raw error/customer text is emitted.
#
# AGGREGATE recording is made IDEMPOTENT against a duplicate/redelivered ActiveJob using this
# job's stable, non-customer ActiveJob `job_id` (a UUID) as a versioned Redis NX completion
# marker. AFTER a valid observation but BEFORE the metrics increment the marker is claimed with a
# random owner token; a duplicate/failed claim skips the increment, so the same delivery can never
# count twice. If the record then fails the marker is released (compare-and-delete of this owner)
# so a safe retry can still record; on success the marker is retained until its bounded TTL. The
# marker key carries ONLY the job_id — never an account/message/conversation/contact/inbox id.
class Marine::Decision::ShadowJob < ApplicationJob
  queue_as :low

  # Versioned, feature-specific completion-marker prefix — never a broad pattern; the only
  # dynamic component is the validated ActiveJob job_id.
  COMPLETION_KEY_PREFIX = 'marine:decision:shadow:done:v1'.freeze
  # Independent completion-marker prefix for the Langkah 3 Model 2 aggregate (same job_id-only
  # pattern, distinct namespace) so the Model 2 metric records exactly once per delivery WITHOUT
  # colliding with the Decision metric's marker.
  MODEL2_COMPLETION_KEY_PREFIX = 'marine:model2:shadow:done:v1'.freeze
  # Same bounded 14-day lifetime as the metrics retention window.
  COMPLETION_TTL_SECONDS = Marine::Decision::ShadowMetricsStore::TTL_SECONDS
  # A bounded UUID/job-id shape: the default ActiveJob job_id is a 36-char UUID; this allows a
  # small alnum+hyphen token and rejects anything empty/oversized/exotic before key construction.
  JOB_ID_PATTERN = /\A[0-9a-zA-Z-]{8,64}\z/

  def perform(account_id, assistant_id, conversation_id, message_id)
    return unless Marine::Decision::ShadowConfig.enabled_for?(assistant_id)

    records = load_records(account_id, assistant_id, conversation_id, message_id)
    return if records.nil?

    # Re-check with the LOADED assistant id after the scoped load so the Runner/provider never
    # runs for an assistant that is no longer allowlisted.
    return unless Marine::Decision::ShadowConfig.enabled_for?(records[:assistant].id)

    # Composition root: inject the Phase-1 policy-derived classification vocabulary (a plain frozen
    # array VALUE) so no Decision-layer class names Marine::Backend. ShadowJob is the only production
    # unit that already references both namespaces (it calls Backend::AuthorityShadowExecution below)
    # and is on the ProductAuthority isolation allowlist.
    result = Marine::Decision::ShadowExecution.new(
      **records, classification_intents: Marine::Backend::ExecutionPolicy::CLASSIFICATION_INTENTS
    ).call
    return if result.nil? # nil execution: record NO fake comparison.

    record_metrics(records, result)
    run_authority_shadow(records, result)
    nil
  rescue StandardError
    # Fire-and-forget: swallow everything so the shadow can never affect the primary flow.
    # No exception tracker / logger call — no raw error or customer text is emitted.
    nil
  end

  private

  # Phase 2A (PRICE-ONLY shadow bridge) — the read-only, independently-rescued hook that REUSES the
  # already-computed JEV plan (`result[:candidate_plan]`) through the Backend Authority. It runs AFTER
  # the existing metrics attempt, inside the same enabled_for? gate, passing the FULL loaded records
  # plus the reused plan — it never runs the Decision Runner / a second provider call. Fire-and-forget:
  # its result is discarded and any failure is swallowed, so it can never affect the Decision shadow /
  # metrics behavior or the primary flow. Its deep-frozen AuthorityCoordinator::Result is then REUSED
  # by the Langkah 3 Model 2 shadow (no second Authority/Decision/JEV call).
  def run_authority_shadow(records, result)
    authority_result = Marine::Backend::AuthorityShadowExecution.new(
      account: records[:account],
      assistant: records[:assistant],
      conversation: records[:conversation],
      message: records[:message],
      candidate_plan: result[:candidate_plan]
    ).call
    run_model2_shadow(records, authority_result)
    nil
  rescue StandardError
    nil
  end

  # Langkah 3 (Evidence Packet -> Model 2 SHADOW) — the read-only, independently-rescued hook that
  # REUSES the Phase 2A AuthorityCoordinator::Result. It runs ONLY the accepted exact-price evidence
  # packet through the existing Response Generator (Model 2) for shadow observation; every other
  # outcome skips with zero Model 2 calls. NON-DELIVERING: the bounded closed result is OBSERVED
  # (projected to an aggregate status/reason counter) but never delivered, and any failure is
  # swallowed, so it can never affect the Authority shadow, Decision metrics, or the primary flow. A
  # nil authority result (no-work / relationship fail) runs nothing.
  def run_model2_shadow(records, authority_result)
    return if authority_result.nil?

    result = Marine::Backend::Model2ShadowExecution.new(
      account: records[:account],
      assistant: records[:assistant],
      conversation: records[:conversation],
      message: records[:message],
      authority_result: authority_result
    ).call
    record_model2_metrics(result)
    nil
  rescue StandardError
    nil
  end

  # Observe the deep-frozen Model 2 Result: project it to a bounded status/reason observation and
  # record the AGGREGATE counter once per ActiveJob delivery. Only the closed status/reason pair is
  # read — never the generated text, Evidence Packet, Candidate Plan, or any id. Independently
  # rescued so a projection or Redis failure can never affect the Model 2 execution, the Authority
  # shadow, the Decision metrics, or the primary flow.
  def record_model2_metrics(result)
    observation = Marine::Backend::Model2ShadowObservation.build(result: result)
    record_model2_once(observation)
    nil
  rescue StandardError
    nil
  end

  # Record the Model 2 aggregate at most once per ActiveJob delivery, reusing the same job_id-only
  # NX completion-marker pattern as the Decision metric but under an independent namespace: claim the
  # marker AFTER the valid observation but BEFORE the increment; a duplicate/failed claim skips the
  # increment; a failed record releases only this owner's marker so a safe retry can record.
  def record_model2_once(observation)
    key = model2_completion_key(job_id)
    return if key.nil? # invalid job id: no idempotent marker, so record NOTHING.

    owner = SecureRandom.hex(16)
    return unless claim_marker(key, owner) # duplicate/failed claim: skip the increment.

    release_marker(key, owner) unless record_model2_metric(observation)
  end

  # Record the Model 2 aggregate counter. True ONLY on a genuine write; a false return or any raise
  # folds to false so the caller releases the marker for a safe retry.
  def record_model2_metric(observation)
    Marine::Backend::Model2ShadowMetricsStore.record(observation) == true
  rescue StandardError
    false
  end

  # The versioned Model 2 completion-marker key for a validated job_id, or nil when the job_id is not
  # a bounded UUID/job-id token. Only the job_id is used — never a customer/message/conversation id.
  def model2_completion_key(identifier)
    return nil unless identifier.is_a?(String) && identifier.match?(JOB_ID_PATTERN)

    "#{MODEL2_COMPLETION_KEY_PREFIX}:#{identifier}"
  end

  # Convert the deep-frozen comparison into a privacy-safe observation and record AGGREGATE
  # counters only, once per ActiveJob delivery. The metrics return is ignored; any observation/
  # metrics failure is swallowed so it can never influence the primary flow.
  def record_metrics(records, result)
    observation = Marine::Decision::ShadowObservation.build(
      result: result,
      account_id: records[:account].id,
      assistant_id: records[:assistant].id
    )
    record_once(observation)
    nil
  rescue StandardError
    nil
  end

  # Record the AGGREGATE counters at most once per ActiveJob delivery. Claim the job_id completion
  # marker AFTER the valid observation but BEFORE the increment: a duplicate/failed claim skips the
  # increment; a failed record releases only this owner's marker so a safe retry can record; a
  # successful record keeps the marker until TTL. Never raises into the caller.
  def record_once(observation)
    key = completion_key(job_id)
    return if key.nil? # invalid job id: no idempotent marker, so record NOTHING.

    owner = SecureRandom.hex(16)
    return unless claim_marker(key, owner) # duplicate/failed claim: skip the increment.

    release_marker(key, owner) unless record_metric(observation)
  end

  # NX claim of the completion marker with a bounded TTL. True ONLY on a genuine first claim; a
  # duplicate (NX conflict) or any Redis error fails closed to false so the increment is skipped.
  def claim_marker(key, owner)
    Redis::Alfred.set(key, owner, nx: true, ex: COMPLETION_TTL_SECONDS) ? true : false
  rescue StandardError
    false
  end

  # Record the aggregate counters. True ONLY on a genuine write; a false return or any raise folds
  # to false so the caller releases the marker for a safe retry.
  def record_metric(observation)
    Marine::Decision::ShadowMetricsStore.record(observation) == true
  rescue StandardError
    false
  end

  # Release ONLY the marker this delivery owns (compare-and-delete) so a safe retry can re-claim
  # and record. A delete failure is swallowed — the marker simply expires at its TTL.
  def release_marker(key, owner)
    Redis::Alfred.delete_if_equals(key, owner)
  rescue StandardError
    nil
  end

  # The versioned completion-marker key for a validated job_id, or nil when the job_id is not a
  # bounded UUID/job-id token. Only the job_id is used — never a customer/message/conversation id.
  def completion_key(identifier)
    return nil unless identifier.is_a?(String) && identifier.match?(JOB_ID_PATTERN)

    "#{COMPLETION_KEY_PREFIX}:#{identifier}"
  end

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
