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

  context 'with a person in charge (manually chosen, exact-revalidated before insert)' do
    def get_requests
      requests.select { |request| request.is_a?(Net::HTTP::Get) }
    end

    # Re-stubs SafeHttp so a User GET reflects `user_present` while the insert
    # POST always succeeds; records the requests for assertions.
    def stub_directory(user_present:)
      responder = lambda do |request|
        if request.is_a?(Net::HTTP::Get)
          user_present ? ok('data' => [{ 'name' => 'agent@erp.example' }]) : ok('data' => [])
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
    end

    it 'accepts a blank selection with no User directory lookup and inserts with an empty PIC' do
      # Default params carry a blank person_in_charge.
      service.perform

      doc = JSON.parse(post_requests.first.body)['doc']
      expect(doc['person_in_charge']).to eq('')
      expect(get_requests).to be_empty
      expect(post_requests.size).to eq(1)
    end

    it 'exact-revalidates a chosen active user and records it on the insert' do
      stub_directory(user_present: true)

      service('person_in_charge' => 'agent@erp.example').perform

      doc = JSON.parse(post_requests.first.body)['doc']
      expect(doc['person_in_charge']).to eq('agent@erp.example')
      # A fresh exact User lookup was issued for the chosen value.
      expect(get_requests.map(&:path).join).to include('agent%40erp.example')
    end

    it 'rejects an unknown/deleted value with a 422 and issues no insert' do
      stub_directory(user_present: false)

      result = service('person_in_charge' => 'ghost@erp.example').perform

      expect(result.http_status).to eq(:unprocessable_entity)
      expect(result.status).to eq('invalid')
      expect(post_requests).to be_empty
    end

    it 'rejects a disabled/Guest/stale value (filtered out by ERP) with a 422 and no insert' do
      # enabled=1 + name!=Guest filters mean a disabled/Guest/stale name returns
      # no row, which is a definite invalid -> 422, never normalized to blank.
      stub_directory(user_present: false)

      result = service('person_in_charge' => 'Guest').perform

      expect(result.http_status).to eq(:unprocessable_entity)
      expect(result.status).to eq('invalid')
      expect(post_requests).to be_empty
    end

    it 'returns a 502 and issues no insert when the directory lookup is a non-success' do
      responder = lambda do |request|
        request.is_a?(Net::HTTP::Get) ? server_error('exc' => 'boom') : ok('data' => { 'name' => 'ACT-1' })
      end
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, uri:, body: nil, **|
        request = SsrfFilter::VERB_MAP.fetch(method).new(uri)
        request.body = body if body
        requests << request
        responder.call(request)
      end

      result = service('person_in_charge' => 'agent@erp.example').perform

      expect(result.http_status).to eq(:bad_gateway)
      expect(result.status).to eq('options_unavailable')
      expect(post_requests).to be_empty
      # Ambiguous availability must not poison the submission id.
      expect(Redis::Alfred.get(outcome_key)).to be_nil
    end

    it 'returns a 502 and issues no insert when the directory transport fails' do
      allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, uri:, body: nil, **|
        request = SsrfFilter::VERB_MAP.fetch(method).new(uri)
        request.body = body if body
        requests << request
        raise Wijaya::Batteries::ErpLeadSidebar::SafeHttp::TimeoutError, 'timed out' if request.is_a?(Net::HTTP::Get)

        ok('data' => { 'name' => 'ACT-1' })
      end

      result = service('person_in_charge' => 'agent@erp.example').perform

      expect(result.http_status).to eq(:bad_gateway)
      expect(result.status).to eq('options_unavailable')
      expect(post_requests).to be_empty
    end

    it 'rejects an oversized manipulated value with a 422, no lookup, no insert, and no cached outcome' do
      # A browser-manipulated value past the directory bound is a definite
      # invalid: bounded locally before any request, so zero User GET and zero
      # insert, and the submission id stays clean for a corrected retry.
      oversized = "#{'a' * 300}@erp.example"

      result = service('person_in_charge' => oversized).perform

      expect(result.http_status).to eq(:unprocessable_entity)
      expect(result.status).to eq('invalid')
      expect(get_requests).to be_empty
      expect(post_requests).to be_empty
      expect(Redis::Alfred.get(outcome_key)).to be_nil
    end
  end

  # Directly exercises the ERP User directory contract that backs both the PIC
  # picker options and the pre-insert revalidation. Uses the same SafeHttp stub
  # (records into `requests`, replies via `responder`) as the service specs.
  context 'with the LeadActivityPersonDirectory contract' do
    let(:directory) { Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory }

    def only_request
      expect(requests.size).to eq(1)
      requests.first
    end

    # Decoded query params of the (single) issued GET.
    def query_of(request)
      URI.decode_www_form(URI(request.path).query).to_h
    end

    describe '.fetch_options' do
      let(:responder) do
        lambda do |_request|
          ok('data' => [
               { 'name' => 'zoe@erp.example', 'full_name' => 'Zoe', 'enabled' => 1, 'roles' => ['System Manager'] },
               { 'name' => 'amy@erp.example', 'full_name' => 'amy adams', 'secret' => 'leak-me' },
               { 'name' => 'nolabel@erp.example', 'full_name' => '' }
             ])
        end
      end

      it 'issues a single GET /api/resource/User asking strictly for name and full_name' do
        directory.fetch_options(account)

        request = only_request
        expect(request).to be_a(Net::HTTP::Get)
        expect(request.path).to include('/api/resource/User')
        expect(query_of(request)['fields']).to eq('["name","full_name"]')
      end

      it 'restricts the list to enabled=1 and name!=Guest' do
        directory.fetch_options(account)

        filters = JSON.parse(query_of(only_request)['filters'])
        expect(filters).to include(['User', 'enabled', '=', 1])
        expect(filters).to include(['User', 'name', '!=', 'Guest'])
      end

      it 'returns only value/label, falls back full_name to name, sorts deterministically, and hides raw keys' do
        options = directory.fetch_options(account)

        expect(options).to eq(
          [
            { value: 'amy@erp.example', label: 'amy adams' },
            { value: 'nolabel@erp.example', label: 'nolabel@erp.example' },
            { value: 'zoe@erp.example', label: 'Zoe' }
          ]
        )
        # No raw ERP row key (enabled/roles/secret) ever leaks through.
        expect(options.flat_map(&:keys).uniq).to eq(%i[value label])
      end
    end

    describe '.valid?' do
      it 'queries the exact name alongside enabled=1 and name!=Guest, asking only for name' do
        allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, uri:, **|
          request = SsrfFilter::VERB_MAP.fetch(method).new(uri)
          requests << request
          ok('data' => [{ 'name' => 'agent@erp.example' }])
        end

        expect(directory.valid?(account, 'agent@erp.example')).to be(true)

        query = query_of(only_request)
        expect(query['fields']).to eq('["name"]')
        filters = JSON.parse(query['filters'])
        expect(filters).to include(['User', 'enabled', '=', 1])
        expect(filters).to include(['User', 'name', '!=', 'Guest'])
        expect(filters).to include(['User', 'name', '=', 'agent@erp.example'])
      end

      it 'requires exact row equality: a near-match row that is not the target is invalid' do
        allow(Wijaya::Batteries::ErpLeadSidebar::SafeHttp).to receive(:request) do |method:, uri:, **|
          request = SsrfFilter::VERB_MAP.fetch(method).new(uri)
          requests << request
          ok('data' => [{ 'name' => 'agent@erp.example.evil' }])
        end

        expect(directory.valid?(account, 'agent@erp.example')).to be(false)
      end
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
