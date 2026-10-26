# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Marine idle memory redesign contract' do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:assistant) { create(:marine_assistant, account: account, config: { 'feature_memory' => true }) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, status: :open) }

  before { MarineInbox.create!(inbox: inbox, marine_assistant: assistant) }

  it 'normalizes the per-assistant idle timeout to 1..24 with a default of two hours' do
    expect(assistant.memory_idle_timeout_hours).to eq(2)

    assistant.config['memory_idle_timeout_hours'] = '24'
    expect(assistant.memory_idle_timeout_hours).to eq(24)

    assistant.config['memory_idle_timeout_hours'] = '0'
    expect(assistant.memory_idle_timeout_hours).to eq(2)

    assistant.config['memory_idle_timeout_hours'] = 'invalid'
    expect(assistant.memory_idle_timeout_hours).to eq(2)
  end

  it 'has no registered resolve callback, extension include, hook, or job' do
    marine_loader = Rails.root.join('custom/wijaya/batteries/marine_ai/loader.rb').read

    expect(marine_loader).not_to include('conversation_extensions')
    expect(Conversation.ancestors.map(&:name)).not_to include('Wijaya::Marine::ConversationExtensions')
    expect(Wijaya::Marine::Hooks).not_to respond_to(:after_conversation_resolved)
    expect(defined?(Marine::Memory::GenerateContactNotesJob)).to be_nil
  end

  it 'builds and trusts the exact v2 marker while keeping v1 valid' do
    marker = Marine::Memory::Marker.build_v2(
      trigger_source: 'idle_timeout', conversation: conversation,
      start_id: 11, end_id: 12, fingerprint: Digest::SHA256.hexdigest('range')
    )

    expect(marker.keys).to match_array(Marine::Memory::Marker::V2_KEYS)
    expect(marker).to include(
      'version' => 2,
      'trigger_source' => 'idle_timeout',
      'memory_signal_version' => 'marine_memory_signal_v1'
    )
    expect(Marine::Memory::Marker.trusted_shape?(marker)).to be(true)
  end

  it 'exposes a closed signal contract rather than facts or prose' do
    expect(Marine::Memory::Signal::KEY).to eq('marine_memory_signal_v1')
    expect(Marine::Memory::Signal::KEYS).to contain_exactly(
      'schema_version', 'status', 'requested_capabilities', 'delivered_capabilities',
      'evidence_versions', 'public_reply_message_id'
    )
    expect(Marine::Memory::Signal::CAPABILITIES).to contain_exactly(
      'price', 'price_range', 'stock', 'product_listing', 'product_information',
      'company_offerings', 'catalog_attachment'
    )
  end

  it 'trusts v2 only for the linked assistant and eligible causal public range endpoints' do
    start_message = create(:message, conversation: conversation, account: account, inbox: inbox,
                                     message_type: :incoming, private: false, created_at: 2.minutes.ago)
    end_message = create(:message, conversation: conversation, account: account, inbox: inbox, sender: assistant,
                                   message_type: :outgoing, private: false, created_at: 1.minute.ago)
    marker = Marine::Memory::Marker.build_v2(
      trigger_source: 'idle_timeout', conversation: conversation,
      start_id: start_message.id, end_id: end_message.id, fingerprint: Digest::SHA256.hexdigest('range')
    )
    note = create(:message, conversation: conversation, account: account, inbox: inbox, sender: assistant,
                            message_type: :outgoing, private: true,
                            additional_attributes: { Marine::Memory::Marker::KEY => marker })

    expect(Marine::Memory::Marker.extract(note)).to eq(marker)
  end

  it 'rejects v2 notes from a foreign assistant and ranges from another conversation or inbox' do
    start_message = create(:message, conversation: conversation, account: account, inbox: inbox,
                                     message_type: :incoming, private: false, created_at: 3.minutes.ago)
    end_message = create(:message, conversation: conversation, account: account, inbox: inbox, sender: assistant,
                                   message_type: :outgoing, private: false, created_at: 2.minutes.ago)
    marker = Marine::Memory::Marker.build_v2(
      trigger_source: 'idle_timeout', conversation: conversation,
      start_id: start_message.id, end_id: end_message.id, fingerprint: Digest::SHA256.hexdigest('range')
    )
    foreign_assistant = create(:marine_assistant, account: account)
    foreign_note = create(:message, conversation: conversation, account: account, inbox: inbox, sender: foreign_assistant,
                                    message_type: :outgoing, private: true,
                                    additional_attributes: { Marine::Memory::Marker::KEY => marker })
    expect(Marine::Memory::Marker.extract(foreign_note)).to be_nil

    other = create(:conversation, account: account, inbox: inbox, contact: contact)
    foreign_start = create(:message, conversation: other, account: account, inbox: inbox,
                                     message_type: :incoming, private: false, created_at: 3.minutes.ago)
    foreign_end = create(:message, conversation: other, account: account, inbox: inbox, sender: assistant,
                                   message_type: :outgoing, private: false, created_at: 2.minutes.ago)
    foreign_range = marker.merge('start_public_message_id' => foreign_start.id,
                                 'end_public_message_id' => foreign_end.id)
    range_note = create(:message, conversation: conversation, account: account, inbox: inbox, sender: assistant,
                                  message_type: :outgoing, private: true,
                                  additional_attributes: { Marine::Memory::Marker::KEY => foreign_range })
    expect(Marine::Memory::Marker.extract(range_note)).to be_nil

    other_inbox = create(:inbox, account: account)
    wrong_inbox_endpoint = create(:message, conversation: conversation, account: account, inbox: other_inbox,
                                            message_type: :outgoing, private: false, created_at: 1.minute.ago)
    wrong_inbox_range = marker.merge('end_public_message_id' => wrong_inbox_endpoint.id)
    wrong_inbox_note = create(:message, conversation: conversation, account: account, inbox: inbox, sender: assistant,
                                        message_type: :outgoing, private: true,
                                        additional_attributes: { Marine::Memory::Marker::KEY => wrong_inbox_range })
    expect(Marine::Memory::Marker.extract(wrong_inbox_note)).to be_nil
  end
end
