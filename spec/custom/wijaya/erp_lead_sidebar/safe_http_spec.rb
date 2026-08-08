# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::ErpLeadSidebar::SafeHttp do
  let(:public_uri) { URI.parse('https://erp.example.com/api/method/ping') }

  it 'pins public requests through ssrf_filter and never follows redirects' do
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    expect(SsrfFilter).to receive(:get).with(
      public_uri.to_s,
      hash_including(
        headers: { 'Authorization' => 'token key:secret' },
        max_redirects: 0,
        allow_unfollowed_redirects: true,
        sensitive_headers: ['authorization']
      )
    ).and_return(response)

    result = described_class.request(
      method: :get, uri: public_uri, api_key: 'key', api_secret: 'secret'
    )
    expect(result).to equal(response)
  end

  it 'uses direct Net::HTTP only for an explicit loopback development host' do
    uri = URI.parse('http://127.0.0.1:8000/api/method/ping')
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    http = instance_double(Net::HTTP)
    allow(http).to receive(:request).and_return(response)
    expect(Net::HTTP).to receive(:start).with(
      '127.0.0.1', 8000, hash_including(use_ssl: false)
    ).and_yield(http)

    expect(
      described_class.request(method: :get, uri: uri, api_key: 'key', api_secret: 'secret')
    ).to equal(response)
  end

  it 'fails closed with a sanitized error when ssrf_filter rejects a private target' do
    uri = URI.parse('https://169.254.169.254/api/method/ping')
    allow(SsrfFilter).to receive(:get).and_raise(SsrfFilter::PrivateIPAddress, 'sensitive detail')

    expect do
      described_class.request(method: :get, uri: uri, api_key: 'key', api_secret: 'secret')
    end.to raise_error(described_class::Error, 'ERPNext request failed')
  end
end
