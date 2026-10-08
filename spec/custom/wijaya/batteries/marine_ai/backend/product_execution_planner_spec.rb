# frozen_string_literal: true

require 'rails_helper'

# Phase 1 (Opsi B) — backend repository validation & execution plan. Every repository is INJECTED
# and mocked; no catalog DB, provider, or state is touched. Execution authorization is
# backend-policy-owned (Marine::Backend::ExecutionPolicy): the executable set is exactly ["price"],
# and a non-price / empty / mixed intent set fails closed to a factless handoff BEFORE any repository
# read. Scenario carries provenance only ({ key: }). The real PriceDisplayFormatter is used for the
# immutable display envelope (pure/deterministic).
RSpec.describe Marine::Backend::ProductExecutionPlanner do
  subject(:planner) do
    described_class.new(
      family_repository: family_repository, variant_resolver: variant_resolver,
      price_repository: price_repository, stock_repository: stock_repository,
      price_formatter: Marine::Catalog::PriceDisplayFormatter.new, clock: clock
    )
  end

  let(:clock) { -> { Time.utc(2026, 9, 30, 12, 0, 0) } }
  let(:catalog_error) { Marine::Catalog::Errors::CatalogUnavailableError }
  let(:checked_at) { '2026-09-30T12:00:00Z' }

  let(:family_repository) { instance_double(Marine::Catalog::ProductFamilyRepository) }
  let(:variant_resolver) { instance_double(Marine::Catalog::VariantResolver) }
  let(:price_repository) { instance_double(Marine::Catalog::PriceRepository) }
  let(:stock_repository) { instance_double(Marine::Catalog::StockRepository) }

  def product_intent(overrides = {})
    {
      family_mention: 'Santorini', explicit_child_code: 'BD-4', attribute_candidates: [],
      customer_language: 'id'
    }.merge(overrides)
  end

  before do
    allow(family_repository).to receive(:resolve_exact).with('Santorini').and_return(code: 'BD', name: 'Santorini')
    allow(variant_resolver).to receive(:resolve).and_return(status: :resolved, code: 'BD-4')
  end

  def call(intents:, intent_overrides: {})
    planner.call(product_intent: product_intent(intent_overrides), intents: intents,
                 scenario: { key: 'scenario_8' })
  end

  describe 'execution boundary (ExecutionPolicy-authorized; fails closed BEFORE any repository read)' do
    it 'hands off on an empty intent set' do
      result = call(intents: [])
      expect(result[:response_goals]).to eq(%w[handoff])
      expect(result[:facts]).to eq({})
    end

    it 'hands off on an unsupported intent without touching any repository' do
      expect(family_repository).not_to receive(:resolve_exact)
      expect(variant_resolver).not_to receive(:resolve)
      expect(price_repository).not_to receive(:price_for)
      expect(stock_repository).not_to receive(:status_for)
      result = call(intents: %w[order_status])
      expect(result[:response_goals]).to eq(%w[handoff])
    end

    it 'hands off on a supported-but-unauthorized (variant_info) intent without touching any repository' do
      expect(family_repository).not_to receive(:resolve_exact)
      expect(variant_resolver).not_to receive(:resolve)
      expect(price_repository).not_to receive(:price_for)
      expect(stock_repository).not_to receive(:status_for)
      result = call(intents: %w[variant_info])
      expect(result[:response_goals]).to eq(%w[handoff])
      expect(result[:facts]).to eq({})
    end

    it 'hands off on a mixed price+stock intent set without touching any repository' do
      expect(family_repository).not_to receive(:resolve_exact)
      expect(variant_resolver).not_to receive(:resolve)
      expect(price_repository).not_to receive(:price_for)
      expect(stock_repository).not_to receive(:status_for)
      result = call(intents: %w[price stock])
      expect(result[:response_goals]).to eq(%w[handoff])
      expect(result[:facts]).to eq({})
    end

    it 'hands off on a duplicated price set (exact-canonical-array policy)' do
      expect(price_repository).not_to receive(:price_for)
      result = call(intents: %w[price price])
      expect(result[:response_goals]).to eq(%w[handoff])
    end

    it 'hands off (never answers) a supported-but-unauthorized product_overview intent without a repository read' do
      expect(family_repository).not_to receive(:resolve_exact)
      result = planner.call(product_intent: product_intent(family_mention: 'Santorini', explicit_child_code: nil),
                            intents: %w[product_overview], scenario: { key: 'scenario_8' })
      expect(result[:response_goals]).to eq(%w[handoff])
      expect(result[:facts]).to eq({})
    end
  end

  describe 'price' do
    before do
      allow(price_repository).to receive(:price_for).with('BD-4').and_return(status: :available, price_list_rate: '12500', currency: 'IDR',
                                                                             uom: 'Yard')
    end

    it 'produces the exact canonical + immutable display price fact' do
      result = call(intents: %w[price])

      expect(result[:response_goals]).to eq(%w[answer_price])
      expect(result[:facts][:price]).to eq(
        canonical: { variant_code: 'BD-4', currency: 'IDR', price_list_rate: '12500', uom: 'Yard' },
        display: { product: 'BD-4', currency: 'Rp', amount: '12.500', uom: 'yard' },
        policy_version: 'price-display-v1', source: 'catalog_price_repository', checked_at: checked_at
      )
      expect(result[:validated_slots][:variant][:code]).to eq('BD-4')
      expect(result[:scenario]).to eq(key: 'scenario_8')
    end

    it 'hands off (no price fact) when the price is unavailable' do
      allow(price_repository).to receive(:price_for).with('BD-4').and_return(status: :unavailable)
      result = call(intents: %w[price])

      expect(result[:facts]).not_to have_key(:price)
      expect(result[:response_goals]).to include('handoff')
    end
  end

  describe 'stock (Phase 5 — binary availability only)' do
    it 'produces a binary available fact over the exact resolved variant (never a quantity)' do
      allow(stock_repository).to receive(:status_for).with('BD-4').and_return(:available)
      result = call(intents: %w[stock])

      expect(result[:response_goals]).to eq(%w[answer_stock])
      expect(result[:facts][:stock]).to eq(status: 'available', source: 'stock_repository', checked_at: checked_at)
      expect(result[:validated_slots][:variant][:code]).to eq('BD-4')
      # No numeric inventory ever enters the fact.
      expect(result[:facts][:stock].keys).to contain_exactly(:status, :source, :checked_at)
    end

    it 'produces a binary unavailable fact for an empty variant' do
      allow(stock_repository).to receive(:status_for).with('BD-4').and_return(:empty)
      expect(call(intents: %w[stock])[:facts][:stock][:status]).to eq('unavailable')
    end

    it 'clarifies the variant when stock is asked with only a family (no exact child)' do
      allow(variant_resolver).to receive(:resolve).and_return(status: :unresolved, reason: :missing)
      result = call(intents: %w[stock], intent_overrides: { explicit_child_code: nil })
      expect(result[:response_goals]).to eq(%w[clarify_variant])
      expect(result[:facts]).to eq({})
    end

    it 'hands off (no stock fact) on a stock repository outage' do
      allow(stock_repository).to receive(:status_for).with('BD-4').and_raise(catalog_error)
      result = call(intents: %w[stock])
      expect(result[:response_goals]).to eq(%w[handoff])
      expect(result[:facts]).to eq({})
    end
  end

  describe 'price_range (Phase 5 — family-level selling-price range)' do
    let(:range_authority) { instance_double(Marine::Backend::FamilyPriceRangeAuthority) }
    let(:range_planner) do
      described_class.new(
        family_repository: family_repository, variant_resolver: variant_resolver,
        price_repository: price_repository, stock_repository: stock_repository,
        price_formatter: Marine::Catalog::PriceDisplayFormatter.new, range_authority: range_authority, clock: clock
      )
    end
    # The authority Result carries its OWN source + checked_at; the planner must carry both VERBATIM
    # into the fact (never re-stamp a literal source or its own clock). The default checked_at is a
    # valid UTC instant DISTINCT from the planner clock (`checked_at`), so a carried timestamp is
    # provably the authority's and not the planner's.
    let(:authority_source) { Marine::Backend::FamilyPriceRangeAuthority::SOURCE }
    let(:authority_checked_at) { '2026-09-29T08:30:00Z' }

    def range_call(mention: 'Santorini')
      range_planner.call(product_intent: { customer_language: 'id', family_mention: mention, explicit_child_code: nil, attribute_candidates: [] },
                         intents: %w[price_range], scenario: { key: 'scenario_8' })
    end

    def range_result(min:, max:, source: authority_source, checked_at: authority_checked_at)
      Marine::Backend::FamilyPriceRangeAuthority::Result.new(
        status: :available, min: min, max: max, currency: 'IDR', uom: 'Yard', source: source, checked_at: checked_at
      ).freeze
    end

    it 'emits an answer_price_range fact with canonical + formatter-reconstructed display endpoints, no variant resolution' do
      expect(variant_resolver).not_to receive(:resolve)
      allow(range_authority).to receive(:call).with(family_code: 'BD').and_return(range_result(min: '10000', max: '12500'))

      result = range_call

      expect(result[:response_goals]).to eq(%w[answer_price_range])
      expect(result[:validated_slots][:variant]).to be_nil
      expect(result[:validated_slots][:product][:code]).to eq('BD')
      expect(result[:facts][:price_range]).to eq(
        canonical: { family_code: 'BD', currency: 'IDR', min: '10000', max: '12500', uom: 'Yard' },
        display: { currency: 'Rp', min: '10.000', max: '12.500', uom: 'yard' },
        policy_version: 'price-display-v1', source: authority_source, checked_at: authority_checked_at
      )
    end

    it 'carries the authority Result source + checked_at verbatim (never re-stamps a literal source or the planner clock)' do
      allow(range_authority).to receive(:call).and_return(range_result(min: '10000', max: '12500'))

      fact = range_call[:facts][:price_range]
      expect(fact[:source]).to eq(authority_source)
      # The authority's checked_at is preserved — NOT the planner clock (`checked_at`).
      expect(fact[:checked_at]).to eq(authority_checked_at)
      expect(fact[:checked_at]).not_to eq(checked_at)
    end

    it 'carries a forged authority source/timestamp through unchanged, and EvidencePacketBuilder rejects each (fail-closed backstop)' do
      invalid_error = Marine::Backend::EvidencePacketBuilder::InvalidEvidenceInputError

      allow(range_authority).to receive(:call).and_return(range_result(min: '10000', max: '12500', source: 'forged_source'))
      forged_source_input = range_call
      expect(forged_source_input[:facts][:price_range][:source]).to eq('forged_source')
      expect { Marine::Backend::EvidencePacketBuilder.new(clock: clock).build(evidence_input: forged_source_input) }
        .to raise_error(invalid_error)

      allow(range_authority).to receive(:call).and_return(range_result(min: '10000', max: '12500', checked_at: '2026-09-29 08:30:00'))
      forged_ts_input = range_call
      expect(forged_ts_input[:facts][:price_range][:checked_at]).to eq('2026-09-29 08:30:00')
      expect { Marine::Backend::EvidencePacketBuilder.new(clock: clock).build(evidence_input: forged_ts_input) }
        .to raise_error(invalid_error)
    end

    it 'keeps equal endpoints exact and coherent (min == max)' do
      allow(range_authority).to receive(:call).and_return(range_result(min: '12500', max: '12500'))
      display = range_call[:facts][:price_range][:display]
      expect(display[:min]).to eq('12.500')
      expect(display[:max]).to eq('12.500')
    end

    it 'clarifies the product when no exact family matches (never a guessed range)' do
      allow(family_repository).to receive(:resolve_exact).with('Ghost').and_return(nil)
      expect(range_authority).not_to receive(:call)
      result = range_call(mention: 'Ghost')
      expect(result[:response_goals]).to eq(%w[clarify_product])
      expect(result[:facts]).to eq({})
    end

    it 'hands off (no range fact) when the authoritative range is unavailable' do
      allow(range_authority).to receive(:call).and_return(Marine::Backend::FamilyPriceRangeAuthority::Result.new(status: :range_unavailable).freeze)
      result = range_call
      expect(result[:response_goals]).to eq(%w[handoff])
      expect(result[:facts]).to eq({})
    end

    it 'produces an evidence input the EvidencePacketBuilder accepts end-to-end' do
      allow(range_authority).to receive(:call).and_return(range_result(min: '10000', max: '12500'))
      input = range_call
      packet = Marine::Backend::EvidencePacketBuilder.new(clock: clock).build(evidence_input: input)
      expect(packet[:response_goals]).to eq(%w[answer_price_range])
      expect(packet[:facts][:price_range][:display]).to eq(currency: 'Rp', min: '10.000', max: '12.500', uom: 'yard')
      # The authority provenance rides through the builder's closed validation unchanged.
      expect(packet[:facts][:price_range][:checked_at]).to eq(authority_checked_at)
    end

    # Checkpoint A — a threaded presentation_policy is embedded in the price_range evidence input (and the
    # builder emits v3 end-to-end); the planner itself neither projects nor reads the assistant/DB.
    it 'embeds a threaded presentation_policy in the price_range evidence input and builds v3 end-to-end' do
      policy = { tone: 'professional', verbosity: 'concise', range_followup_mode: 'ask_variant_code' }
      allow(range_authority).to receive(:call).with(family_code: 'BD').and_return(range_result(min: '10000', max: '12500'))

      product_intent = { customer_language: 'id', family_mention: 'Santorini', explicit_child_code: nil, attribute_candidates: [] }
      input = range_planner.call(product_intent: product_intent, intents: %w[price_range],
                                 scenario: { key: 'scenario_8' }, presentation_policy: policy)

      expect(input[:presentation_policy]).to eq(policy)
      packet = Marine::Backend::EvidencePacketBuilder.new(clock: clock).build(evidence_input: input)
      expect(packet[:evidence_version]).to eq('marine_evidence_v3')
      expect(packet[:presentation_policy]).to eq(policy)
    end
  end

  describe 'exact-code-only variant authority (3A-1)' do
    it 'passes NO attribute candidates to the resolver even when the input carries them' do
      expect(variant_resolver).to receive(:resolve)
        .with(family_code: 'BD', explicit_child_code: 'BD-4', attribute_candidates: [])
        .and_return(status: :resolved, code: 'BD-4')
      allow(price_repository).to receive(:price_for).with('BD-4').and_return(status: :available, price_list_rate: '12500', currency: 'IDR',
                                                                             uom: 'Yard')

      call(intents: %w[price], intent_overrides: { attribute_candidates: %w[Blue] })
    end

    it 'clarifies (never resolves) when only an attribute candidate is present and no exact code' do
      allow(variant_resolver).to receive(:resolve)
        .with(family_code: 'BD', explicit_child_code: nil, attribute_candidates: [])
        .and_return(status: :unresolved, reason: :missing)
      result = call(intents: %w[price],
                    intent_overrides: { explicit_child_code: nil, attribute_candidates: %w[Blue] })

      expect(result[:response_goals]).to eq(%w[clarify_variant])
    end
  end

  describe 'unresolved / ambiguous slots (never guessed)' do
    it 'clarifies the product when no exact family matches' do
      allow(family_repository).to receive(:resolve_exact).with('Ghost').and_return(nil)
      result = call(intents: %w[price], intent_overrides: { family_mention: 'Ghost' })

      expect(result[:response_goals]).to eq(%w[clarify_product])
      expect(result[:missing_slots]).to eq(%w[product])
      expect(result[:facts]).to eq({})
    end

    it 'clarifies an ambiguous variant' do
      allow(variant_resolver).to receive(:resolve).and_return(status: :unresolved, reason: :ambiguous)
      result = call(intents: %w[price])

      expect(result[:response_goals]).to eq(%w[clarify_ambiguous_variant])
      expect(result[:missing_slots]).to eq(%w[variant_input])
    end

    it 'clarifies a missing variant' do
      allow(variant_resolver).to receive(:resolve).and_return(status: :unresolved, reason: :missing)
      result = call(intents: %w[price])
      expect(result[:response_goals]).to eq(%w[clarify_variant])
    end
  end

  describe 'defense in depth on a direct call' do
    it 'hands off (never raises) when product_intent is not a Hash' do
      result = planner.call(product_intent: nil, intents: %w[price], scenario: { key: 'scenario_8' })
      expect(result[:response_goals]).to eq(%w[handoff])
      expect(result[:facts]).to eq({})
    end
  end

  describe 'catalog outage' do
    it 'hands off on a family repository outage' do
      allow(family_repository).to receive(:resolve_exact).with('Santorini').and_raise(catalog_error)
      result = call(intents: %w[price])
      expect(result[:response_goals]).to eq(%w[handoff])
      expect(result[:facts]).to eq({})
    end
  end

  it 'returns a deeply frozen evidence input' do
    allow(price_repository).to receive(:price_for).and_return(status: :available, price_list_rate: '12500', currency: 'IDR', uom: 'Yard')
    result = call(intents: %w[price])
    expect(result).to be_frozen
    expect(result[:facts][:price]).to be_frozen
  end

  describe 'product_listing / product_information (Phase 3 bounded catalog)' do
    let(:listing_repository) { instance_double(Marine::Catalog::ProductListingRepository) }
    let(:description_source) { ->(_products) { {} } }
    let(:listing_result) do
      { products: [{ code: 'AAA', name: 'Alpha' }, { code: 'BBB', name: 'Bravo' }],
        returned_count: 2, total_count: 2, complete: true, has_more: false }
    end
    let(:listing_planner) do
      described_class.new(
        family_repository: family_repository, variant_resolver: variant_resolver,
        price_repository: price_repository, stock_repository: stock_repository,
        price_formatter: Marine::Catalog::PriceDisplayFormatter.new,
        listing_repository: listing_repository, description_source: description_source, clock: clock
      )
    end

    before { allow(listing_repository).to receive(:active_top_level).and_return(listing_result) }

    def listing_call(intents:)
      listing_planner.call(product_intent: { customer_language: 'id' }, intents: intents, scenario: { key: 'scenario_9' })
    end

    it 'builds a names-only listing input without resolving any family/variant' do
      expect(family_repository).not_to receive(:resolve_exact)
      expect(variant_resolver).not_to receive(:resolve)
      result = listing_call(intents: %w[product_listing])

      expect(result[:response_goals]).to eq(%w[answer_product_listing])
      expect(result[:validated_slots]).to eq({})
      listing = result[:facts][:product_listing]
      expect(listing[:products]).to eq([{ code: 'AAA', name: 'Alpha' }, { code: 'BBB', name: 'Bravo' }])
      expect(listing[:returned_count]).to eq(2)
      expect(listing[:total_count]).to eq(2)
      expect(listing[:complete]).to be(true)
      expect(listing[:source]).to eq('catalog_listing_repository')
    end

    context 'with product_information and a wired description source' do
      # The batch source receives the whole authorized page and returns a { code => description } map
      # for ONLY the codes it exactly bound — it can never add a product.
      let(:description_source) { ->(products) { products.any? { |p| p[:code] == 'AAA' } ? { 'AAA' => 'Soft cotton' } : {} } }

      it 'filters a mixed broad page to the described subset, recomputing counts (complete=false)' do
        result = listing_call(intents: %w[product_information])
        expect(result[:response_goals]).to eq(%w[answer_product_information])
        listing = result[:facts][:product_listing]
        # Only AAA bound a description; BBB (undescribed) is dropped — never emitted description-less.
        expect(listing[:products]).to eq([{ code: 'AAA', name: 'Alpha', description: 'Soft cotton' }])
        expect(listing[:returned_count]).to eq(1)
        # total_count stays the Catalog-authoritative top-level total; a filtered page is not complete.
        expect(listing[:total_count]).to eq(2)
        expect(listing[:complete]).to be(false)
      end
    end

    context 'with product_information when no description binds (broad)' do
      let(:description_source) { ->(_products) { {} } }

      it 'hands off (factless) rather than emit a names-only or undescribed information page' do
        result = listing_call(intents: %w[product_information])
        expect(result[:response_goals]).to eq(%w[handoff])
        expect(result[:facts]).to eq({})
      end
    end

    context 'with product_information when the description source returns an off-page code' do
      # A code the authorized page never listed is ignored — a product is never introduced from RAG.
      let(:description_source) { ->(_products) { { 'AAA' => 'Soft cotton', 'ZZZ' => 'ghost off-page' } } }

      it 'emits only on-page described products and never the off-page code' do
        listing = listing_call(intents: %w[product_information])[:facts][:product_listing]
        expect(listing[:products]).to eq([{ code: 'AAA', name: 'Alpha', description: 'Soft cotton' }])
        expect(listing[:products].map { |p| p[:code] }).not_to include('ZZZ')
      end
    end

    context 'with product_information for a specific exact product' do
      def info_mention_call(mention:)
        listing_planner.call(product_intent: { customer_language: 'id', family_mention: mention },
                             intents: %w[product_information], scenario: { key: 'scenario_9' })
      end

      before { allow(listing_repository).to receive(:exact_top_level).with('Alpha').and_return(code: 'AAA', name: 'Alpha') }

      context 'when its RAG description exists' do
        let(:description_source) { ->(_products) { { 'AAA' => 'Soft cotton' } } }

        it 'emits one complete described product (returned_count=total_count=1, complete=true)' do
          listing = info_mention_call(mention: 'Alpha')[:facts][:product_listing]
          expect(listing[:products]).to eq([{ code: 'AAA', name: 'Alpha', description: 'Soft cotton' }])
          expect(listing[:returned_count]).to eq(1)
          expect(listing[:total_count]).to eq(1)
          expect(listing[:complete]).to be(true)
        end
      end

      context 'with no RAG description' do
        let(:description_source) { ->(_products) { {} } }

        it 'hands off (never an undescribed specific product)' do
          result = info_mention_call(mention: 'Alpha')
          expect(result[:response_goals]).to eq(%w[handoff])
          expect(result[:facts]).to eq({})
        end
      end
    end

    context 'when Model 1 supplies a product candidate (Section D)' do
      def mention_call(intents:, mention:)
        listing_planner.call(product_intent: { customer_language: 'id', family_mention: mention },
                             intents: intents, scenario: { key: 'scenario_9' })
      end

      it 'exact-resolves the candidate against top-level authority and restricts the page to it' do
        allow(listing_repository).to receive(:exact_top_level).with('Alpha').and_return(code: 'AAA', name: 'Alpha')
        expect(listing_repository).not_to receive(:active_top_level)
        listing = mention_call(intents: %w[product_listing], mention: 'Alpha')[:facts][:product_listing]
        expect(listing[:products]).to eq([{ code: 'AAA', name: 'Alpha' }])
        expect(listing[:returned_count]).to eq(1)
        expect(listing[:total_count]).to eq(1)
        expect(listing[:complete]).to be(true)
      end

      it 'hands off (never shows the product as available) when the candidate has no exact top-level match' do
        allow(listing_repository).to receive(:exact_top_level).with('Ghost').and_return(nil)
        result = mention_call(intents: %w[product_information], mention: 'Ghost')
        expect(result[:response_goals]).to eq(%w[handoff])
        expect(result[:facts]).to eq({})
      end

      it 'hands off on a catalog outage while resolving the candidate' do
        allow(listing_repository).to receive(:exact_top_level).and_raise(catalog_error)
        expect(mention_call(intents: %w[product_listing], mention: 'Alpha')[:response_goals]).to eq(%w[handoff])
      end
    end

    it 'carries not-complete metadata through (complete=false, total_count>returned)' do
      allow(listing_repository).to receive(:active_top_level)
        .and_return(products: [{ code: 'AAA', name: 'Alpha' }], returned_count: 1, total_count: 9, complete: false, has_more: true)
      listing = listing_call(intents: %w[product_listing])[:facts][:product_listing]
      expect(listing[:complete]).to be(false)
      expect(listing[:total_count]).to eq(9)
    end

    it 'maps the repository has_more directly into Evidence completeness (complete == !has_more)' do
      allow(listing_repository).to receive(:active_top_level)
        .and_return(products: [{ code: 'AAA', name: 'Alpha' }, { code: 'BBB', name: 'Bravo' }],
                    returned_count: 2, total_count: 2, complete: true, has_more: false)
      listing = listing_call(intents: %w[product_listing])[:facts][:product_listing]
      expect(listing[:complete]).to be(true)
    end

    it 'hands off (factless) on an empty catalog or a catalog outage' do
      allow(listing_repository).to receive(:active_top_level)
        .and_return(products: [], returned_count: 0, total_count: 0, complete: true, has_more: false)
      expect(listing_call(intents: %w[product_listing])[:response_goals]).to eq(%w[handoff])
      allow(listing_repository).to receive(:active_top_level).and_raise(catalog_error)
      result = listing_call(intents: %w[product_information])
      expect(result[:response_goals]).to eq(%w[handoff])
      expect(result[:facts]).to eq({})
    end

    it 'produces an evidence input the EvidencePacketBuilder accepts end-to-end' do
      input = listing_call(intents: %w[product_listing])
      packet = Marine::Backend::EvidencePacketBuilder.new(clock: clock).build(evidence_input: input)
      expect(packet[:facts][:product_listing][:products].map { |product| product[:code] }).to eq(%w[AAA BBB])
      expect(packet[:response_goals]).to eq(%w[answer_product_listing])
    end
  end
end
