# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/custom_roles/hooks')

RSpec.describe Wijaya::Batteries::CustomRoles::Hooks do
  describe '.can_manage_all_conversations?' do
    it 'returns true for an administrator regardless of custom role' do
      account_user = instance_double(AccountUser, administrator?: true)

      expect(described_class.can_manage_all_conversations?(account_user)).to be(true)
    end

    it 'returns true for an ordinary (non-custom-role) agent so native self-assignment is preserved' do
      account_user = instance_double(AccountUser, administrator?: false, agent?: true, custom_role_id: nil)

      expect(described_class.can_manage_all_conversations?(account_user)).to be(true)
    end

    it 'returns true for a custom-role agent that holds conversation_manage' do
      account_user = instance_double(
        AccountUser, administrator?: false, agent?: true, custom_role_id: 7, permissions: ['conversation_manage']
      )

      expect(described_class.can_manage_all_conversations?(account_user)).to be(true)
    end

    it 'returns false for a custom-role agent without conversation_manage' do
      account_user = instance_double(
        AccountUser, administrator?: false, agent?: true, custom_role_id: 7, permissions: ['conversation_participating_manage']
      )

      expect(described_class.can_manage_all_conversations?(account_user)).to be(false)
    end

    it 'returns true when the account user is nil (fail-open to native behaviour)' do
      expect(described_class.can_manage_all_conversations?(nil)).to be(true)
    end
  end

  describe '.custom_role_agent?' do
    it 'is true only for an agent with a custom_role_id' do
      account_user = instance_double(AccountUser, agent?: true, custom_role_id: 7)

      expect(described_class.custom_role_agent?(account_user)).to be(true)
    end

    it 'is false for an agent without a custom_role_id' do
      account_user = instance_double(AccountUser, agent?: true, custom_role_id: nil)

      result = described_class.custom_role_agent?(account_user)

      expect(result).to be_falsey
    end

    it 'is false when the account user is nil' do
      result = described_class.custom_role_agent?(nil)

      expect(result).to be_falsey
    end
  end

  describe '.associate_agent_with_custom_role' do
    let(:account_user) { instance_double(AccountUser) }
    let(:agent) { instance_double(User, current_account_user: account_user) }

    it 'assigns the custom_role_id from a nested agent param' do
      params = ActionController::Parameters.new(agent: { custom_role_id: 7 })

      expect(account_user).to receive(:update!).with(custom_role_id: 7)

      described_class.associate_agent_with_custom_role(agent, params)
    end

    it 'assigns the custom_role_id from a top-level param' do
      params = ActionController::Parameters.new(custom_role_id: 9)

      expect(account_user).to receive(:update!).with(custom_role_id: 9)

      described_class.associate_agent_with_custom_role(agent, params)
    end

    it 'is a no-op (fail-open to native behaviour) when the key is absent' do
      params = ActionController::Parameters.new(agent: { name: 'Jane' })

      expect(account_user).not_to receive(:update!)

      described_class.associate_agent_with_custom_role(agent, params)
    end
  end

  describe '.explicit_conversation_forbidden_response?' do
    it 'uses native authorization for an ordinary agent viewing a conversation' do
      account_user = instance_double(AccountUser, agent?: true, custom_role_id: nil)

      result = described_class.explicit_conversation_forbidden_response?(
        account_user: account_user,
        action_name: 'show'
      )

      expect(result).to be(false)
    end

    it 'uses the explicit forbidden response for reporting events' do
      result = described_class.explicit_conversation_forbidden_response?(
        account_user: nil,
        action_name: 'reporting_events'
      )

      expect(result).to be(true)
    end

    it 'uses the explicit forbidden response for a custom-role agent' do
      account_user = instance_double(AccountUser, agent?: true, custom_role_id: 7)

      result = described_class.explicit_conversation_forbidden_response?(
        account_user: account_user,
        action_name: 'show'
      )

      expect(result).to be(true)
    end
  end
end
