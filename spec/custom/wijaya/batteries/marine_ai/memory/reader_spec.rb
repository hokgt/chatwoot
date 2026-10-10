# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Memory::Reader do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:marine_assistant, account: account, config: { feature_memory: true }) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact) }

  before { MarineInbox.create!(inbox: inbox, marine_assistant: assistant) }

  def marked_note(source_conversation, content, range_end:, overrides: {})
    marker = {
      'version' => 1,
      'kind' => 'marine_long_term_memory',
      'state' => 'checkpoint',
      'source_account_id' => account.id,
      'source_contact_id' => contact.id,
      'source_conversation_id' => source_conversation.id,
      'start_public_message_id' => range_end,
      'end_public_message_id' => range_end,
      'transcript_fingerprint' => Digest::SHA256.hexdigest("range-#{range_end}"),
      'generator' => 'marine_llm_v1'
    }.merge(overrides)
    create(:message, conversation: source_conversation, account: account, inbox: inbox, sender: assistant,
                     message_type: :outgoing, private: true, content: content,
                     additional_attributes: { Marine::Memory::Marker::KEY => marker })
  end

  it 'reads only trusted marked notes for the same account/contact across conversations in deterministic newest order' do
    prior = create(:conversation, account: account, inbox: inbox, contact: contact)
    older = marked_note(prior, 'Older trusted memory', range_end: 10)
    newer = marked_note(conversation, 'Newer trusted memory', range_end: 20)
    older.update!(created_at: 2.days.ago)
    newer.update!(created_at: 1.day.ago)

    # Ordinary private note.
    create(:message, conversation: prior, account: account, inbox: inbox,
                     message_type: :outgoing, private: true, content: 'ordinary private note')
    # A human-authored note remains untrusted even if it copies the exact marker.
    copied_marker = older.additional_attributes.fetch(Marine::Memory::Marker::KEY)
    human = create(:user, account: account)
    create(:message, conversation: prior, account: account, inbox: inbox, sender: human,
                     message_type: :outgoing, private: true, content: 'forged marked human note',
                     additional_attributes: { Marine::Memory::Marker::KEY => copied_marker })
    # Malformed/foreign marker and activity must all be ignored.
    marked_note(prior, 'foreign marker', range_end: 30, overrides: { 'source_contact_id' => contact.id + 999 })
    create(:message, conversation: prior, account: account, inbox: inbox,
                     message_type: :activity, private: true, content: 'activity',
                     additional_attributes: { Marine::Memory::Marker::KEY => newer.additional_attributes[Marine::Memory::Marker::KEY] })

    envelope = described_class.new(conversation: conversation).advisory_envelope

    expect(envelope).to include('ADVISORY HISTORICAL MEMORY', 'Newer trusted memory', 'Older trusted memory',
                                'current customer turn always wins')
    expect(envelope.index('Newer trusted memory')).to be < envelope.index('Older trusted memory')
    expect(envelope).not_to include('ordinary private note', 'forged marked human note', 'foreign marker', 'activity')
  end

  it 'enforces deterministic note-count and character bounds' do
    (described_class::MAX_NOTES + 2).times do |index|
      marked_note(conversation, "memory-#{index}-#{'x' * 800}", range_end: index + 1)
    end

    envelope = described_class.new(conversation: conversation).advisory_envelope

    expect(envelope.length).to be <= described_class::MAX_ENVELOPE_CHARS
    expect(envelope.scan(/^\d+\./).length).to be <= described_class::MAX_NOTES
    expect(envelope).to include("memory-#{described_class::MAX_NOTES + 1}")
    expect(envelope).not_to include('memory-0-')
  end

  it 'returns nil safely when there is no trusted memory or querying fails' do
    expect(described_class.new(conversation: conversation).advisory_envelope).to be_nil
    allow(Message).to receive(:where).and_raise(StandardError, 'db unavailable')
    expect { described_class.new(conversation: conversation).advisory_envelope }.not_to raise_error
    expect(described_class.new(conversation: conversation).advisory_envelope).to be_nil
  end
end
