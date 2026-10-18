# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WecomChannel::ApiClient do
  subject(:client) { described_class.new(channel) }

  let(:channel) { create(:channel_wecom, corp_id: 'ww_corp', secret: 'corp-secret') }

  before { Redis::Alfred.delete(client.send(:token_cache_key)) }

  describe 'access token caching' do
    it 'fetches once and serves subsequent calls from the cache' do
      stub = stub_request(:get, 'https://qyapi.weixin.qq.com/cgi-bin/gettoken')
             .with(query: { corpid: 'ww_corp', corpsecret: 'corp-secret' })
             .to_return(body: { errcode: 0, access_token: 'token-1', expires_in: 7200 }.to_json)

      expect(client.access_token).to eq('token-1')
      expect(client.access_token).to eq('token-1')
      expect(stub).to have_been_requested.once
    end
  end

  describe 'refresh-once on an expired/invalid token' do
    it 'refreshes the token exactly once on a 40014 then retries the call' do
      stub_request(:get, 'https://qyapi.weixin.qq.com/cgi-bin/gettoken')
        .with(query: { corpid: 'ww_corp', corpsecret: 'corp-secret' })
        .to_return({ body: { errcode: 0, access_token: 'stale', expires_in: 7200 }.to_json },
                   { body: { errcode: 0, access_token: 'fresh', expires_in: 7200 }.to_json })

      stub_request(:post, 'https://qyapi.weixin.qq.com/cgi-bin/kf/account/list')
        .with(query: { access_token: 'stale' })
        .to_return(body: { errcode: 40_014, errmsg: 'invalid access_token' }.to_json)
      ok = stub_request(:post, 'https://qyapi.weixin.qq.com/cgi-bin/kf/account/list')
           .with(query: { access_token: 'fresh' })
           .to_return(body: { errcode: 0, account_list: [{ open_kfid: 'wk1' }] }.to_json)

      expect(client.kf_account_list['account_list']).to eq([{ 'open_kfid' => 'wk1' }])
      expect(ok).to have_been_requested.once
    end
  end

  describe 'provider error text' do
    it 'raises an Error carrying the errcode and sanitized errmsg (no token)' do
      stub_request(:get, 'https://qyapi.weixin.qq.com/cgi-bin/gettoken')
        .with(query: { corpid: 'ww_corp', corpsecret: 'corp-secret' })
        .to_return(body: { errcode: 0, access_token: 'token-1', expires_in: 7200 }.to_json)
      stub_request(:post, 'https://qyapi.weixin.qq.com/cgi-bin/kf/account/list')
        .with(query: { access_token: 'token-1' })
        .to_return(body: { errcode: 95_000, errmsg: 'api freq out of limit, hint access_token=SECRET' }.to_json)

      expect { client.kf_account_list }.to raise_error(described_class::Error) do |error|
        expect(error.errcode).to eq(95_000)
        expect(error.message).to include('95000')
        expect(error.message).to include('api freq out of limit')
        expect(error.message).not_to include('SECRET')
        expect(error.message).to include('access_token=[redacted]')
      end
    end
  end

  describe 'proxy scoping' do
    it 'applies WECOM_HTTP_PROXY only to the exact qyapi host' do
      with_modified_env WECOM_HTTP_PROXY: 'http://proxy.internal:3128' do
        expect(client.send(:proxy_applicable?, URI('https://qyapi.weixin.qq.com/cgi-bin/gettoken'))).to be(true)
        expect(client.send(:proxy_applicable?, URI('https://evil.example.com/cgi-bin/gettoken'))).to be(false)
      end
    end

    it 'never proxies when WECOM_HTTP_PROXY is unset' do
      with_modified_env WECOM_HTTP_PROXY: nil do
        expect(client.send(:proxy_applicable?, URI('https://qyapi.weixin.qq.com/cgi-bin/gettoken'))).to be(false)
      end
    end
  end
end
