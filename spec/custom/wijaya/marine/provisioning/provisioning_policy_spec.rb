# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::ProvisioningPolicy do
  subject(:policy) { described_class.new(user_context, account) }

  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:super_admin) { create(:super_admin) }

  let(:user_context) do
    account_user = account.account_users.find_by(user: current_user)
    { user: current_user, account: account, account_user: account_user }
  end

  context 'when the user is a SuperAdmin with an administrator membership' do
    let(:current_user) { super_admin }

    before { create(:account_user, account: account, user: super_admin, role: :administrator) }

    it { expect(policy.provision?).to be(true) }
  end

  context 'when the user is a SuperAdmin but only an agent in the account' do
    let(:current_user) { super_admin }

    before { create(:account_user, account: account, user: super_admin, role: :agent) }

    it { expect(policy.provision?).to be(false) }
  end

  context 'when the user is a SuperAdmin with no membership in the account' do
    let(:current_user) { super_admin }

    it { expect(policy.provision?).to be(false) }
  end

  context 'when the user is a regular account administrator (not a SuperAdmin)' do
    let(:current_user) { administrator }

    it { expect(policy.provision?).to be(false) }
  end

  context 'when the user is an agent' do
    let(:current_user) { agent }

    it { expect(policy.provision?).to be(false) }
  end
end
