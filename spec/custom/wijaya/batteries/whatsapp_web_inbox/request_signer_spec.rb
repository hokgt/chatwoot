# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WhatsappWebInbox::RequestSigner do
  let(:secret) { 'super-secret' }

  describe '.signing_string' do
    it 'builds exactly METHOD\\npath\\nts\\nnonce\\nsha256hex(body)' do
      string = described_class.signing_string(
        method: 'post', path: '/api/sessions', raw_body: '{"a":1}',
        timestamp: '1700000000', nonce: 'nonce-1'
      )
      body_hash = Digest::SHA256.hexdigest('{"a":1}')
      expect(string).to eq("POST\n/api/sessions\n1700000000\nnonce-1\n#{body_hash}")
    end

    it 'hashes an empty body as sha256 of the empty string' do
      string = described_class.signing_string(
        method: 'get', path: '/api/sessions', raw_body: nil,
        timestamp: '1', nonce: 'n'
      )
      empty_sha = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
      expect(string).to end_with("\n#{empty_sha}")
    end

    it 'uppercases the method' do
      expect(described_class.signing_string(method: 'delete', path: '/x', raw_body: nil,
                                            timestamp: '1', nonce: 'n')).to start_with("DELETE\n")
    end
  end

  describe '.sign' do
    it 'is the lowercase hex HMAC-SHA256 of the signing string' do
      ts = '1700000000'
      nonce = 'nonce-1'
      expected = OpenSSL::HMAC.hexdigest('SHA256', secret,
                                         "GET\n/api/sessions\n#{ts}\n#{nonce}\n#{Digest::SHA256.hexdigest('')}")
      signature = described_class.sign(method: 'get', path: '/api/sessions', raw_body: nil,
                                       secret: secret, timestamp: ts, nonce: nonce)
      expect(signature).to eq(expected)
      expect(signature).to match(/\A[0-9a-f]{64}\z/)
    end
  end

  describe '.headers' do
    it 'returns the three service headers with a signature matching the body' do
      headers = described_class.headers(method: 'post', path: '/api/sessions',
                                        raw_body: '{"k":"v"}', secret: secret)
      ts = headers['X-Service-Timestamp']
      nonce = headers['X-Service-Nonce']
      expected = OpenSSL::HMAC.hexdigest('SHA256', secret,
                                         "POST\n/api/sessions\n#{ts}\n#{nonce}\n#{Digest::SHA256.hexdigest('{"k":"v"}')}")
      expect(headers['X-Service-Signature']).to eq(expected)
      expect(ts).to match(/\A\d+\z/)
    end

    it 'generates a unique nonce per call' do
      a = described_class.headers(method: 'get', path: '/x', raw_body: nil, secret: secret)
      b = described_class.headers(method: 'get', path: '/x', raw_body: nil, secret: secret)
      expect(a['X-Service-Nonce']).not_to eq(b['X-Service-Nonce'])
    end
  end
end
