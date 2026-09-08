# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::CopilotThread, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:assistant).class_name('Marine::Assistant') }
    it { is_expected.to have_many(:copilot_messages).class_name('Marine::CopilotMessage') }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:title) }
  end

  describe '#previous_history' do
    let(:account) { create(:account) }
    let(:user) { create(:user, account: account) }
    let(:assistant) { create(:marine_assistant, account: account) }
    let(:thread) { create(:marine_copilot_thread, account: account, user: user, assistant: assistant) }

    it 'returns user and assistant messages in chronological order with role/content' do
      thread.copilot_messages.create!(message_type: :user, message: { content: 'question' })
      thread.copilot_messages.create!(message_type: :assistant, message: { content: 'answer' })

      expect(thread.previous_history).to eq(
        [
          { role: 'user', content: 'question' },
          { role: 'assistant', content: 'answer' }
        ]
      )
    end
  end
end
