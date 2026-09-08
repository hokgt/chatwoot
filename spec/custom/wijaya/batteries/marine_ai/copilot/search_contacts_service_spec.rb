# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Copilot::SearchContactsService do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  describe '#perform account isolation' do
    it 'never returns contacts from another account' do
      own = create(:contact, account: account, name: 'Alice Marine')
      other_account = create(:account)
      create(:contact, account: other_account, name: 'Alice Marine')

      results = described_class.new(account: account, user: admin).perform(query: 'Alice')

      expect(results.map { |row| row[:id] }).to contain_exactly(own.id)
    end
  end

  describe '#perform keyword search' do
    it 'matches by name, email or phone' do
      match = create(:contact, account: account, email: 'refunds@example.com')
      create(:contact, account: account, email: 'other@example.com')

      results = described_class.new(account: account, user: admin).perform(query: 'refunds')

      expect(results.map { |row| row[:id] }).to contain_exactly(match.id)
    end
  end

  describe '#perform without contact access' do
    it 'returns an empty array when the user cannot access contacts' do
      create(:contact, account: account, name: 'Hidden')
      allow_any_instance_of(described_class).to receive(:contacts_accessible?).and_return(false)

      results = described_class.new(account: account, user: admin).perform(query: 'Hidden')

      expect(results).to eq([])
    end
  end
end
