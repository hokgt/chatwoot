# frozen_string_literal: true

require 'rails_helper'

# End-to-end behavior of the trusted_internal_webhook seam inside Webhooks::Trigger:
# the narrowly allowed trusted API-inbox connector webhook reaches the (stubbed) private
# endpoint with its signed HMAC headers intact, while every other case keeps the exact
# upstream SafeFetch/SsrfFilter path.
RSpec.describe 'Webhooks::Trigger trusted internal webhook delivery' do
  let!(:account) { create(:account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:conversation) { create(:conversation, inbox: inbox) }
  let!(:message) { create(:message, account: account, inbox: inbox, conversation: conversation) }

  let(:connector_url) { 'http://whatsapp-web-connector:3000' }
  let(:connector_webhook) { 'http://whatsapp-web-connector:3000/webhooks/chatwoot/sess-123' }
  let(:secret) { 'service-secret' }
  let(:payload) { { event: 'message_created', conversation: { id: conversation.id }, id: message.id } }

  before do
    allow(GlobalConfig).to receive(:get_value).and_call_original
    allow(GlobalConfig).to receive(:get_value).with('WEBHOOK_TIMEOUT').and_return(5)
  end

  def with_connector(&)
    with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => connector_url,
                      'WIJAYA_TRUSTED_INTERNAL_WEBHOOK_HOSTS' => nil, &)
  end

  context 'without an allowlist configured (stock behavior)' do
    it 'routes the internal-host api_inbox webhook through native SafeFetch, which rejects it' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => nil, 'WIJAYA_TRUSTED_INTERNAL_WEBHOOK_HOSTS' => nil) do
        expect(SafeFetch).to receive(:fetch)
          .and_raise(SafeFetch::UnsafeUrlError.new("Hostname 'whatsapp-web-connector' has no public ip addresses"))

        expect { Webhooks::Trigger.execute(connector_webhook, payload, :api_inbox_webhook) }
          .to change { message.reload.status }.from('sent').to('failed')
      end

      expect(a_request(:post, connector_webhook)).not_to have_been_made
    end
  end

  context 'when the connector host is allowlisted (via WHATSAPP_WEB_CONNECTOR_URL)' do
    it 'delivers the api_inbox webhook to the private connector endpoint with HMAC headers, without SafeFetch' do
      stub = stub_request(:post, connector_webhook)
             .with(body: payload.to_json) do |req|
               req.headers['X-Chatwoot-Signature'].to_s.start_with?('sha256=') &&
                 req.headers['X-Chatwoot-Timestamp'].present?
             end
             .to_return(status: 200, body: 'ok')

      with_connector do
        expect(SafeFetch).not_to receive(:fetch)
        expect { Webhooks::Trigger.execute(connector_webhook, payload, :api_inbox_webhook, secret: secret) }
          .not_to(change { message.reload.status })
      end

      expect(stub).to have_been_requested.once
    end

    it 'marks the message failed (via SafeFetch error semantics) when the connector returns non-2xx' do
      stub_request(:post, connector_webhook).to_return(status: 503)

      with_connector do
        expect { Webhooks::Trigger.execute(connector_webhook, payload, :api_inbox_webhook, secret: secret) }
          .to change { message.reload.status }.from('sent').to('failed')
      end
    end

    it 'still routes an ACCOUNT webhook to that same host through native SafeFetch (not api_inbox)' do
      with_connector do
        expect(SafeFetch).to receive(:fetch).and_yield(instance_double(SafeFetch::Result))
        Webhooks::Trigger.execute(connector_webhook, payload, :account_webhook)
      end

      expect(a_request(:post, connector_webhook)).not_to have_been_made
    end

    it 'still routes an api_inbox webhook to an UNLISTED private host through native SafeFetch' do
      with_connector do
        expect(SafeFetch).to receive(:fetch)
          .and_raise(SafeFetch::UnsafeUrlError.new('blocked'))
        expect { Webhooks::Trigger.execute('http://other-internal:3000/hook', payload, :api_inbox_webhook) }
          .to change { message.reload.status }.from('sent').to('failed')
      end
    end

    it 'leaves a public api_inbox webhook on the native SafeFetch path unchanged' do
      with_connector do
        expect(SafeFetch).to receive(:fetch).and_yield(instance_double(SafeFetch::Result))
        Webhooks::Trigger.execute('https://hooks.example.com/endpoint', payload, :api_inbox_webhook)
      end
    end
  end
end
