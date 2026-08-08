# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::ErpLeadSidebar::ConnectionTestService do
  def build(host: 'https://erp.example.com', api_key: 'key', api_secret: 'secret')
    described_class.new(host: host, api_key: api_key, api_secret: api_secret)
  end

  def response(klass, code)
    klass.new('1.1', code.to_s, '')
  end

  describe '#call validation' do
    it 'fails fast on an invalid host without issuing a request' do
      expect(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).not_to receive(:request)
      result = build(host: 'http://erp.example.com').call
      expect(result[:ok]).to be(false)
      expect(result[:error]).to include('HTTPS')
    end

    it 'fails when the api key is blank' do
      expect(build(api_key: '').call[:error]).to eq('API key is required')
    end

    it 'fails when the secret is blank' do
      expect(build(api_secret: '').call[:error]).to eq('Secret key is required')
    end
  end

  describe '#call HTTP outcomes' do
    it 'returns ok on a 200 and passes credentials to the safe transport' do
      expect(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request).with(
        method: :get,
        uri: URI.parse('https://erp.example.com/api/method/frappe.auth.get_logged_user'),
        api_key: 'key',
        api_secret: 'secret'
      ).and_return(response(Net::HTTPOK, 200))

      expect(build.call[:ok]).to be(true)
    end

    it 'reports an auth failure on 401 without leaking credentials' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request)
        .and_return(response(Net::HTTPUnauthorized, 401))
      result = build(api_secret: 'credential-value-XYZ').call
      expect(result[:error]).to include('Authentication failed')
      expect(result.to_s).not_to include('credential-value-XYZ')
    end

    it 'reports a not-found on 404' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request)
        .and_return(response(Net::HTTPNotFound, 404))
      expect(build.call[:error]).to include('not found')
    end

    it 'sanitizes an unexpected transport error' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request)
        .and_raise(Wijaya::Batteries::ErpLeadSidebar::SafeHttp::Error, 'internal detail')
      expect(build.call[:error]).to eq('Could not connect to ERPNext')
    end

    it 'reports a timeout distinctly' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request)
        .and_raise(Wijaya::Batteries::ErpLeadSidebar::SafeHttp::TimeoutError, 'timeout')
      expect(build.call[:error]).to eq('Connection timed out')
    end
  end
end
