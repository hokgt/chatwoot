# frozen_string_literal: true

require 'rails_helper'

# Reads/creates records in the EXISTING ERPNext DocType "Lead Product
# Requirements". value = ERP document name (stored/sent), label = product_name
# (displayed). Create writes ONLY product_name + a raw numeric product_price and
# dedupes server-side (normalized) before any POST.
RSpec.describe Wijaya::Batteries::ErpLeadSidebar::ProductRequirementsService do
  let(:account) { double('Account') }
  let(:calls) { [] }
  # Default: GETs return a small list; a POST echoes a created document.
  let(:responder) do
    lambda do |method:, body:|
      if method == :post
        ok('data' => { 'name' => 'LPR-NEW', 'product_name' => JSON.parse(body)['product_name'] })
      else
        ok('data' => [{ 'name' => 'LPR-0001', 'product_name' => 'Blue Shirt' }])
      end
    end
  end

  def ok(body)
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    allow(response).to receive(:body).and_return(body.to_json)
    response
  end

  def http_error(klass, code, message, body = {})
    response = klass.new('1.1', code, message)
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
    allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, uri:, body: nil, **|
      calls << { method: method, uri: uri, body: body }
      responder.call(method: method, body: body)
    end
  end

  describe '#list' do
    it 'returns bounded {value: name, label: product_name} rows via GET on its own DocType' do
      options = described_class.new(account).list

      expect(options).to eq([{ value: 'LPR-0001', label: 'Blue Shirt' }])
      expect(calls.map { |c| c[:method] }).to eq([:get])
      expect(calls.first[:uri].path).to include('/api/resource/Lead%20Product%20Requirements')
    end

    it 'bounds the page length (default, never 0) and clamps an oversized limit' do
      described_class.new(account).list
      described_class.new(account).list(limit: 100_000)

      lengths = calls.map { |c| CGI.parse(c[:uri].query)['limit_page_length'].first.to_i }
      expect(lengths).to eq([20, 50])
      expect(lengths).not_to include(0)
    end

    it 'filters by product_name when a query is given (searchable)' do
      described_class.new(account).list(query: 'blue shirt')

      filters = JSON.parse(CGI.parse(calls.first[:uri].query)['filters'].first)
      expect(filters).to eq([['Lead Product Requirements', 'product_name', 'like', '%blue%shirt%']])
    end

    it 'lists the first page (no filter) for a blank query' do
      described_class.new(account).list(query: '   ')

      expect(CGI.parse(calls.first[:uri].query)).not_to have_key('filters')
    end

    it 'raises SyncError without hitting the network when ERP is unconfigured' do
      allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive(:erp_configured?).and_return(false)

      expect { described_class.new(account).list }.to raise_error(Wijaya::Batteries::ErpLeadSidebar::SyncError)
      expect(calls).to be_empty
    end

    it 'raises a sanitized error on a non-2xx response (no raw body)' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request)
        .and_return(http_error(Net::HTTPForbidden, '403', 'Forbidden', 'exc' => 'raw ERP secret'))

      expect { described_class.new(account).list }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::UpstreamHttpError) { |e| expect(e.message).not_to include('raw ERP secret') }
    end

    it 'raises MalformedResponseError when data is not an array' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request).and_return(ok('data' => { 'name' => 'x' }))

      expect { described_class.new(account).list }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::MalformedResponseError)
    end

    it 'displays only product_name: skips a blank-product_name row (never the ERP document id)' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request).and_return(
        ok('data' => [
             { 'name' => 'LPR-0001', 'product_name' => 'Blue Shirt' },
             { 'name' => 'LPR-0002', 'product_name' => '   ' },
             { 'name' => 'LPR-0003', 'product_name' => nil }
           ])
      )

      options = described_class.new(account).list

      expect(options).to eq([{ value: 'LPR-0001', label: 'Blue Shirt' }])
      expect(options.map { |o| o[:label] }).not_to include('LPR-0002', 'LPR-0003')
    end
  end

  describe '#create' do
    it 'sends the raw numeric price (never a formatted string) and only product_name/product_price' do
      # No existing match -> the GET dedupe scan returns nothing, then a POST creates.
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, uri:, body: nil, **|
        calls << { method: method, uri: uri, body: body }
        method == :post ? ok('data' => { 'name' => 'LPR-9', 'product_name' => 'Red Cap' }) : ok('data' => [])
      end

      result = described_class.new(account).create(product_name: 'Red Cap', product_price: '50000')

      expect(result).to eq(value: 'LPR-9', label: 'Red Cap', duplicate: false)
      post = calls.find { |c| c[:method] == :post }
      payload = JSON.parse(post[:body])
      expect(payload['product_price']).to eq(50_000)
      expect(payload['product_price']).to be_a(Integer)
      expect(payload).to include('doctype' => 'Lead Product Requirements', 'product_name' => 'Red Cap')
      expect(payload.keys).to contain_exactly('doctype', 'product_name', 'product_price')
    end

    it 'omits product_price entirely when the price is blank' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, uri:, body: nil, **|
        calls << { method: method, uri: uri, body: body }
        method == :post ? ok('data' => { 'name' => 'LPR-9', 'product_name' => 'Red Cap' }) : ok('data' => [])
      end

      described_class.new(account).create(product_name: 'Red Cap', product_price: '')

      payload = JSON.parse(calls.find { |c| c[:method] == :post }[:body])
      expect(payload).not_to have_key('product_price')
    end

    it 'returns the existing record and performs ZERO POST for a normalized case-insensitive duplicate' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, uri:, body: nil, **|
        calls << { method: method, uri: uri, body: body }
        ok('data' => [{ 'name' => 'LPR-0001', 'product_name' => 'Blue Shirt' }])
      end

      # Different case + collapsible whitespace still matches the stored "Blue Shirt".
      result = described_class.new(account).create(product_name: '  blue   SHIRT ', product_price: '999')

      expect(result).to eq(value: 'LPR-0001', label: 'Blue Shirt', duplicate: true)
      expect(calls.map { |c| c[:method] }).to eq([:get])
      expect(calls.map { |c| c[:method] }).not_to include(:post)
    end

    it 'rejects a blank product_name before any network call' do
      expect { described_class.new(account).create(product_name: '   ', product_price: '10') }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::ValidationError)
      expect(calls).to be_empty
    end

    it 'rejects a negative / non-numeric / formatted price before any network call' do
      ['-5', 'abc', '50.000', '5,5'].each do |bad|
        calls.clear
        expect { described_class.new(account).create(product_name: 'Ok', product_price: bad) }
          .to raise_error(Wijaya::Batteries::ErpLeadSidebar::ValidationError)
        expect(calls).to be_empty
      end
    end

    it 'sanitizes an ERP timeout during create (no secret leak, no partial POST claim)' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request)
        .and_raise(Wijaya::Batteries::ErpLeadSidebar::SafeHttp::TimeoutError, 'ERPNext request timed out')

      expect { described_class.new(account).create(product_name: 'Ok', product_price: '10') }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::SyncError)
    end

    it 'treats a create response with no usable product_name as malformed (never shows the document id)' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, **|
        method == :post ? ok('data' => { 'name' => 'LPR-9', 'product_name' => '  ' }) : ok('data' => [])
      end

      expect { described_class.new(account).create(product_name: 'Red Cap', product_price: '10') }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::MalformedResponseError)
    end

    it 'raises a sanitized error when the create POST returns 5xx' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, **|
        method == :post ? http_error(Net::HTTPInternalServerError, '500', 'Server Error', 'exc' => 'raw ERP secret') : ok('data' => [])
      end

      expect { described_class.new(account).create(product_name: 'Ok', product_price: '10') }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::SyncError) { |e| expect(e.message).not_to include('raw ERP secret') }
    end
  end
end
