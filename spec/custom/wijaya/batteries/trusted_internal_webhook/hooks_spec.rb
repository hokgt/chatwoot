# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/trusted_internal_webhook/hooks')

RSpec.describe Wijaya::Batteries::TrustedInternalWebhook::Hooks do
  let(:connector_url) { 'http://whatsapp-web-connector:3000' }
  let(:url) { 'http://whatsapp-web-connector:3000/webhooks/chatwoot/abc123' }
  let(:body) { { event: 'message_created' }.to_json }
  let(:headers) { { 'Content-Type' => 'application/json' } }

  def with_connector(&)
    with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => connector_url,
                      'WIJAYA_TRUSTED_INTERNAL_WEBHOOK_HOSTS' => nil, &)
  end

  describe '.deliver' do
    it 'returns false and performs no request for a non-trusted destination' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => nil, 'WIJAYA_TRUSTED_INTERNAL_WEBHOOK_HOSTS' => nil) do
        expect(described_class.deliver(url: url, webhook_type: :api_inbox_webhook, body: body, headers: headers, timeout: 5)).to be(false)
      end
      expect(a_request(:post, url)).not_to have_been_made
    end

    it 'delivers and returns true for a trusted api_inbox destination' do
      stub = stub_request(:post, url).to_return(status: 200)

      with_connector do
        expect(described_class.deliver(url: url, webhook_type: :api_inbox_webhook, body: body, headers: headers, timeout: 5)).to be(true)
      end

      expect(stub).to have_been_requested.once
    end

    it 'fails OPEN on an unexpected decision error (returns false, native path runs)' do
      allow(Wijaya::Batteries::TrustedInternalWebhook::Policy).to receive(:trusted?).and_raise(StandardError, 'boom')

      expect(described_class.deliver(url: url, webhook_type: :api_inbox_webhook, body: body, headers: headers, timeout: 5)).to be(false)
    end

    it 'fails CLOSED on a delivery error (raises so the trigger marks the message failed)' do
      stub_request(:post, url).to_return(status: 500)

      with_connector do
        expect { described_class.deliver(url: url, webhook_type: :api_inbox_webhook, body: body, headers: headers, timeout: 5) }
          .to raise_error(SafeFetch::HttpError)
      end
    end
  end
end
