# frozen_string_literal: true

# Standalone smoke for RefreshService freshness reconciliation, runnable without
# the Rails/rspec stack: stubs ERPNext HTTP and asserts the conflict policy.
# Not part of the suite.
#   bundle exec ruby spec/custom/wijaya/erp_lead_sidebar/refresh_service_smoke.rb
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

        MARKET_CUSTOMER_FIELDS = %w[custom_brand_sendiri custom_tailor].freeze
        JENIS_PAKAIAN_FIELDS = %w[custom_gamis custom_batik].freeze
      end

      class PayloadBuilder
        DIRECT_FIELDS = %w[
          lead_owner first_name company_name whatsapp_no mobile_no status
          utm_source industry territory utm_campaign
        ].freeze
      end
    end
  end
end

require_relative 'refresh_service'

module RefreshSmoke
  Draft = Struct.new(:fields, :erp_lead_id, :sync_status) do
    attr_reader :updated

    def update!(attrs)
      @updated = attrs
      attrs.each { |key, value| self[key] = value if members.include?(key) }
    end
  end

  REQUESTS = [].freeze

  def self.response(klass, code, msg, body)
    resp = klass.new('1.1', code, msg)
    resp.define_singleton_method(:body) { body.to_json }
    resp
  end

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

RS = Wijaya::Batteries::ErpLeadSidebar::RefreshService

ERP_LEAD = {
  'first_name' => 'Remote Ana',
  'company_name' => 'Remote Co',
  'status' => 'Opportunity',
  'whatsapp_no' => '+628999',
  'mobile_no' => '+628999',
  'industry' => 'Manufacturing',
  'custom_tailor' => 1,
  'custom_batik' => '1',
  'custom_gamis' => 0
}.freeze

puts 'case 1: synced draft -> overwrite local fields with ERP data'
RefreshSmoke.install_http! do |_r|
  RefreshSmoke.response(Net::HTTPOK, '200', 'OK', 'data' => ERP_LEAD)
end
draft = RefreshSmoke::Draft.new({ 'first_name' => 'Stale Local' }, 'LEAD-0001', 'synced')
result = RS.new(draft).perform
RefreshSmoke.assert('issued a GET', RefreshSmoke::REQUESTS.map(&:method) == ['GET'])
RefreshSmoke.assert('get targets stored lead', RefreshSmoke::REQUESTS.first.path.include?('/api/resource/Lead/LEAD-0001'))
RefreshSmoke.assert('refreshed flag true', result[:refreshed] == true)
RefreshSmoke.assert('not a conflict', result[:conflict] == false)
RefreshSmoke.assert('message names the lead', result[:message].include?('LEAD-0001'))
RefreshSmoke.assert('draft fields overwritten', draft.fields['first_name'] == 'Remote Ana')
RefreshSmoke.assert('checkbox 1 -> true', draft.fields['custom_tailor'] == true)
RefreshSmoke.assert("checkbox '1' -> true", draft.fields['custom_batik'] == true)
RefreshSmoke.assert('checkbox 0 -> false', draft.fields['custom_gamis'] == false)
RefreshSmoke.assert('sync_status stays synced', draft.updated[:sync_status] == 'synced')

puts "case 2: unsynced draft (sync_status 'draft') -> keep local, return conflict"
RefreshSmoke.install_http! do |_r|
  RefreshSmoke.response(Net::HTTPOK, '200', 'OK', 'data' => ERP_LEAD)
end
draft = RefreshSmoke::Draft.new({ 'first_name' => 'Agent Edit' }, 'LEAD-0002', 'draft')
result = RS.new(draft).perform
RefreshSmoke.assert('conflict flag true', result[:conflict] == true)
RefreshSmoke.assert('not refreshed', result[:refreshed] == false)
RefreshSmoke.assert('local field preserved', draft.fields['first_name'] == 'Agent Edit')
RefreshSmoke.assert('draft not updated', draft.updated.nil?)
RefreshSmoke.assert('remote_fields exposed', result[:remote_fields]['first_name'] == 'Remote Ana')

puts 'case 3: failed draft is also treated as unsynced -> conflict'
RefreshSmoke.install_http! do |_r|
  RefreshSmoke.response(Net::HTTPOK, '200', 'OK', 'data' => ERP_LEAD)
end
draft = RefreshSmoke::Draft.new({ 'first_name' => 'Pending Retry' }, 'LEAD-0003', 'failed')
result = RS.new(draft).perform
RefreshSmoke.assert('conflict flag true', result[:conflict] == true)
RefreshSmoke.assert('local field preserved', draft.fields['first_name'] == 'Pending Retry')

puts 'case 4: ERP fetch fails -> keep local, soft warning, no overwrite'
RefreshSmoke.install_http! do |_r|
  RefreshSmoke.response(Net::HTTPBadGateway, '502', 'Bad Gateway', 'exc' => 'boom')
end
draft = RefreshSmoke::Draft.new({ 'first_name' => 'Local Only' }, 'LEAD-0004', 'synced')
result = RS.new(draft).perform
RefreshSmoke.assert('not refreshed', result[:refreshed] == false)
RefreshSmoke.assert('not a conflict', result[:conflict] == false)
RefreshSmoke.assert('warning message present', result[:message].to_s.include?('Could not refresh'))
RefreshSmoke.assert('local field preserved', draft.fields['first_name'] == 'Local Only')
RefreshSmoke.assert('draft not updated', draft.updated.nil?)

puts 'case 5: no erp_lead_id -> no-op, no HTTP'
RefreshSmoke.install_http! { |_r| raise 'HTTP should not be called' }
draft = RefreshSmoke::Draft.new({ 'first_name' => 'Unlinked' }, nil, 'draft')
result = RS.new(draft).perform
RefreshSmoke.assert('returns empty metadata', result == {})
RefreshSmoke.assert('no HTTP issued', RefreshSmoke::REQUESTS.empty?)

puts 'ALL SMOKE CHECKS PASSED'
