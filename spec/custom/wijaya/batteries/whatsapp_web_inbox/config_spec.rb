# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WhatsappWebInbox::Config do
  describe '.configured?' do
    it 'is false when the secret is absent' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => 'https://wa.example.com',
                        'WHATSAPP_WEB_CONNECTOR_HMAC_SECRET' => nil,
                        'FRONTEND_URL' => 'https://chat.example.com') do
        expect(described_class.configured?).to be(false)
      end
    end

    it 'is false when the connector url is absent' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => nil,
                        'WHATSAPP_WEB_CONNECTOR_HMAC_SECRET' => 's',
                        'FRONTEND_URL' => 'https://chat.example.com') do
        expect(described_class.configured?).to be(false)
      end
    end

    it 'is false when the public base url is not https' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => 'https://wa.example.com',
                        'WHATSAPP_WEB_CONNECTOR_HMAC_SECRET' => 's',
                        'FRONTEND_URL' => 'http://chat.example.com') do
        expect(described_class.configured?).to be(false)
      end
    end

    it 'is true when all three are present and valid' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => 'https://wa.example.com',
                        'WHATSAPP_WEB_CONNECTOR_HMAC_SECRET' => 's',
                        'FRONTEND_URL' => 'https://chat.example.com') do
        expect(described_class.configured?).to be(true)
      end
    end
  end

  describe '.connector_uri' do
    it 'accepts an https origin' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => 'https://wa.example.com') do
        expect(described_class.connector_uri&.host).to eq('wa.example.com')
      end
    end

    it 'accepts plain http for an internal single-label docker host' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => 'http://wa-connector:3000') do
        expect(described_class.connector_uri&.host).to eq('wa-connector')
      end
    end

    it 'accepts plain http for loopback' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => 'http://127.0.0.1:3000') do
        expect(described_class.connector_uri).not_to be_nil
      end
    end

    it 'rejects plain http for a public multi-label host' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => 'http://wa.example.com') do
        expect(described_class.connector_uri).to be_nil
      end
    end

    it 'rejects a url with embedded credentials' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => 'https://user:pass@wa.example.com') do
        expect(described_class.connector_uri).to be_nil
      end
    end

    it 'rejects a non-http scheme' do
      with_modified_env('WHATSAPP_WEB_CONNECTOR_URL' => 'ftp://wa.example.com') do
        expect(described_class.connector_uri).to be_nil
      end
    end
  end

  describe '.public_base_uri' do
    it 'requires https' do
      with_modified_env('FRONTEND_URL' => 'http://chat.example.com') do
        expect(described_class.public_base_uri).to be_nil
      end
      with_modified_env('FRONTEND_URL' => 'https://chat.example.com') do
        expect(described_class.public_base_uri&.host).to eq('chat.example.com')
      end
    end
  end
end
