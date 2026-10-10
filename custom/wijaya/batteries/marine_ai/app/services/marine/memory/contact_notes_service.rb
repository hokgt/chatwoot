# frozen_string_literal: true

require 'digest'
require 'json'

# Incrementally summarizes an exact public Message range into one native private
# conversation note. Generation runs outside the row lock; the exact range is
# re-read under a short Conversation lock before the append-only note is created.
class Marine::Memory::ContactNotesService
  MAX_SOURCE_MESSAGES = 100
  QUIET_PERIOD = 30.minutes

  def initialize(assistant:, conversation:)
    @assistant = assistant
    @conversation = conversation
    @account = conversation&.account
  end

  def generate_and_store(state: 'final')
    error = request_error(state)
    return no_op(error) if error

    watermark = last_watermark
    range_revision = latest_public_message_id_after(watermark)
    snapshot = public_snapshot_after(watermark)
    return no_op('no_new_incoming') unless new_incoming?(snapshot)
    return no_op(error) if (error = generation_lifecycle_error(state, reload: true))

    summary = summarize(snapshot)
    return no_op('no_summary') if summary.blank?

    persist_if_current(state, watermark, range_revision, snapshot, summary)
  rescue StandardError => e
    capture(e)
    no_op('marine_memory_failed')
  end

  def checkpoint_eligible?
    return false unless checkpoint_candidate?

    new_incoming?(public_snapshot_after(last_watermark)) && generation_lifecycle_error('checkpoint').nil?
  rescue StandardError
    false
  end

  private

  attr_reader :assistant, :conversation, :account

  def request_error(state)
    records_error || state_error(state) || memory_error || assistant_error || configuration_error
  end

  def records_error
    'missing_records' if conversation.blank? || conversation.contact.blank?
  end

  def state_error(state)
    'invalid_state' unless Marine::Memory::Marker::STATES.include?(state)
  end

  def memory_error
    'memory_disabled' if assistant&.feature_memory.blank?
  end

  def assistant_error
    'assistant_mismatch' unless conversation.inbox&.try(:marine_assistant)&.id == assistant.id
  end

  def configuration_error
    'marine_llm_not_configured' unless base_service.configured?
  end

  def checkpoint_candidate?
    conversation&.status.in?(%w[open pending]) && assistant&.feature_memory.present?
  end

  def generation_lifecycle_error(state, target = conversation, reload: false)
    target.reload if reload
    Marine::Memory::LifecyclePolicy.new(conversation: target, quiet_period: QUIET_PERIOD).error(state)
  end

  def new_incoming?(snapshot)
    snapshot.any? { |item| item[:message_type] == 'incoming' }
  end

  def base_service
    @base_service ||= Marine::Llm::BaseService.new(account: account)
  end

  def last_watermark
    trusted_notes.filter_map { |message| Marine::Memory::Marker.extract(message) }
                 .pluck('end_public_message_id').max.to_i
  end

  def trusted_notes
    conversation.messages.where(private: true, message_type: :outgoing)
                .where('jsonb_extract_path(messages.additional_attributes, ?) IS NOT NULL',
                       Marine::Memory::Marker::KEY)
                .reorder(id: :desc).limit(100).includes(:conversation).to_a
  end

  def public_snapshot_after(watermark)
    messages = conversation.messages.where(private: false, message_type: %i[incoming outgoing])
                           .where('id > ?', watermark).reorder(id: :asc)
                           .limit(MAX_SOURCE_MESSAGES + 1).to_a
    messages.filter_map { |message| snapshot_item(message) }.first(MAX_SOURCE_MESSAGES)
  end

  def latest_public_message_id_after(watermark)
    conversation.messages.where(private: false, message_type: %i[incoming outgoing])
                .where('id > ?', watermark).maximum(:id).to_i
  end

  def snapshot_item(message)
    content = message.content_for_llm.to_s.strip
    return nil if content.blank?

    {
      id: message.id,
      message_type: message.message_type,
      created_at: message.created_at.utc.iso8601(6),
      content: content
    }.freeze
  end

  def summarize(snapshot)
    result = base_service.complete(prompt: transcript(snapshot), system: system_prompt)
    return nil unless result[:ok]

    result[:message].to_s.strip.presence
  end

  def transcript(snapshot)
    snapshot.map do |item|
      role = item[:message_type] == 'incoming' ? 'Customer' : 'Assistant'
      "#{role}: #{item[:content]}"
    end.join("\n")
  end

  def system_prompt
    <<~PROMPT.strip
      Extract one concise, human-readable durable memory from this conversation range.
      Keep only stable customer preferences, account facts, recurring needs, or commitments.
      Ignore greetings and one-off pleasantries. A customer-stated historical product family
      or variant may be remembered as advisory context, but never claim it is still current or
      validated. Never preserve price or stock as current facts. Return only the memory prose.
    PROMPT
  end

  def persist_if_current(state, watermark, range_revision, snapshot, summary)
    data = { state: state, watermark: watermark, range_revision: range_revision, snapshot: snapshot, summary: summary }
    conversation.class.transaction do
      locked_conversation = conversation.class.lock.find(conversation.id)
      persist_under_lock(data, locked_conversation)
    end
  end

  def persist_under_lock(data, locked_conversation)
    current = public_snapshot_after(data[:watermark])
    range_current = latest_public_message_id_after(data[:watermark]) == data[:range_revision]
    return no_op('stale_snapshot') unless current == data[:snapshot] && range_current

    error = generation_lifecycle_error(data[:state], locked_conversation)
    return no_op(error) if error

    transcript_fingerprint = fingerprint(data[:snapshot])
    return { ok: true, created: 0, error: nil } if duplicate?(data[:snapshot], transcript_fingerprint)

    create_private_note(data[:state], data[:snapshot], transcript_fingerprint, data[:summary])
    { ok: true, created: 1, error: nil }
  end

  def duplicate?(snapshot, fingerprint)
    start_id = snapshot.first[:id]
    end_id = snapshot.last[:id]
    trusted_notes.any? do |message|
      marker = Marine::Memory::Marker.extract(message)
      marker && marker['start_public_message_id'] == start_id &&
        marker['end_public_message_id'] == end_id && marker['transcript_fingerprint'] == fingerprint
    end
  end

  def create_private_note(state, snapshot, fingerprint, summary)
    marker = Marine::Memory::Marker.build(
      state: state, conversation: conversation, start_id: snapshot.first[:id],
      end_id: snapshot.last[:id], fingerprint: fingerprint
    )
    conversation.messages.create!(
      account: account,
      inbox: conversation.inbox,
      sender: assistant,
      message_type: :outgoing,
      private: true,
      content: "Marine memory (#{state}): #{summary}",
      additional_attributes: { Marine::Memory::Marker::KEY => marker }
    )
  end

  def fingerprint(snapshot)
    Digest::SHA256.hexdigest(JSON.generate(snapshot))
  end

  def no_op(error)
    { ok: false, created: 0, error: error }
  end

  def capture(exception)
    return if account.blank?

    ChatwootExceptionTracker.new(exception, account: account).capture_exception
  rescue StandardError
    nil
  end
end
