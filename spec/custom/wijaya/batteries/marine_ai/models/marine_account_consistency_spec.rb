# frozen_string_literal: true

require 'rails_helper'

# Cross-account integrity: even though each account_id/assistant_id column has its
# own foreign key, a record must never mix an account with an assistant/thread/inbox
# from a different account.
RSpec.describe 'Marine cross-account integrity', type: :model do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }
  let(:assistant) { create(:marine_assistant, account: account) }

  describe 'Marine::Scenario' do
    it 'coerces the account to the assistant account instead of persisting a mismatch' do
      scenario = create(:marine_scenario, assistant: assistant, account: other_account)
      expect(scenario.account_id).to eq(assistant.account_id)
    end
  end

  describe 'Marine::CopilotThread' do
    it 'coerces the account to the assistant account instead of persisting a mismatch' do
      thread = create(:marine_copilot_thread, assistant: assistant, account: other_account,
                                              user: create(:user, account: account))
      expect(thread.account_id).to eq(assistant.account_id)
    end
  end

  describe 'Marine::CopilotMessage' do
    it 'always derives the account from its thread' do
      thread = create(:marine_copilot_thread, assistant: assistant, account: account, user: create(:user, account: account))
      message = thread.copilot_messages.create!(message_type: :user, message: { content: 'hi' }, account_id: other_account.id)
      expect(message.account_id).to eq(thread.account_id)
    end
  end

  describe 'MarineInbox' do
    it 'rejects linking an assistant to an inbox from a different account' do
      foreign_inbox = create(:inbox, account: other_account)
      link = assistant.marine_inboxes.build(inbox: foreign_inbox)

      expect(link).not_to be_valid
      expect(link.errors[:inbox]).to include('must belong to the same account as the assistant')
    end

    it 'accepts an inbox from the same account' do
      inbox = create(:inbox, account: account)
      expect(assistant.marine_inboxes.build(inbox: inbox)).to be_valid
    end
  end
end
