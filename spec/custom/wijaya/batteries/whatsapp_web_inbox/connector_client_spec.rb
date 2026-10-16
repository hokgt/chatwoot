# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WhatsappWebInbox::ConnectorClient do
  let(:base) { 'http://wa-connector:3000' }
  let(:env) do
    {
      'WHATSAPP_WEB_CONNECTOR_URL' => base,
      'WHATSAPP_WEB_CONNECTOR_HMAC_SECRET' => 'svc-secret',
      'FRONTEND_URL' => 'https://chat.example.com'
    }
  end

  around { |example| with_modified_env(env) { example.run } }

  def json_headers
    { 'Content-Type' => 'application/json' }
  end

  describe 'service signing' do
    it 'sends the three signed headers and the JSON body on create' do
      stub = stub_request(:post, "#{base}/api/sessions")
             .with(
               headers: {
                 'X-Service-Timestamp' => /\A\d+\z/,
                 'X-Service-Nonce' => /.+/,
                 'X-Service-Signature' => /\A[0-9a-f]{64}\z/
               }
             )
             .to_return(status: 201, body: { id: 'sess-1', status: 'waiting_for_qr' }.to_json,
                        headers: json_headers)

      result = described_class.new.create_session(baseUrl: 'https://chat.example.com')
      expect(result['id']).to eq('sess-1')
      expect(stub).to have_been_requested
    end

    it 'signs the exact pathname (no query) with the real wire ts/nonce' do
      captured = nil
      stub_request(:get, "#{base}/api/sessions/abc")
        .to_return(status: 200, body: { id: 'abc', status: 'connected' }.to_json, headers: json_headers)
        .with { |req| captured = req }

      described_class.new.get_session('abc')
      ts = captured.headers['X-Service-Timestamp']
      nonce = captured.headers['X-Service-Nonce']
      expected = OpenSSL::HMAC.hexdigest('SHA256', 'svc-secret',
                                         "GET\n/api/sessions/abc\n#{ts}\n#{nonce}\n#{Digest::SHA256.hexdigest('')}")
      expect(captured.headers['X-Service-Signature']).to eq(expected)
    end
  end

  describe 'transport safety' do
    it 'does not follow redirects (treats 3xx as an error, one request only)' do
      stub = stub_request(:get, "#{base}/api/sessions/x")
             .to_return(status: 302, headers: { 'Location' => 'http://evil.internal/' })

      expect { described_class.new.get_session('x') }
        .to raise_error(described_class::ConnectorError)
      expect(stub).to have_been_requested.once
    end

    it 'raises a sanitized ConnectorUnavailable on timeout' do
      stub_request(:get, "#{base}/api/sessions").to_timeout
      expect { described_class.new.list_sessions }
        .to raise_error(described_class::ConnectorUnavailable, /timed out/)
    end

    it 'maps 5xx to ConnectorUnavailable' do
      stub_request(:get, "#{base}/api/sessions").to_return(status: 503, body: 'boom')
      expect { described_class.new.list_sessions }.to raise_error(described_class::ConnectorUnavailable)
    end

    it 'maps 4xx to ConnectorError without leaking the remote body' do
      stub_request(:post, "#{base}/api/sessions")
        .to_return(status: 400, body: { error: 'invalid_config', detail: 'secret-leak' }.to_json,
                   headers: json_headers)
      expect { described_class.new.create_session({}) }
        .to raise_error(described_class::ConnectorError) { |e| expect(e.message).not_to include('secret-leak') }
    end

    it 'rejects an oversized response body' do
      huge = 'x' * (Wijaya::Batteries::WhatsappWebInbox::Config::MAX_RESPONSE_BYTES + 1)
      stub_request(:get, "#{base}/api/sessions").to_return(status: 200, body: huge, headers: json_headers)
      expect { described_class.new.list_sessions }.to raise_error(described_class::ConnectorError, /too large/)
    end

    it 'rejects a non-JSON response' do
      stub_request(:get, "#{base}/api/sessions")
        .to_return(status: 200, body: '<html>', headers: { 'Content-Type' => 'text/html' })
      expect { described_class.new.list_sessions }.to raise_error(described_class::ConnectorError)
    end
  end

  describe '#qr' do
    it 'returns the data url and raw qr (server-side) on 200' do
      stub_request(:get, "#{base}/api/sessions/s1/qr")
        .to_return(status: 200, body: { qr: 'RAW-QR-STRING', dataUrl: 'data:image/png;base64,AAAA' }.to_json,
                   headers: json_headers)
      result = described_class.new.qr('s1')
      expect(result).to eq('available' => true, 'data_url' => 'data:image/png;base64,AAAA', 'raw_qr' => 'RAW-QR-STRING')
    end

    it 'returns available:false on a 409 qr_not_available (not an error)' do
      stub_request(:get, "#{base}/api/sessions/s1/qr")
        .to_return(status: 409, body: { error: 'qr_not_available' }.to_json, headers: json_headers)
      expect(described_class.new.qr('s1')).to eq('available' => false)
    end
  end

  describe 'configuration gate' do
    it 'raises ConfigurationError when the connector is not configured' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_HMAC_SECRET' => nil) do
        expect { described_class.new }.to raise_error(described_class::ConfigurationError)
      end
    end
  end
end
