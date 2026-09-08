# frozen_string_literal: true

require 'rails_helper'

# Phase 7 — Cross-flow SECURITY invariants for the deterministic product-catalog path.
#
# The per-component specs (catalog/*_spec.rb, conversation/*_spec.rb, documents/*_spec.rb)
# already prove each unit's behavior with injected fakes. This aggregate spec proves the
# SYSTEMIC, source-level guarantees that no single behavioral unit test can establish and
# that a future edit could silently break:
#
#   * every external catalog query targets ONLY the five approved tables
#     (item / item_variant_attribute / item_price / price_list / bin);
#   * every external catalog query is a single, parameterized SELECT the connection
#     guard accepts (no multi-statement / dynamic SQL);
#   * stock availability never projects a raw numeric quantity column; and
#   * the deterministic product path issues NO direct provider or channel API call.
#
# It executes the REAL repository SQL-builders (through a capturing Connection stub) and
# reads the REAL shipped sources, so it fails closed if the contract regresses.
RSpec.describe 'Marine catalog cross-flow security invariants' do
  # The complete allowlist of physical catalog tables the blueprint approves. Any other
  # FROM/JOIN target is a contract violation.
  APPROVED_CATALOG_TABLES = %w[item item_variant_attribute item_price price_list bin].freeze

  # Source files that make up the deterministic product decision + native delivery path.
  # Excludes the catalog Connection/Config (the DB transport itself) and the LLM-backed
  # intent extractor (which reasons only through the injected Marine LLM abstraction).
  PRODUCT_PATH_SOURCES = %w[
    app/services/marine/catalog/product_query_orchestrator.rb
    app/services/marine/catalog/reply_renderer.rb
    app/services/marine/catalog/variant_resolver.rb
    app/services/marine/catalog/product_family_repository.rb
    app/services/marine/catalog/variant_repository.rb
    app/services/marine/catalog/price_repository.rb
    app/services/marine/catalog/stock_repository.rb
    app/services/marine/catalog/product_flow_state_store.rb
    app/services/marine/conversation/product_message_delivery_service.rb
    app/services/marine/documents/product_catalog_selector.rb
    app/jobs/marine/conversation/response_builder_job.rb
  ].freeze

  # Unambiguous external-egress / channel-send tokens. None of these belong in the
  # deterministic product path: delivery happens ONLY by persisting a native Message
  # (whose native callbacks own the actual channel send), and reasoning happens ONLY
  # through the injected Marine LLM service — never a raw HTTP client or channel call.
  FORBIDDEN_EGRESS = [
    'Net::HTTP', 'Faraday', 'HTTParty', 'RestClient', 'Excon', 'open-uri', 'URI.open',
    'Anthropic', 'OpenAI', 'Twilio', 'Whatsapp', 'Facebook', 'Instagram', 'Bandwidth',
    'Channels::', 'SendReplyJob', 'send_reply', '.deliver_now', '.deliver_later'
  ].freeze

  let(:battery_root) { Rails.root.join('custom/wijaya/batteries/marine_ai') }

  describe 'approved-table-only, single-SELECT catalog access' do
    # Drives every read-only repository method through a Connection stub that records the
    # SQL the REAL builders produce, so the assertions cover the shipped SQL, not a copy.
    let(:captured) { [] }

    before do
      allow(Marine::Catalog::Config).to receive_messages(
        configured?: true, schema: 'marine_ai', table: 'item', qualified_table: 'marine_ai.item'
      )
      allow(Marine::Catalog::Connection).to receive(:select) do |sql, _params|
        captured << sql
        [] # benign empty result; a fail-closed raise after capture is ignored below
      end
      exercise_every_repository
    end

    # Invoke each public repository entry point so its SQL is captured. Any fail-closed
    # CatalogError (e.g. StockRepository on an empty result) fires AFTER the SQL is
    # recorded, so it is safely swallowed here.
    def exercise_every_repository
      family = Marine::Catalog::ProductFamilyRepository.new
      variant = Marine::Catalog::VariantRepository.new
      price = Marine::Catalog::PriceRepository.new
      stock = Marine::Catalog::StockRepository.new

      [-> { family.exists?('F') }, -> { family.search(query: 'q') }, -> { family.resolve_exact('F') },
       -> { family.active_candidates(query: 'q') }, -> { variant.resolve_child('F', 'C') },
       -> { variant.attribute_names('F') }, -> { variant.resolve_by_attribute('F', 'a', 'v') },
       -> { price.price_for('C') }, -> { stock.status_for('C') }].each do |call|
        call.call
      rescue Marine::Catalog::Errors::CatalogError
        nil
      end
    end

    def tables_in(sql)
      sql.scan(/\b(?:FROM|JOIN)\s+([a-z_][a-z0-9_.]*)/i).flatten.map { |token| token.split('.').last }
    end

    it 'exercises the full repository surface (guards against an untested new query)' do
      expect(captured.length).to eq(9)
    end

    it 'references only the five approved catalog tables across every query' do
      referenced = captured.flat_map { |sql| tables_in(sql) }.uniq

      expect(referenced).to match_array(APPROVED_CATALOG_TABLES)
      expect(referenced - APPROVED_CATALOG_TABLES).to be_empty
    end

    it 'issues only single-statement parameterized SELECTs the connection guard accepts' do
      captured.each do |sql|
        expect(Marine::Catalog::Connection.single_select?(sql)).to be(true)
        expect(sql).not_to include(';')
        expect(sql).to match(/\$\d/) # client/policy values are bound, never interpolated
      end
    end

    it 'never projects a raw numeric stock quantity — stock is a single binary status column' do
      stock_sql = captured.find { |sql| tables_in(sql) == ['bin'] }
      projection = stock_sql[/SELECT(.*?)\bFROM\b/im, 1]

      expect(projection).to match(/\bAS status\b/i)             # a status column
      expect(projection.scan(/\bAS\b/i).length).to eq(1)        # exactly ONE aliased output column
      expect(projection).to match(/SUM\(\s*actual_qty\s*\)/i)   # qty is only summed...
      expect(projection.gsub(/SUM\(\s*actual_qty\s*\)/i, '')).not_to include('actual_qty') # ...never projected raw
    end
  end

  describe 'binary stock status crossing the boundary' do
    it 'returns a Symbol status, never a numeric quantity' do
      allow(Marine::Catalog::Config).to receive(:configured?).and_return(true)
      allow(Marine::Catalog::Connection).to receive(:select).and_return([{ 'status' => 'available' }])

      result = Marine::Catalog::StockRepository.new.status_for('CHILD-1')

      expect(result).to eq(:available)
      expect(result).not_to be_a(Numeric)
    end
  end

  describe 'no direct provider or channel egress in the product path' do
    it 'contains no raw HTTP client or channel-send call in any product-path source' do
      offenders = PRODUCT_PATH_SOURCES.each_with_object({}) do |relative, acc|
        # Scan executable code only — full-line comments legitimately describe the native
        # delivery path (e.g. mention SendReplyJob) without ever calling it.
        code = File.read(battery_root.join(relative)).lines.reject { |line| line.strip.start_with?('#') }.join
        hits = FORBIDDEN_EGRESS.select { |token| code.include?(token) }
        acc[relative] = hits if hits.any?
      end

      expect(offenders).to eq({})
    end
  end
end
