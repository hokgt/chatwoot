# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/custom_roles/hooks')

RSpec.describe Wijaya::Batteries::CustomRoles::Hooks do
  describe '.can_manage_all_conversations?' do
    it 'preserves assignment for administrators' do
      account_user = instance_double(AccountUser, administrator?: true)

      expect(described_class.can_manage_all_conversations?(account_user)).to be(true)
    end

    it 'preserves native assignment for ordinary agents' do
      account_user = instance_double(AccountUser, administrator?: false, agent?: true, custom_role_id: nil)

      expect(described_class.can_manage_all_conversations?(account_user)).to be(true)
    end

    it 'allows custom-role agents with conversation_manage' do
      account_user = instance_double(
        AccountUser, administrator?: false, agent?: true, custom_role_id: 7, permissions: ['conversation_manage']
      )

      expect(described_class.can_manage_all_conversations?(account_user)).to be(true)
    end

    it 'denies custom-role agents without conversation_manage' do
      account_user = instance_double(
        AccountUser, administrator?: false, agent?: true, custom_role_id: 7,
        permissions: ['conversation_participating_manage']
      )

      expect(described_class.can_manage_all_conversations?(account_user)).to be(false)
    end

    it 'fails open to native behavior when account user is absent' do
      expect(described_class.can_manage_all_conversations?(nil)).to be(true)
    end
  end
end
