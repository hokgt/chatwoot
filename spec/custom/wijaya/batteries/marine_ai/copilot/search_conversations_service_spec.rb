# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Copilot::SearchConversationsService do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }

  describe '#perform account isolation' do
    it 'never returns conversations from another account' do
      own = create(:conversation, account: account, inbox: inbox)
      other_account = create(:account)
      create(:conversation, account: other_account)

      results = described_class.new(account: account, user: admin).perform

      expect(results.map { |row| row[:id] }).to contain_exactly(own.display_id)
    end
  end

  describe '#perform RBAC scoping' do
    it 'restricts an agent to conversations in their inboxes' do
      member_inbox = create(:inbox, account: account)
      create(:inbox_member, user: agent, inbox: member_inbox)
      visible = create(:conversation, account: account, inbox: member_inbox)
      create(:conversation, account: account, inbox: inbox)

      results = described_class.new(account: account, user: agent).perform

      expect(results.map { |row| row[:id] }).to contain_exactly(visible.display_id)
    end
  end

  describe '#perform status filter' do
    it 'filters by valid status only' do
      create(:conversation, account: account, inbox: inbox, status: :open)
      resolved = create(:conversation, account: account, inbox: inbox, status: :resolved)

      results = described_class.new(account: account, user: admin).perform(status: 'resolved')

      expect(results.map { |row| row[:id] }).to contain_exactly(resolved.display_id)
    end
  end
end
