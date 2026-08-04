# frozen_string_literal: true

# Standalone smoke for SyncService idempotency, runnable without the Rails/rspec
# stack: stubs ERPNext HTTP and asserts verb selection. Not part of the suite.
#   bundle exec ruby spec/custom/wijaya/erp_lead_sidebar/sync_service_smoke.rb
require 'active_support/all'
require 'net/http'
require 'json'
require 'uri'

# Nested (not compact) so this standalone smoke can create the Wijaya parent chain
# itself when run via bare `ruby` with Wijaya undefined; a compact
# `module Wijaya::Batteries::ErpLeadSidebar` raises `uninitialized constant Wijaya`.
module Wijaya
  module Batteries
    module ErpLeadSidebar
      module Config
        module_function

        def erp_configured? = true
        def erp_base_url = 'https://erp.example.com'
        def erp_api_key = 'key'
        def erp_api_secret = 'secret'
      end

      class PayloadBuilder
        def initialize(fields) = (@fields = fields)

        def payload
          { :doctype => 'Lead', 'first_name' => 'Ana',
            'whatsapp_no' => @fields['whatsapp_no'], 'mobile_no' => @fields['whatsapp_no'] }
        end
      end
    end
  end
end

require_relative 'sync_service'

module SyncSmoke
  Draft = Struct.new(:fields, :erp_lead_id) do
    attr_reader :updated

    def update!(attrs)
      @updated = attrs
    end
  end

  REQUESTS = [].freeze

  def self.response(klass, code, msg, body)
    resp = klass.new('1.1', code, msg)
    resp.define_singleton_method(:body) { body.to_json }
    resp
  end

  # Install a fake Net::HTTP.start that records requests and replies via `@responder`.
  def self.install_http!
    REQUESTS.clear
    fake_http = Object.new
    fake_http.define_singleton_method(:request) do |request|
      REQUESTS << request
      yield(request)
    end
    Net::HTTP.define_singleton_method(:start) do |*_args, **_kw, &block|
      block.call(fake_http)
    end
  end

  def self.assert(label, condition)
    raise "FAIL: #{label}" unless condition

    puts "  ok: #{label}"
  end
end

SS = Wijaya::Batteries::ErpLeadSidebar::SyncService
fields = { 'whatsapp_no' => '+628123456789' }

puts 'case 1: stored erp_lead_id -> PUT only'
SyncSmoke.install_http! { |_r| SyncSmoke.response(Net::HTTPOK, '200', 'OK', 'data' => { 'name' => 'LEAD-0001' }) }
draft = SyncSmoke::Draft.new(fields, 'LEAD-0001')
result = SS.new(draft).perform
SyncSmoke.assert('only PUT issued', SyncSmoke::REQUESTS.map(&:method) == ['PUT'])
SyncSmoke.assert('put targets stored lead', SyncSmoke::REQUESTS.first.path.include?('/api/resource/Lead/LEAD-0001'))
SyncSmoke.assert('returns stored id', result[:erp_lead_id] == 'LEAD-0001')
SyncSmoke.assert('draft marked synced', draft.updated[:sync_status] == 'synced' && draft.updated[:erp_lead_id] == 'LEAD-0001')

puts 'case 2: no id + phone match -> GET then PUT, stores found id, no POST'
SyncSmoke.install_http! do |request|
  if request.is_a?(Net::HTTP::Get)
    SyncSmoke.response(Net::HTTPOK, '200', 'OK', 'data' => [{ 'name' => 'LEAD-EXISTING' }])
  else
    SyncSmoke.response(Net::HTTPOK, '200', 'OK', 'data' => { 'name' => 'LEAD-EXISTING' })
  end
end
draft = SyncSmoke::Draft.new(fields, nil)
result = SS.new(draft).perform
methods = SyncSmoke::REQUESTS.map(&:method)
SyncSmoke.assert('searched via GET', methods.include?('GET'))
SyncSmoke.assert('updated via PUT', methods.include?('PUT'))
SyncSmoke.assert('did not POST', methods.exclude?('POST'))
SyncSmoke.assert('stored found id', result[:erp_lead_id] == 'LEAD-EXISTING' && draft.updated[:erp_lead_id] == 'LEAD-EXISTING')

puts 'case 3: no id + no match -> POST'
SyncSmoke.install_http! do |request|
  if request.is_a?(Net::HTTP::Get)
    SyncSmoke.response(Net::HTTPOK, '200', 'OK', 'data' => [])
  else
    SyncSmoke.response(Net::HTTPOK, '200', 'OK', 'data' => { 'name' => 'LEAD-NEW' })
  end
end
draft = SyncSmoke::Draft.new(fields, nil)
result = SS.new(draft).perform
methods = SyncSmoke::REQUESTS.map(&:method)
SyncSmoke.assert('searched via GET', methods.include?('GET'))
SyncSmoke.assert('created via POST', methods.last == 'POST')
SyncSmoke.assert('no PUT', methods.exclude?('PUT'))
SyncSmoke.assert('stored new id', result[:erp_lead_id] == 'LEAD-NEW')

puts 'case 4: stored id missing (404) -> raise relink, no duplicate create'
SyncSmoke.install_http! { |_r| SyncSmoke.response(Net::HTTPNotFound, '404', 'Not Found', 'exc' => 'DoesNotExistError') }
draft = SyncSmoke::Draft.new(fields, 'LEAD-GONE')
begin
  SS.new(draft).perform
  raise 'FAIL: expected SyncError'
rescue Wijaya::Batteries::ErpLeadSidebar::SyncError => e
  SyncSmoke.assert('raised relink error', e.message.include?('relink'))
  SyncSmoke.assert('only PUT attempted', SyncSmoke::REQUESTS.map(&:method) == ['PUT'])
end

puts 'ALL SMOKE CHECKS PASSED'
