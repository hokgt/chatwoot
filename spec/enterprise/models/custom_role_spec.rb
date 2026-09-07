require 'rails_helper'

RSpec.describe CustomRole, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to have_many(:account_users).dependent(:nullify) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:name) }

    describe 'conversation permission scope' do
      let(:account) { create(:account) }

      it 'accepts exactly one conversation permission' do
        role = build(:custom_role, account: account, permissions: %w[conversation_manage contact_manage])

        expect(role).to be_valid
      end

      it 'rejects zero conversation permissions' do
        role = build(:custom_role, account: account, permissions: %w[contact_manage])

        expect(role).not_to be_valid
        expect(role.errors[:permissions]).to include('must include exactly one conversation permission')
      end

      it 'rejects multiple conversation permissions' do
        role = build(:custom_role, account: account, permissions: %w[conversation_manage conversation_unassigned_manage])

        expect(role).not_to be_valid
        expect(role.errors[:permissions]).to include('must include exactly one conversation permission')
      end
    end
  end
end
