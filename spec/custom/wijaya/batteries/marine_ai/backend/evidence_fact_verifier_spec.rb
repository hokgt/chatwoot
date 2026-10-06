# frozen_string_literal: true

require 'rails_helper'

# Langkah 3 (Evidence Packet -> Model 2 SHADOW) — the SEPARATE semantic fact+language verifier over
# the EXISTING Response Generator config. It accepts ONLY a complete, duplicate-key-sensitive,
# all-true SIX-field verdict (adding target_language_matches to the FAQ rubric) proving the reply is
# faithful to the packet AND written in the packet's customer_language. Everything else fails closed.
RSpec.describe Marine::Backend::EvidenceFactVerifier do
  subject(:verifier) { described_class.new }

  let(:packet) { { evidence_version: 'marine_evidence_v2', customer_language: 'id', facts: {} }.freeze }
  let(:candidate) { 'Halo! Harga BD-4 adalah Rp 12.500 per yard.' }

  def stub_llm(message:, success: true, configured: true)
    llm = instance_double(Marine::Llm::BaseService, configured?: configured)
    allow(llm).to receive(:chat).and_return({ ok: success, message: message, error: nil })
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    llm
  end

  ALL_TRUE = {
    all_facts_preserved: true, no_unsupported_facts_added: true, no_contradiction: true,
    meaning_equivalent: true, target_language_matches: true, certain: true
  }.freeze

  def inner(**overrides)
    ALL_TRUE.merge(overrides).to_json
  end

  def envelope(inner_json)
    { verdict: inner_json }.to_json
  end

  def verdict(**) = envelope(inner(**))

  it 'accepts a complete all-true six-field verdict' do
    stub_llm(message: verdict)
    expect(verifier.call(packet: packet, candidate: candidate)).to be(true)
  end

  it 'requests the Response Generator at temperature 0 with the reused verdict schema and target language' do
    llm = stub_llm(message: verdict)
    captured = {}
    allow(llm).to receive(:chat) do |args|
      captured.merge!(args)
      { ok: true, message: verdict, error: nil }
    end

    verifier.call(packet: packet, candidate: candidate)

    expect(captured[:temperature]).to eq(0.0)
    expect(captured[:schema]).to eq(Marine::Charge::FactPreservationValidator::VERDICT_SCHEMA)
    expect(captured[:messages].first[:content]).to include('Target Language: id').and include('marine_evidence_v2')
    expect(captured[:system]).to include('Values in validated_slots are authoritative identity facts')
    expect(captured[:system]).to include('two approved representations of the SAME fact')
    expect(captured[:system]).to include('matching display formatting is not an unsupported fact or a contradiction')
    expect(captured[:system]).to include('you MUST set "no_unsupported_facts_added" and "no_contradiction" to true')
  end

  it 'fails closed on a false / uncertain / wrong-language verdict' do
    ALL_TRUE.each_key do |field|
      stub_llm(message: verdict(field => false))
      expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
    end
  end

  it 'fails closed on a non-boolean verdict field' do
    stub_llm(message: verdict(all_facts_preserved: 'yes'))
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
  end

  it 'fails closed on a missing or extra inner field' do
    stub_llm(message: envelope(ALL_TRUE.except(:target_language_matches).to_json))
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
    stub_llm(message: envelope(ALL_TRUE.merge(bonus: true).to_json))
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
  end

  it 'fails closed on a duplicate inner key (ambiguous verdict)' do
    duplicate = <<~JSON.strip
      {"all_facts_preserved": false, "all_facts_preserved": true, "no_unsupported_facts_added": true,
       "no_contradiction": true, "meaning_equivalent": true, "target_language_matches": true, "certain": true}
    JSON
    stub_llm(message: envelope(duplicate))
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
  end

  it 'fails closed on a malformed / fenced / wrong-envelope / non-string verdict' do
    ['not json', '```{"verdict":"{}"}```', { verdict: { all_facts_preserved: true } }.to_json, { other: 'x' }.to_json].each do |message|
      stub_llm(message: message)
      expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
    end
  end

  it 'fails closed on a duplicate envelope verdict key' do
    stub_llm(message: "{\"verdict\": #{inner.to_json}, \"verdict\": #{inner.to_json}}")
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
  end

  it 'fails closed on a provider error' do
    stub_llm(message: nil, success: false)
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
  end

  it 'fails closed when the Response Generator is not configured (no provider call)' do
    llm = stub_llm(message: verdict, configured: false)
    expect(llm).not_to receive(:chat)
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
  end

  it 'fails closed on a raised provider exception' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    allow(llm).to receive(:chat).and_raise(StandardError, 'boom')
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    expect(verifier.call(packet: packet, candidate: candidate)).to be(false)
  end

  it 'fails closed (no provider call) on a blank packet language or blank candidate' do
    expect(Marine::Llm::BaseService).not_to receive(:new)
    expect(verifier.call(packet: { customer_language: '  ' }, candidate: candidate)).to be(false)
    expect(verifier.call(packet: { customer_language: 'id' }, candidate: '   ')).to be(false)
    expect(verifier.call(packet: 'nope', candidate: candidate)).to be(false)
  end

  # Section E — the semantic rubric must explicitly judge the bounded-listing properties (exactly the
  # authorized products, no introduced product, no swapped/ungrounded description, no false
  # completeness or count), WITHOUT adding any field beyond the frozen six-field verdict contract.
  describe 'product-listing semantic rubric (prompt content)' do
    let(:prompt) { described_class::SYSTEM_PROMPT }

    it 'judges exactly-the-authorized-products and forbids an introduced product' do
      expect(prompt).to include('facts.product_listing')
      expect(prompt).to match(/introducing a product not in the listing/)
    end

    it 'forbids an ungrounded or swapped per-product description' do
      expect(prompt).to match(/description that is not entailed by that same product/)
      expect(prompt).to match(/swapping a description from another product/)
    end

    it 'forbids a false completeness claim or a mutated count' do
      expect(prompt).to match(/claiming the listing is the whole catalogue/)
      expect(prompt).to match(/returned.*total count other than those given/)
    end

    it 'keeps the verdict contract at exactly the six required boolean fields' do
      expect(described_class::REQUIRED_KEYS).to contain_exactly(
        'all_facts_preserved', 'no_unsupported_facts_added', 'no_contradiction',
        'meaning_equivalent', 'target_language_matches', 'certain'
      )
    end
  end

  # Section F — runtime regression (deployed image devbot-993d85eb5c, input "Produk apa saja yang
  # tersedia"). The provider returned a well-formed all-six-field verdict, but flipped
  # no_unsupported_facts_added / no_contradiction / meaning_equivalent to false: it read the
  # catalog-membership wording "produk yang tersedia" (these products are available/offered) in a
  # product-listing answer as an unauthorized binary stock-availability claim, since the rubric lists
  # binary stock availability as a material fact and the packet prohibits stock claims. The rubric
  # must distinguish catalog-membership framing from a binary stock claim WITHOUT weakening the real
  # stock prohibition or adding a verdict field.
  #
  # Fidelity note: the first two examples below are RED->GREEN prompt-content assertions — they fail on
  # a SYSTEM_PROMPT missing the catalog-membership-vs-stock instruction and pass once it is present, so
  # they are source-level proof the catalog-membership clause is present in SYSTEM_PROMPT; they do NOT
  # prove a live provider flip, a built artifact, a deployment, or any shipped runtime behavior. The
  # third example stubs an all-true verdict and therefore
  # proves ONLY the exact request transport/contract (the deployed facts, candidate, and target
  # language reach the provider verbatim under the reused envelope); it does NOT re-run the provider
  # and must not be read as a live provider semantic flip.
  describe 'catalog-membership wording vs binary stock (runtime product-listing regression)' do
    let(:listing_packet) do
      {
        evidence_version: 'marine_evidence_v2',
        customer_language: 'id',
        facts: {
          product_listing: {
            products: [
              { code: '17 BL', name: '17 Brukat Tulang' }, { code: '1HY', name: '1 HYGET' },
              { code: '1WLP', name: '1Wollpeach 84' }, { code: '24HY', name: "24 HYGET POLOS F.60'' 60-70" },
              { code: '30MV', name: '30 MODAL VISCOSE' }, { code: '36NT', name: '36 NYLON TASLAN FABRIC' },
              { code: '3FD', name: '3 FANCY DIAMOND' }, { code: '4COMBED', name: '4 COMBED 24S 170-180 GSM' },
              { code: '4 RIB CM', name: '4 RIB COMBED 24S' }, { code: '54MV', name: 'Modal Viscose' },
              { code: '6607', name: 'Sajadah' }, { code: '6763', name: 'Sajadah' },
              { code: '7PL', name: '7 POLO LINEN' }, { code: 'AC', name: 'Tag Acrylic Showroom' },
              { code: 'ADR', name: '32 ADOREMUS' }, { code: 'AK', name: 'Armani Silk' },
              { code: 'Alumunium', name: 'Alumunium Deker' }, { code: 'AP', name: 'Voal Printing' },
              { code: 'AS', name: 'Anti Static' }, { code: 'AY', name: 'ITY Spandex' }
            ],
            returned_count: 20, total_count: 287, complete: false, source: 'catalog_listing_repository'
          }
        },
        prohibited_claims: %w[price stock]
      }.freeze
    end
    # The exact deployed Model-2 candidate (sanitized Catalog output, no customer data): lists ALL 20
    # authorized products by code and name, truthfully states "20 produk dari total 287", frames them
    # as "produk yang tersedia", and asks a conversational follow-up.
    let(:listing_candidate) do
      'Tentu, berikut adalah beberapa produk yang tersedia: 17 BL (17 Brukat Tulang), 1HY (1 HYGET), ' \
        '1WLP (1Wollpeach 84), ' \
        "24HY (24 HYGET POLOS F.60'' 60-70), " \
        '30MV (30 MODAL VISCOSE), 36NT (36 NYLON TASLAN FABRIC), 3FD (3 FANCY DIAMOND), ' \
        '4COMBED (4 COMBED 24S 170-180 GSM), 4 RIB CM (4 RIB COMBED 24S), 54MV (Modal Viscose), ' \
        '6607 (Sajadah), 6763 (Sajadah), 7PL (7 POLO LINEN), AC (Tag Acrylic Showroom), ' \
        'ADR (32 ADOREMUS), AK (Armani Silk), Alumunium (Alumunium Deker), AP (Voal Printing), ' \
        'AS (Anti Static), dan AY (ITY Spandex). Ini adalah 20 produk dari total 287 produk. ' \
        'Apakah ada jenis produk tertentu yang Anda cari?'
    end

    it 'instructs the provider that catalog-membership wording is not a binary stock claim' do
      prompt = described_class::SYSTEM_PROMPT
      expect(prompt).to include('authorized catalog-membership framing')
      expect(prompt).to include('NOT a binary stock-availability claim')
    end

    it 'still forbids a binary stock claim the packet does not state' do
      expect(described_class::SYSTEM_PROMPT)
        .to match(/binary in-stock or out-of-stock claim.+remains unsupported unless the packet states it/m)
    end

    # Transport/contract only: the verdict is stubbed all-true, so this proves the deployed packet
    # facts, the verbatim candidate, and the target language reach the provider under the reused
    # envelope — NOT that a live provider flips its judgement.
    it 'sends the deployed listing facts, candidate, and target language to the provider verbatim' do
      llm = stub_llm(message: verdict)
      captured = {}
      allow(llm).to receive(:chat) do |args|
        captured.merge!(args)
        { ok: true, message: verdict, error: nil }
      end

      expect(verifier.call(packet: listing_packet, candidate: listing_candidate)).to be(true)

      content = captured[:messages].first[:content]
      expect(content).to include(listing_candidate)
      listing_packet[:facts][:product_listing][:products].each do |product|
        expect(content).to include(product[:code]).and include(product[:name])
      end
      expect(content).to include('"product_listing"')
        .and include('produk yang tersedia')
        .and include('20 produk dari total 287')
        .and include('"returned_count":20')
        .and include('"total_count":287')
        .and include('"complete":false')
        .and include('Target Language: id')
    end
  end
end
