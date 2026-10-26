# frozen_string_literal: true

require 'rails_helper'

# The Lead Owner picker is sourced from the account's own Chatwoot agents, never the
# ERPNext User list. This proves the options/value are agent emails, that the source is
# strictly the current account's agents (administrators + agents, no contacts / bots /
# cross-account users), and that the membership gate rejects a fabricated email — all
# from the local DB, with no outbound ERP request.
RSpec.describe Wijaya::Batteries::ErpLeadSidebar::AccountAgentDirectory do
  let(:account) { create(:account) }
  let(:other_account) { create(:account) }

  describe '.fetch_options' do
    it 'lists the current-account Chatwoot agents (administrators + agents) with the email as value and label' do
      create(:user, account: account, role: :agent, email: 'agent@example.com', name: 'Zed Agent')
      create(:user, account: account, role: :administrator, email: 'admin@example.com', name: 'Amy Admin')
      # A user in another account must never appear.
      create(:user, account: other_account, role: :agent, email: 'elsewhere@example.com')

      options = described_class.fetch_options(account)

      expect(options).to eq(
        [
          { value: 'admin@example.com', label: 'admin@example.com' },
          { value: 'agent@example.com', label: 'agent@example.com' }
        ]
      )
    end

    it 'issues no outbound ERP request to build the options' do
      create(:user, account: account, role: :agent, email: 'agent@example.com')
      expect(Net::HTTP).not_to receive(:start)
      expect(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).not_to receive(:request)

      expect(described_class.fetch_options(account).pluck(:value)).to eq(['agent@example.com'])
    end
  end

  describe '.agent?' do
    before do
      create(:user, account: account, role: :agent, email: 'agent@example.com')
      create(:user, account: other_account, role: :agent, email: 'elsewhere@example.com')
    end

    it 'accepts an exact current-account agent email' do
      expect(described_class.agent?(account, 'agent@example.com')).to be(true)
    end

    it 'rejects a blank value' do
      expect(described_class.agent?(account, '  ')).to be(false)
    end

    it 'rejects a fabricated email that is no account agent' do
      expect(described_class.agent?(account, 'attacker@evil.example')).to be(false)
    end

    it 'rejects an agent that belongs only to another account' do
      expect(described_class.agent?(account, 'elsewhere@example.com')).to be(false)
    end
  end
end
