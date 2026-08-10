# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::ErpLeadSidebar::LeadActivityService do
  let(:account) { double('Account', id: 4242) }
  let(:erp_lead_id) { 'LEAD-0001' }
  let(:assignee) { double('User', id: 55, name: 'Agent Smith') }
  let(:conversation) { double('Conversation', assignee: assignee) }
  let(:draft) do
    double('ErpLeadDraft', account: account, erp_lead_id: erp_lead_id, conversation_id: 77, conversation: conversation)
  end
  let(:agent) { double('User', id: 9) }
  let(:submission_id) { SecureRandom.uuid }
  let(:valid_names) { %w[Call WhatsApp] }
  let(:params) do
    {
      'submission_id' => submission_id,
      'date' => '2026-08-10',
      'lead_activity' => 'Call',
      'follow_up' => 'No',
      'follow_up_date' => '',
      'follow_up_activity' => '',
      'person_in_charge' => '',
      'remark' => 'hi'
    }
  end

  let(:requests) { [] }
  # Default: the insert POST succeeds and any User GET returns no match.
  let(:responder) do
    lambda do |request|
      request.is_a?(Net::HTTP::Get) ? ok('data' => []) : ok('data' => { 'name' => 'ACT-1' })
    end
  end

  def ok(body)
    build_response(Net::HTTPOK.new('1.1', '200', 'OK'), body)
  end

  def bad_request(body = {})
    build_response(Net::HTTPBadRequest.new('1.1', '400', 'Bad Request'), body)
  end

  def server_error(body = {})
    build_response(Net::HTTPInternalServerError.new('1.1', '500', 'Server Error'), body)
  end

  def build_response(response, body)
    allow(response).to receive(:body).and_return(body.to_json)
    response
  end

  def lock_key(sid = submission_id)
    "wijaya:erp_lead_activity:lock:#{account.id}:#{sid}"
  end

  def outcome_key(sid = submission_id)
    "wijaya:erp_lead_activity:outcome:#{account.id}:#{sid}"
  end

  def service(overrides = {})
    described_class.new(draft: draft, agent: agent, params: params.merge(overrides))
  end

  def post_requests
    requests.select { |request| request.is_a?(Net::HTTP::Post) }
  end

  before do
    allow(Wijaya::Batteries::ErpLeadSidebar::Config).to receive_messages(
      erp_configured?: true,
      erp_base_url: 'https://erp.example.com',
      erp_api_key: 'key',
      erp_api_secret: 'secret'
    )
    options_service = instance_double(
      Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService, fetch_names: valid_names
    )
    allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).to receive(:new).and_return(options_service)

    allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, uri:, body: nil, **|
      request = SsrfFilter::VERB_MAP.fetch(method).new(uri)
      request.body = body if body
      requests << request
      instance_exec(request, &responder)
    end
  end

  after do
    Redis::Alfred.delete(lock_key)
    Redis::Alfred.delete(outcome_key)
  end

  context 'on a valid submission' do
    it 'POSTs exactly one frappe.client.insert with the server-derived parent' do
      result = service.perform

      expect(result.http_status).to eq(:ok)
      expect(result.body[:message]).to eq('Lead Activity added successfully.')
      expect(post_requests.size).to eq(1)

      post = post_requests.first
      expect(post.path).to include('/api/method/frappe.client.insert')
      doc = JSON.parse(post.body)['doc']
      expect(doc['parent']).to eq('LEAD-0001')
      expect(doc['doctype']).to eq('Lead Activity')
      expect(doc['remark']).to eq("[chatwoot:activity:#{submission_id}] hi")
    end

    it 'never issues a PUT or DELETE against ERP' do
      service.perform

      methods = requests.map(&:method)
      expect(methods).not_to include('PUT')
      expect(methods).not_to include('DELETE')
    end

    it 'caches the success so a resubmission returns success without a second POST' do
      first = service.perform
      expect(first.http_status).to eq(:ok)

      second = service.perform
      expect(second.http_status).to eq(:ok)
      expect(second.body[:message]).to eq('Lead Activity added successfully.')
      expect(post_requests.size).to eq(1)
    end

    it 'forces the follow-up fields empty when follow_up is No' do
      service('follow_up' => 'No', 'follow_up_date' => '2026-09-01', 'follow_up_activity' => 'Call').perform

      doc = JSON.parse(post_requests.first.body)['doc']
      expect(doc['follow_up_date']).to eq('')
      expect(doc['follow_up_activity']).to eq('')
    end

    it 'ignores any client-supplied structural override and uses the draft parent' do
      service('parent' => 'HACK', 'doctype' => 'Sales Order', 'parentfield' => 'x').perform

      doc = JSON.parse(post_requests.first.body)['doc']
      expect(doc['parent']).to eq('LEAD-0001')
      expect(doc['doctype']).to eq('Lead Activity')
      expect(doc['parentfield']).to eq('custom_lead_activity')
    end
  end

  context 'when no ERP Lead is linked' do
    let(:erp_lead_id) { '' }

    it 'returns a no-lead result and issues no ERP request' do
      result = service.perform

      expect(result.http_status).to eq(:unprocessable_entity)
      expect(result.status).to eq('no_lead')
      expect(requests).to be_empty
    end
  end

  context 'with an invalid submission id' do
    it 'returns an invalid result and issues no ERP request' do
      result = service('submission_id' => 'not-a-uuid').perform

      expect(result.http_status).to eq(:unprocessable_entity)
      expect(result.status).to eq('invalid')
      expect(requests).to be_empty
    end
  end

  context 'with a field that fails validation' do
    it 'returns a validation error without POSTing' do
      result = service('date' => 'not-a-date').perform

      expect(result.http_status).to eq(:unprocessable_entity)
      expect(result.status).to eq('invalid')
      expect(post_requests).to be_empty
    end
  end

  context 'when the Lead Activity options are unavailable' do
    before do
      unavailable = instance_double(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService)
      allow(unavailable).to receive(:fetch_names)
        .and_raise(Wijaya::Batteries::ErpLeadSidebar::SyncError)
      allow(Wijaya::Batteries::ErpLeadSidebar::LeadActivityOptionsService).to receive(:new).and_return(unavailable)
    end

    it 'rejects before any insert with a bad_gateway' do
      result = service.perform

      expect(result.http_status).to eq(:bad_gateway)
      expect(result.status).to eq('options_unavailable')
      expect(post_requests).to be_empty
    end
  end

  context 'person in charge resolution (server-derived from the assignee)' do
    let(:directory) { Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory }

    def get_requests
      requests.select { |request| request.is_a?(Net::HTTP::Get) }
    end

    it 'derives the candidate from the conversation assignee and keeps it when ERP confirms it' do
      allow(directory).to receive(:erp_user_for).with(assignee).and_return('agent@erp.example')
      # GET User lookup confirms the exact name; POST inserts.
      responder = lambda do |request|
        if request.is_a?(Net::HTTP::Get)
          ok('data' => [{ 'name' => 'agent@erp.example' }])
        else
          ok('data' => { 'name' => 'ACT-1' })
        end
      end
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, uri:, body: nil, **|
        request = SsrfFilter::VERB_MAP.fetch(method).new(uri)
        request.body = body if body
        requests << request
        responder.call(request)
      end

      service.perform

      doc = JSON.parse(post_requests.first.body)['doc']
      expect(doc['person_in_charge']).to eq('agent@erp.example')
    end

    it 'drops the mapped candidate that ERPNext cannot confirm' do
      allow(directory).to receive(:erp_user_for).with(assignee).and_return('agent@erp.example')
      # Default responder returns an empty User list -> not confirmed.
      service.perform

      doc = JSON.parse(post_requests.first.body)['doc']
      expect(doc['person_in_charge']).to eq('')
    end

    it 'records no person in charge (and issues no User lookup) when the assignee is unmapped' do
      # Real, empty shared map: the assignee id/name resolve to nothing.
      service.perform

      doc = JSON.parse(post_requests.first.body)['doc']
      expect(doc['person_in_charge']).to eq('')
      expect(get_requests).to be_empty
    end

    it 'ignores a browser-supplied person_in_charge and cannot be used to pick another mapped candidate' do
      # Server maps the assignee to a confirmed candidate; the browser proposes a
      # different value. The browser value must never be looked up or recorded.
      allow(directory).to receive(:erp_user_for).with(assignee).and_return('agent@erp.example')
      responder = lambda do |request|
        if request.is_a?(Net::HTTP::Get)
          # Confirm ONLY the server-derived name; the browser value is never looked up.
          request.path.include?('agent%40erp.example') ? ok('data' => [{ 'name' => 'agent@erp.example' }]) : ok('data' => [])
        else
          ok('data' => { 'name' => 'ACT-1' })
        end
      end
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, uri:, body: nil, **|
        request = SsrfFilter::VERB_MAP.fetch(method).new(uri)
        request.body = body if body
        requests << request
        responder.call(request)
      end

      service('person_in_charge' => 'attacker@erp.example').perform

      doc = JSON.parse(post_requests.first.body)['doc']
      expect(doc['person_in_charge']).to eq('agent@erp.example')
      # Never looked up the browser-proposed candidate.
      expect(get_requests.map(&:path).join).not_to include('attacker%40erp.example')
    end
  end

  context 'concurrency and idempotency' do
    it 'blocks a concurrent submission holding the in-flight lock' do
      Redis::Alfred.set(lock_key, 'other-token', ex: 30)

      result = service.perform

      expect(result.http_status).to eq(:conflict)
      expect(result.status).to eq('in_flight')
      expect(post_requests).to be_empty
    end
  end

  context 'when ERP returns a definite 4xx rejection' do
    let(:responder) { ->(_request) { bad_request('exc' => 'ValidationError') } }

    it 'returns a rejection, caches no outcome, and allows a corrected retry' do
      result = service.perform

      expect(result.http_status).to eq(:unprocessable_entity)
      expect(result.status).to eq('rejected')
      expect(Redis::Alfred.get(outcome_key)).to be_nil
    end
  end

  context 'when ERP returns a 5xx ambiguous status' do
    let(:responder) { ->(_request) { server_error('exc' => 'boom') } }

    it 'records outcome_unknown and blocks a same-id resubmission' do
      first = service.perform
      expect(first.http_status).to eq(:bad_gateway)
      expect(first.status).to eq('outcome_unknown')
      expect(Redis::Alfred.get(outcome_key)).to eq('outcome_unknown')

      second = service.perform
      expect(second.http_status).to eq(:conflict)
      expect(second.status).to eq('outcome_unknown')
    end
  end

  context 'when the transport times out' do
    let(:responder) do
      ->(_request) { raise Wijaya::Batteries::ErpLeadSidebar::SafeHttp::TimeoutError, 'timed out' }
    end

    it 'records outcome_unknown' do
      result = service.perform

      expect(result.http_status).to eq(:bad_gateway)
      expect(result.status).to eq('outcome_unknown')
      expect(Redis::Alfred.get(outcome_key)).to eq('outcome_unknown')
    end
  end
end
