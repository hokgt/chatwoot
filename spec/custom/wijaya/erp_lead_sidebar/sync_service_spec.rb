# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::ErpLeadSidebar::SyncService do
  let(:fields) do
    {
      'first_name' => 'Ana',
      'whatsapp_no' => '+628123456789',
      'status' => 'Lead',
      'industry' => 'Garment'
    }
  end

  let(:erp_lead_id) { nil }
  let(:draft) { double('ErpLeadDraft', fields: fields, erp_lead_id: erp_lead_id) }
  let(:requests) { [] }
  # Default responder: create returns a fresh Lead; list/search returns nothing.
  let(:responder) do
    lambda do |request|
      request.is_a?(Net::HTTP::Get) ? ok('data' => []) : ok('data' => { 'name' => 'LEAD-NEW' })
    end
  end

  def ok(body)
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    allow(response).to receive(:body).and_return(body.to_json)
    response
  end

  def not_found(body = {})
    response = Net::HTTPNotFound.new('1.1', '404', 'Not Found')
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
    allow(draft).to receive(:update!)

    http = instance_double(Net::HTTP)
    allow(Net::HTTP).to receive(:start).and_yield(http)
    allow(http).to receive(:request) do |request|
      requests << request
      instance_exec(request, &responder)
    end
  end

  context 'with a stored erp_lead_id' do
    let(:erp_lead_id) { 'LEAD-0001' }
    let(:responder) { ->(_request) { ok('data' => { 'name' => 'LEAD-0001' }) } }

    it 'updates the existing lead via PUT and never creates' do
      result = described_class.new(draft).perform

      expect(requests.map(&:method)).to eq(['PUT'])
      expect(requests.first.path).to include('/api/resource/Lead/LEAD-0001')
      expect(result[:erp_lead_id]).to eq('LEAD-0001')
      expect(draft).to have_received(:update!).with(
        hash_including(erp_lead_id: 'LEAD-0001', sync_status: 'synced', last_error: nil)
      )
    end
  end

  context 'with no stored id but a matching phone in ERP' do
    let(:responder) do
      lambda do |request|
        request.is_a?(Net::HTTP::Get) ? ok('data' => [{ 'name' => 'LEAD-EXISTING' }]) : ok('data' => { 'name' => 'LEAD-EXISTING' })
      end
    end

    it 'adopts the found lead via PUT and stores its id, without POSTing' do
      result = described_class.new(draft).perform

      methods = requests.map(&:method)
      expect(methods).to include('GET', 'PUT')
      expect(methods).not_to include('POST')
      expect(result[:erp_lead_id]).to eq('LEAD-EXISTING')
      expect(draft).to have_received(:update!).with(hash_including(erp_lead_id: 'LEAD-EXISTING'))
    end
  end

  context 'with no stored id and no phone match' do
    it 'creates a new lead via POST' do
      result = described_class.new(draft).perform

      methods = requests.map(&:method)
      expect(methods).to include('GET')
      expect(methods.last).to eq('POST')
      expect(methods).not_to include('PUT')
      expect(result[:erp_lead_id]).to eq('LEAD-NEW')
    end
  end

  context 'when the stored lead is missing in ERP' do
    let(:erp_lead_id) { 'LEAD-GONE' }
    let(:responder) { ->(_request) { not_found('exc' => 'DoesNotExistError') } }

    it 'raises for relink instead of creating a duplicate' do
      expect { described_class.new(draft).perform }
        .to raise_error(Wijaya::Batteries::ErpLeadSidebar::SyncError, /relink/)

      expect(requests.map(&:method)).to eq(['PUT'])
    end
  end
end
