# frozen_string_literal: true

require 'rails_helper'

# End-to-end proof that the native inbox builder learns the `wecom` channel type via
# the battery's prepend (InboxesControllerExtension), with the staged-setup contract:
# Corp ID + Token + EncodingAESKey only; Secret and Open KF ID left blank.
RSpec.describe 'WeCom inbox creation', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:encoding_aes_key) { Base64.strict_encode64(SecureRandom.random_bytes(32))[0, 43] }

  it 'creates a WeCom inbox from Corp ID + Token + EncodingAESKey, leaving Secret/Open KF ID blank' do
    expect do
      post "/api/v1/accounts/#{account.id}/inboxes",
           headers: admin.create_new_auth_token,
           params: { name: 'WeCom Inbox',
                     channel: { type: 'wecom', corp_id: 'ww00f52928a68017c4', token: 'tok', encoding_aes_key: encoding_aes_key } },
           as: :json
    end.to change { account.wecom_channels.count }.by(1)

    expect(response).to have_http_status(:success)
    expect(response.body).to include('WeCom Inbox')
    channel = account.wecom_channels.last
    expect(channel.corp_id).to eq('ww00f52928a68017c4')
    expect(channel.secret).to be_blank
    expect(channel.open_kfid).to be_blank
  end
end
