# frozen_string_literal: true

# Reads only versioned Marine private-note memories for the same account/contact.
# The returned envelope is advisory context, never product or catalogue authority.
class Marine::Memory::Reader
  MAX_NOTES = 5
  MAX_NOTE_CHARS = 600
  MAX_ENVELOPE_CHARS = 2400
  HEADER = <<~TEXT.strip
    [ADVISORY HISTORICAL MEMORY — UNTRUSTED FOR BUSINESS FACTS]
    Use only as background personalization. The current customer turn always wins.
    This memory is not authority for product identity, price, stock, quantity, or catalogue facts.
  TEXT
  FOOTER = '[END ADVISORY HISTORICAL MEMORY]'

  def initialize(conversation:)
    @conversation = conversation
  end

  def advisory_envelope
    return nil unless memory_enabled?

    notes = trusted_notes
    return nil if notes.empty?

    body = bounded_body(notes)
    return nil if body.blank?

    "#{HEADER}\n#{body}\n#{FOOTER}"
  rescue StandardError
    nil
  end

  private

  attr_reader :conversation

  def memory_enabled?
    conversation_identity? && assistant_memory_enabled?
  end

  def conversation_identity?
    conversation&.account_id.present? && conversation&.contact_id.present?
  end

  def assistant_memory_enabled?
    conversation&.inbox&.try(:marine_assistant)&.feature_memory.present?
  end

  def trusted_notes
    Message.where(account_id: conversation.account_id, private: true, message_type: :outgoing)
           .where('jsonb_extract_path(messages.additional_attributes, ?) IS NOT NULL', Marine::Memory::Marker::KEY)
           .joins(:conversation)
           .where(conversations: { contact_id: conversation.contact_id })
           .includes(:conversation)
           .reorder(created_at: :desc, id: :desc)
           .limit(MAX_NOTES * 4)
           .select { |message| Marine::Memory::Marker.extract(message).present? }
           .first(MAX_NOTES)
  end

  def bounded_body(notes)
    budget = MAX_ENVELOPE_CHARS - HEADER.length - FOOTER.length - 2
    lines = []
    notes.each_with_index do |message, index|
      content = message.content.to_s.strip.first(MAX_NOTE_CHARS)
      next if content.blank?

      line = "#{index + 1}. #{content}"
      remaining = budget - lines.sum(&:length) - lines.length
      break if remaining <= 3

      lines << line.first(remaining)
    end
    lines.join("\n")
  end
end
