# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::CopilotMessage, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:copilot_thread).class_name('Marine::CopilotThread') }
    it { is_expected.to belong_to(:account) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:message_type) }

    it 'rejects unknown message keys' do
      thread = create(:marine_copilot_thread)
      message = thread.copilot_messages.build(message_type: :assistant, message: { hacked: true })

      expect(message).not_to be_valid
      expect(message.errors[:message].join).to include('invalid attributes')
    end

    it 'accepts content and citations keys' do
      thread = create(:marine_copilot_thread)
      message = thread.copilot_messages.build(
        message_type: :assistant,
        message: { content: 'hi', citations: [{ type: 'conversation', id: 1 }] }
      )

      expect(message).to be_valid
    end
  end

  describe 'account backfill' do
    it 'derives account_id from the copilot thread' do
      thread = create(:marine_copilot_thread)
      message = thread.copilot_messages.create!(message_type: :user, message: { content: 'hi' })

      expect(message.account_id).to eq(thread.account_id)
    end
  end
end
