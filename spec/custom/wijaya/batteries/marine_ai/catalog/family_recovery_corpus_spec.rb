# frozen_string_literal: true

require 'rails_helper'

# Conversation 102 regression — family resolution over a REALISTIC catalog corpus.
#
# The prior orchestrator specs mock ProductFamilyRepository so #active_candidates returns a
# fixed list regardless of the query/limit arguments, so neither of these real behaviors was
# ever represented:
#   * the recovery scorer only scanned the first RECOVERY_FAMILY_LIMIT active families ordered
#     by item_code, silently ignoring any family beyond that prefix; and
#   * a BLANK clarify identifier fell through to #active_candidates(query: ''), which the
#     repository treats as "no filter" and returns an arbitrary item_code-ordered slice of the
#     WHOLE catalog as if those were relevant examples.
#
# These examples use a FAITHFUL fake repository (real ILIKE-contains + item_code ordering +
# limit clamping over a synthetic corpus of UNRELATED families) so both behaviors are exercised
# exactly as production would. No product/family/code/phrase from the real catalog appears here.
RSpec.describe Marine::Catalog::ProductQueryOrchestrator, 'family recovery over a realistic corpus' do
  # A faithful, read-only stand-in for ProductFamilyRepository: exact resolution (unique code or
  # case-insensitive exact name), plus a bounded case-insensitive CONTAINS search ordered by
  # item_code with the same [1, 50] limit clamp as the real repository. A blank query matches all
  # rows (the real "no filter" semantics). Every row is an active template.
  class FaithfulFamilyRepository
    MAX_LIMIT = 50

    def initialize(rows)
      @rows = rows
    end

    def resolve_exact(identifier)
      value = identifier.to_s.strip
      return nil if value.empty?

      matches = @rows.select { |r| r[:code] == value || r[:name].downcase == value.downcase }
      matches.length == 1 ? matches.first : nil
    end

    def active_candidates(query: nil, limit: 20)
      needle = query.to_s.strip.downcase
      matched = needle.empty? ? @rows : @rows.select { |r| r[:code].downcase.include?(needle) || r[:name].downcase.include?(needle) }
      matched.sort_by { |r| r[:code] }.first(clamp(limit))
    end

    private

    def clamp(limit)
      value = limit.to_i
      value <= 0 ? 20 : [value, MAX_LIMIT].min
    end
  end

  subject(:orchestrator) do
    described_class.new(
      repositories: { family: family_repository, variant: variant_repository, price: price_repository, stock: stock_repository }
    )
  end

  let(:variant_repository) { instance_double(Marine::Catalog::VariantRepository) }
  let(:price_repository) { instance_double(Marine::Catalog::PriceRepository) }
  let(:stock_repository) { instance_double(Marine::Catalog::StockRepository) }

  # 55 UNRELATED filler families whose codes all sort before the target ("F01".."F55") and whose
  # names share no token with the probes below, so the target sits FAR beyond the first-50
  # item_code prefix the old recovery scan was bounded to.
  let(:fillers) { (1..55).map { |n| { code: format('F%02d', n), name: "Widget #{n}" } } }

  def intent(overrides = {})
    {
      product_related: true, intent: 'catalog', family_mention: nil,
      explicit_child_code: nil, attribute_candidates: [], requires_exact_variant: false,
      clarification_reply: nil, family_changed: false, intent_changed: false,
      multiple_numeric_candidates: false, confidence: 'high', reason: 'extracted'
    }.merge(overrides)
  end

  describe 'a noisy mention of a family beyond the first-50 item_code prefix (Failure 1)' do
    # The target family sorts LAST by item_code, so it is outside the old RECOVERY_FAMILY_LIMIT
    # prefix scan; the customer names it with a generic leading word ("cloth"), so exact and
    # contains resolution both miss and only the token-driven recovery can reach it.
    let(:family_repository) do
      FaithfulFamilyRepository.new(fillers + [{ code: 'ZZ', name: 'Zephyr' }])
    end

    it 'recovers the UNIQUE matching family from the raw turn and sends its catalog' do
      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'catalog', family_mention: 'cloth zephyr'),
        flow: nil, text: 'please send me the cloth zephyr catalog'
      )

      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'ZZ', family_name: 'Zephyr')
      expect(plan[:state][:changes]).to include('validated_family' => 'ZZ', 'current_intent' => 'catalog')
    end
  end

  describe 'genuine ambiguity beyond the prefix still fails closed' do
    # Two families beyond the prefix both carry the mentioned token — real ambiguity.
    let(:family_repository) do
      FaithfulFamilyRepository.new(fillers + [{ code: 'ZZ', name: 'Zephyr Marine' }, { code: 'ZY', name: 'Zephyr Coastal' }])
    end

    it 'clarifies (never a catalog) and surfaces the actual competing families as candidates' do
      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'catalog', family_mention: 'cloth zephyr'),
        flow: nil, text: 'please send me the cloth zephyr catalog'
      )

      expect(plan[:action]).to eq(:clarify_family)
      expect(plan[:reply][:candidates].map { |c| c[:code] }).to contain_exactly('ZZ', 'ZY')
    end
  end

  describe 'a generic catalog request with no family signal (Failure 2)' do
    # No turn token matches any family, so there is no relevant example to offer.
    let(:family_repository) { FaithfulFamilyRepository.new(fillers) }

    it 'clarifies WITHOUT dumping an arbitrary slice of the whole catalog as examples' do
      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'catalog', family_mention: nil),
        flow: nil, text: 'please show me your other catalogs'
      )

      expect(plan[:action]).to eq(:clarify_family)
      expect(plan[:reply][:candidates]).to be_empty
    end
  end

  describe 'a generic request whose ordinary word coincidentally matches ONE family (exact transcript shape, Failure 3)' do
    # The exact reported runtime shape the sanitized Failure-2 phrase missed: the extractor
    # supplies NO family mention, and the generic utterance happens to contain an everyday word
    # ("everyday") that is ALSO the distinctive word of exactly one family's name. That single
    # coincidental token used to score as a unique top match and auto-select the family from a
    # request that named nothing. Trusting the extractor's blank mention, the turn must fail
    # closed to a generic, example-free clarification — never a catalog, never that family.
    let(:family_repository) do
      FaithfulFamilyRepository.new(fillers + [{ code: 'EV', name: 'Everyday Series' }])
    end

    it 'never selects the coincidental family and clarifies without examples' do
      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'catalog', family_mention: nil),
        flow: nil, text: 'do you sell anything for everyday use'
      )

      expect(plan[:action]).to eq(:clarify_family)
      expect(plan[:reply][:candidates]).to be_empty
    end
  end

  describe 'an explicit multi-word family mention still resolves (contiguous identity)' do
    # Requirement 1/5: when the extractor DOES supply the family reference — the full multi-word
    # name plus a trailing generic word — exact resolution misses (the trailing word defeats an
    # ILIKE-contains match) but the contiguous identity in the MENTION is discriminative enough
    # to recover the family. (Prefix-position independence is proven by the ZZ example above.)
    let(:family_repository) do
      FaithfulFamilyRepository.new(fillers + [{ code: 'EV', name: 'Everyday Series' }])
    end

    it 'recovers the uniquely named family and sends its catalog' do
      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'catalog', family_mention: 'everyday series catalog'),
        flow: nil, text: 'please send the everyday series catalog'
      )

      expect(plan[:action]).to eq(:send_catalog)
      expect(plan[:reply]).to eq(kind: :catalog, family_code: 'EV', family_name: 'Everyday Series')
    end
  end
end
