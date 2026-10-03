# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/trusted_internal_webhook/hooks')

RSpec.describe Wijaya::Batteries::TrustedInternalWebhook::Policy do
  let(:connector_url) { 'http://whatsapp-web-connector:3000' }
  let(:connector_webhook) { 'http://whatsapp-web-connector:3000/webhooks/chatwoot/abc123' }

  def with_connector(&)
    with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => connector_url,
                      'WIJAYA_TRUSTED_INTERNAL_WEBHOOK_HOSTS' => nil, &)
  end

  describe '.trusted?' do
    it 'is false by default-deny when nothing is configured' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => nil,
                        'WIJAYA_TRUSTED_INTERNAL_WEBHOOK_HOSTS' => nil) do
        expect(described_class.trusted?(url: connector_webhook, webhook_type: :api_inbox_webhook)).to be(false)
      end
    end

    it 'trusts the configured connector host for an api_inbox webhook' do
      with_connector do
        expect(described_class.trusted?(url: connector_webhook, webhook_type: :api_inbox_webhook)).to be(true)
      end
    end

    it 'only applies to the api_inbox webhook path' do
      with_connector do
        expect(described_class.trusted?(url: connector_webhook, webhook_type: :account_webhook)).to be(false)
        expect(described_class.trusted?(url: connector_webhook, webhook_type: :agent_bot_webhook)).to be(false)
      end
    end

    it 'trusts hosts from the explicit allowlist env (comma-separated)' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => nil,
                        'WIJAYA_TRUSTED_INTERNAL_WEBHOOK_HOSTS' => 'other-connector, extra-svc') do
        expect(described_class.trusted?(url: 'http://other-connector/hook', webhook_type: :api_inbox_webhook)).to be(true)
        expect(described_class.trusted?(url: 'http://extra-svc:4000/hook', webhook_type: :api_inbox_webhook)).to be(true)
      end
    end

    it 'matches the host case-insensitively and ignores the port' do
      with_connector do
        expect(described_class.trusted?(url: 'http://WhatsApp-Web-Connector:9999/hook', webhook_type: :api_inbox_webhook)).to be(true)
      end
    end

    it 'rejects a suffix-trick host' do
      with_connector do
        expect(described_class.trusted?(url: 'http://whatsapp-web-connector.evil.com/hook', webhook_type: :api_inbox_webhook)).to be(false)
      end
    end

    it 'rejects a URL carrying userinfo (user@host and host@evil tricks)' do
      with_connector do
        expect(described_class.trusted?(url: 'http://evil.com@whatsapp-web-connector/hook', webhook_type: :api_inbox_webhook)).to be(false)
        expect(described_class.trusted?(url: 'http://whatsapp-web-connector@evil.com/hook', webhook_type: :api_inbox_webhook)).to be(false)
      end
    end

    it 'rejects an unlisted private host' do
      with_connector do
        expect(described_class.trusted?(url: 'http://169.254.169.254/latest/meta-data', webhook_type: :api_inbox_webhook)).to be(false)
        expect(described_class.trusted?(url: 'http://127.0.0.1/hook', webhook_type: :api_inbox_webhook)).to be(false)
      end
    end

    it 'rejects a non-http(s) scheme and a malformed url' do
      with_connector do
        expect(described_class.trusted?(url: 'ftp://whatsapp-web-connector/hook', webhook_type: :api_inbox_webhook)).to be(false)
        expect(described_class.trusted?(url: 'http://%', webhook_type: :api_inbox_webhook)).to be(false)
        expect(described_class.trusted?(url: nil, webhook_type: :api_inbox_webhook)).to be(false)
      end
    end

    it 'does not trust an http connector host that fails connector validation (public host over http)' do
      # Config.connector_uri rejects a public multi-label host over plain http, so it
      # contributes no trusted host; the explicit allowlist is the only way to add one.
      with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => 'http://connector.public.example.com',
                        'WIJAYA_TRUSTED_INTERNAL_WEBHOOK_HOSTS' => nil) do
        expect(described_class.trusted?(url: 'http://connector.public.example.com/hook', webhook_type: :api_inbox_webhook)).to be(false)
      end
    end
  end
end
