# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService do
  let(:account) { double('Account', reporting_timezone: 'Asia/Jakarta') }
  let(:requests) { [] }
  let(:responder) { ->(_request) { ok('data' => [{ 'name' => 'Call' }, { 'name' => 'WhatsApp' }]) } }

  def ok(body)
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    allow(response).to receive(:body).and_return(body.to_json)
    response
  end

  def server_error(body = {})
    response = Net::HTTPInternalServerError.new('1.1', '500', 'Server Error')
    allow(response).to receive(:body).and_return(body.to_json)
    response
  end

  before do
    allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive_messages(
      erp_configured?: true,
      erp_base_url: 'https://erp.example.com',
      erp_api_key: 'key',
      erp_api_secret: 'secret'
    )
    allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, uri:, **|
      request = SsrfFilter::VERB_MAP.fetch(method).new(uri)
      requests << request
      instance_exec(request, &responder)
    end
  end

  describe '#fetch_names' do
    it 'fetches the Lead Activity Master names via GET on its own DocType' do
      names = described_class.new(account).fetch_names

      expect(names).to eq(%w[Call WhatsApp])
      expect(requests.map(&:method)).to eq(['GET'])
      expect(requests.first.path).to include('/api/resource/Lead%20Activity%20Master')
    end

    it 'raises SyncError when ERP is unconfigured (never hits the network)' do
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(false)

      expect { described_class.new(account).fetch_names }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::SyncError)
      expect(requests).to be_empty
    end

    it 'raises SyncError on a non-success response' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request).and_return(server_error('exc' => 'boom'))

      expect { described_class.new(account).fetch_names }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::SyncError)
    end

    # The POST insert-validation path stays tolerant: a malformed 2xx body (no
    # `data` array) collapses to [] exactly as before, so its contract is unchanged.
    it 'tolerates a malformed successful body as an empty list (POST path contract)' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request).and_return(ok('unexpected' => true))

      expect(described_class.new(account).fetch_names).to eq([])
    end

    it 'tolerates a top-level JSON array body as an empty list (never raises on the POST path)' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request).and_return(ok([{ 'name' => 'Call' }]))

      expect(described_class.new(account).fetch_names).to eq([])
    end

    it 'tolerates malformed rows as an empty list (POST path contract)' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request).and_return(ok('data' => ['bad', {}]))

      expect(described_class.new(account).fetch_names).to eq([])
    end
  end

  describe '#fetch_activity_names' do
    it 'returns the master names on a well-formed success' do
      expect(described_class.new(account).fetch_activity_names).to eq(%w[Call WhatsApp])
    end

    it 'returns a genuinely empty data array as a valid empty list' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request).and_return(ok('data' => []))

      expect(described_class.new(account).fetch_activity_names).to eq([])
    end

    it 'raises MalformedResponseError (never a silent empty list) when a 2xx body lacks a data array' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request).and_return(ok('message' => 'ok'))

      expect { described_class.new(account).fetch_activity_names }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::MalformedResponseError)
    end

    it 'raises MalformedResponseError when the top-level body is a JSON array (never a 500)' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request).and_return(ok([{ 'name' => 'Call' }]))

      expect { described_class.new(account).fetch_activity_names }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::MalformedResponseError)
    end

    it 'raises MalformedResponseError when a row is not a well-formed object' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request).and_return(ok('data' => ['bad']))

      expect { described_class.new(account).fetch_activity_names }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::MalformedResponseError)
    end

    it 'raises MalformedResponseError when a row has a blank name' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request)
        .and_return(ok('data' => [{ 'name' => 'Call' }, { 'name' => '  ' }]))

      expect { described_class.new(account).fetch_activity_names }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::MalformedResponseError)
    end

    it 'raises MalformedResponseError when a row is missing the name key' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request)
        .and_return(ok('data' => [{ 'other' => 'x' }]))

      expect { described_class.new(account).fetch_activity_names }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::MalformedResponseError)
    end

    it 'raises SyncError on a non-success response' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request).and_return(server_error('exc' => 'boom'))

      expect { described_class.new(account).fetch_activity_names }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::SyncError)
    end
  end

  describe '#default_date' do
    it 'uses the account reporting timezone' do
      travel_to(Time.utc(2026, 8, 10, 20, 0, 0)) do
        # 20:00 UTC on the 10th is already the 11th in Asia/Jakarta (UTC+7).
        expect(described_class.new(account).default_date).to eq('2026-08-11')
      end
    end

    it 'falls back to project Time.zone when the account has no reporting timezone' do
      account_without_tz = double('Account', reporting_timezone: nil)

      travel_to(Time.utc(2026, 8, 10, 3, 0, 0)) do
        expect(described_class.new(account_without_tz).default_date).to eq(Time.zone.today.iso8601)
      end
    end
  end
end
