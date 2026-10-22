# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/trusted_internal_webhook/hooks')

RSpec.describe Wijaya::Batteries::TrustedInternalWebhook::Delivery do
  subject(:delivery) { described_class.new(url: url, body: body, headers: headers, timeout: 5) }

  let(:url) { 'http://whatsapp-web-connector:3000/webhooks/chatwoot/abc123' }
  let(:body) { { event: 'message_created', id: 42 }.to_json }
  let(:headers) do
    {
      'Content-Type' => 'application/json',
      'Accept' => 'application/json',
      'X-Chatwoot-Timestamp' => '1700000000',
      'X-Chatwoot-Signature' => 'sha256=deadbeef'
    }
  end

  it 'performs exactly one POST preserving the signed headers and body, returning nil on 2xx' do
    stub = stub_request(:post, url)
           .with(body: body, headers: headers)
           .to_return(status: 200, body: 'ok')

    expect(delivery.perform).to be_nil
    expect(stub).to have_been_requested.once
  end

  it 'raises SafeFetch::HttpError on a non-success response' do
    stub_request(:post, url).to_return(status: 500, body: 'boom')

    expect { delivery.perform }.to raise_error(SafeFetch::HttpError, /500/)
  end

  it 'does NOT follow redirects — a 3xx is surfaced as an error and fetched only once' do
    stub = stub_request(:post, url).to_return(status: 302, headers: { 'Location' => 'http://169.254.169.254/' })
    evil = stub_request(:get, 'http://169.254.169.254/')

    expect { delivery.perform }.to raise_error(SafeFetch::HttpError)
    expect(stub).to have_been_requested.once
    expect(evil).not_to have_been_requested
  end

  it 'raises SafeFetch::FetchError on a transport timeout' do
    stub_request(:post, url).to_timeout

    expect { delivery.perform }.to raise_error(SafeFetch::FetchError)
  end
end
