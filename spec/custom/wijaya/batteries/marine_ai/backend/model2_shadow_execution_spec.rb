# frozen_string_literal: true

require 'rails_helper'

# Langkah 3 (Evidence Packet -> Model 2 SHADOW) — the DEFAULT-OFF, NON-DELIVERING execution. It runs
# Model 2 ONLY for an accepted exact-price evidence packet, reusing the Phase 2A Authority Result; it
# returns a bounded closed status/reason (never the generated text) and makes ZERO provider calls for
# any non-accepted outcome / invalid packet / bad relationship. Generator + verifier are injected.
RSpec.describe Marine::Backend::Model2ShadowExecution do
  let(:account) { double('account', id: 1) }
  let(:assistant) { double('assistant', id: 3, account_id: 1) }
  let(:inbox) { double('inbox', present?: true, marine_assistant: assistant) }
  let(:conversation) { double('conversation', id: 5, account_id: 1, inbox: inbox) }
  let(:message) { double('message', id: 9, conversation_id: 5, incoming?: true, private?: false) }

  let(:context) { double('context', trigger: 'Berapa harga BD-4?', history: []) }
  let(:context_builder) { instance_double(Marine::Conversation::ContextBuilder, build: context) }

  let(:candidate) { 'Halo! Harga BD-4 adalah Rp 12.500 per yard.' }
  let(:generator) { double('generator') }
  let(:fact_verifier) { double('fact_verifier') }

  let(:packet) do
    Marine::Backend::EvidencePacketBuilder.new(clock: -> { Time.utc(2026, 9, 30, 12, 0, 0) }).build(
      evidence_input: {
        scenario: { key: 'scenario_5' },
        intents: %w[price], customer_language: 'id', response_goals: %w[answer_price],
        validated_slots: { variant: { code: 'BD-4', resolution_status: 'resolved', source: 'marine_catalog', attributes: {} } },
        facts: {
          price: {
            canonical: { variant_code: 'BD-4', currency: 'IDR', price_list_rate: '12500', uom: 'Yard' },
            display: { product: 'BD-4', currency: 'Rp', amount: '12.500', uom: 'yard' },
            policy_version: 'price-display-v1', source: 'catalog_price_repository', checked_at: '2026-09-30T12:00:00Z'
          }
        },
        missing_slots: [], variant_candidates: []
      }
    )
  end

  # A forged, deep-frozen marine_evidence_v2 packet the Coordinator NEVER produces in the price-only
  # slice (the EvidencePacketBuilder's whole-set ExecutionPolicy gate rejects a price+stock intents
  # set, so it is hand-built here): it carries an answer_stock goal and a :stock fact alongside price.
  # Used to prove a forged stock-bearing packet is rejected BEFORE any provider call.
  let(:price_stock_packet) do
    deep_freeze(
      evidence_version: 'marine_evidence_v2', generated_at: '2026-09-30T12:00:00Z',
      response_goals: %w[answer_price answer_stock], scenario: { key: 'scenario_5', intents: %w[price stock] },
      validated_slots: { variant: { code: 'BD-4', resolution_status: 'resolved', source: 'marine_catalog', attributes: {} } },
      facts: {
        price: {
          canonical: { variant_code: 'BD-4', currency: 'IDR', price_list_rate: '12500', uom: 'Yard' },
          display: { product: 'BD-4', currency: 'Rp', amount: '12.500', uom: 'yard' },
          policy_version: 'price-display-v1', source: 'catalog_price_repository', checked_at: '2026-09-30T12:00:00Z'
        },
        stock: { status: 'available', source: 'stock_repository', checked_at: '2026-09-30T12:00:00Z' }
      },
      missing_slots: [], variant_candidates: [],
      prohibited_claims: %w[exact_stock_quantity warehouse_location delivery_date unverified_discount],
      response_constraints: { max_paragraphs: 2, role: 'marine_sales_assistant', handoff_self_reference: true },
      customer_language: 'id'
    )
  end

  def deep_freeze(value)
    case value
    when Hash then value.each_value { |child| deep_freeze(child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end

  def authority_result(outcome_type: :evidence_packet, reason: :accepted, evidence_packet: packet, intents: %w[price])
    Marine::Backend::AuthorityCoordinator::Result.new(
      outcome_type: outcome_type, reason: reason, scenario_key: 'scenario_5',
      intents: intents.map(&:dup).map(&:freeze).freeze, source: :catalog, evidence_packet: evidence_packet
    ).freeze
  end

  def execution(result)
    described_class.new(
      account: account, assistant: assistant, conversation: conversation, message: message,
      authority_result: result, generator: generator, fact_verifier: fact_verifier, context_builder: context_builder
    )
  end

  describe 'accepted exact-price packet' do
    before do
      allow(generator).to receive(:call).and_return(candidate)
      allow(fact_verifier).to receive(:call).and_return(true)
    end

    it 'invokes the generator once and the separate verifier once, returning a text-free accepted result' do
      result = execution(authority_result).call

      expect(generator).to have_received(:call).once
      expect(fact_verifier).to have_received(:call).once
      expect(result.status).to eq(described_class::STATUS_ACCEPTED)
      expect(result.reason).to eq(described_class::REASON_DELIVERABLE_WORDING)
    end

    it 'returns ONLY a deep-frozen status/reason result and never retains the generated text' do
      result = execution(authority_result).call

      expect(result).to be_frozen
      expect(result.to_h.keys).to eq(%i[status reason])
      expect(result.respond_to?(:text)).to be(false)
      expect(result.to_h.values.map(&:to_s).join).not_to include(candidate)
    end

    it 'sends ONLY the clean marine_evidence_v2 packet facts to the prompt — no Candidate Plan / raw row / Model 1 prose' do
      captured = {}
      allow(generator).to receive(:call) do |system:, messages:|
        captured[:system] = system
        captured[:messages] = messages
        candidate
      end

      execution(authority_result).call

      expect(captured[:system]).to include('marine_evidence_v2').and include('BD-4').and include('12.500')
      %w[raw_candidate candidate_type slot_operations schema_version marine_decision_v1 SELECT].each do |forbidden|
        expect(captured[:system]).not_to include(forbidden)
      end
    end

    it 'makes the packet customer_language the authoritative requested language' do
      captured = {}
      allow(generator).to receive(:call) { |system:, **|
        captured[:system] = system
        candidate
      }

      execution(authority_result).call

      expect(captured[:system]).to include('Required target language (authoritative): id')
      expect(captured[:system]).not_to include('SAME language')
    end

    it 'rebuilds the bounded request/history from ContextBuilder' do
      allow(generator).to receive(:call) { |messages:, **|
        expect(messages.last[:content]).to eq('Berapa harga BD-4?')
        candidate
      }
      execution(authority_result).call
      expect(context_builder).to have_received(:build)
    end
  end

  describe 'fail-closed rejections (Model 2 ran, a gate fell closed)' do
    it 'rejects when the deterministic fact gate rejects the candidate (e.g. a fabricated price)' do
      allow(generator).to receive(:call).and_return('Harga BD-4 adalah Rp 99.999 per yard.')
      allow(fact_verifier).to receive(:call).and_return(true)

      result = execution(authority_result).call
      expect(result.status).to eq(described_class::STATUS_REJECTED)
      expect(fact_verifier).not_to have_received(:call) # deterministic gate runs before the verifier
    end

    it 'rejects when the separate semantic verifier rejects' do
      allow(generator).to receive(:call).and_return(candidate)
      allow(fact_verifier).to receive(:call).and_return(false)

      result = execution(authority_result).call
      expect(result.status).to eq(described_class::STATUS_REJECTED)
      expect(result.reason).to eq(:fact_unverified)
    end

    it 'rejects when the generator fails closed to nil' do
      allow(generator).to receive(:call).and_return(nil)

      result = execution(authority_result).call
      expect(result.status).to eq(described_class::STATUS_REJECTED)
      expect(result.reason).to eq(:generation_failed)
    end
  end

  describe 'zero Model 2 calls for a non-accepted outcome / invalid packet / bad relationship' do
    before do
      allow(generator).to receive(:call)
      allow(fact_verifier).to receive(:call)
    end

    def expect_skipped_no_providers(result, reason)
      outcome = execution(result).call
      expect(outcome.status).to eq(described_class::STATUS_SKIPPED)
      expect(outcome.reason).to eq(reason)
      expect(generator).not_to have_received(:call)
      expect(fact_verifier).not_to have_received(:call)
    end

    it 'skips a family_price_range outcome' do
      expect_skipped_no_providers(authority_result(outcome_type: :family_price_range, evidence_packet: nil), described_class::REASON_NOT_EXACT_PRICE)
    end

    it 'skips a handoff / clarify / stop / legacy_preserved outcome' do
      %i[handoff clarify stop legacy_preserved].each do |outcome_type|
        expect_skipped_no_providers(authority_result(outcome_type: outcome_type, reason: :price_unavailable, evidence_packet: nil),
                                    described_class::REASON_NOT_EXACT_PRICE)
      end
    end

    it 'skips an evidence_packet outcome whose reason is not accepted' do
      expect_skipped_no_providers(authority_result(reason: :price_unavailable), described_class::REASON_NOT_EXACT_PRICE)
    end

    it 'skips a non-Result authority value' do
      expect_skipped_no_providers({ outcome_type: :evidence_packet }, described_class::REASON_NOT_EXACT_PRICE)
    end

    it 'skips a non-frozen packet and a frozen wrong-version (v1 now rejected) packet' do
      expect_skipped_no_providers(authority_result(evidence_packet: { evidence_version: 'marine_evidence_v2' }),
                                  described_class::REASON_INVALID_PACKET)
      expect_skipped_no_providers(authority_result(evidence_packet: { evidence_version: 'marine_evidence_v1' }.freeze),
                                  described_class::REASON_INVALID_PACKET)
    end

    it 'skips a private message with zero providers and never builds context' do
      allow(message).to receive(:private?).and_return(true)
      outcome = execution(authority_result).call
      expect(outcome.status).to eq(described_class::STATUS_SKIPPED)
      expect(outcome.reason).to eq(described_class::REASON_RELATIONSHIP_INVALID)
      expect(context_builder).not_to have_received(:build)
      expect(generator).not_to have_received(:call)
    end

    it 'skips a mismatched linked assistant' do
      allow(inbox).to receive(:marine_assistant).and_return(double('other', id: 99))
      expect_skipped_no_providers(authority_result, described_class::REASON_RELATIONSHIP_INVALID)
    end

    it 'skips a Result whose intents are not EXACTLY price-only (e.g. price + stock), zero providers' do
      expect_skipped_no_providers(authority_result(intents: %w[price stock]), described_class::REASON_NOT_EXACT_PRICE)
    end

    it 'skips a forged stock-bearing accepted packet (answer_stock goal + stock fact), zero providers' do
      expect_skipped_no_providers(authority_result(evidence_packet: price_stock_packet), described_class::REASON_NOT_EXACT_PRICE)
    end
  end

  # Step 18 — the presenter now returns ok=true reason 'price_evidence_fallback' when it DISCARDED the
  # Model 2 candidate and rendered deterministic price Evidence instead. That is NOT accepted Model 2
  # wording — the candidate was rejected at its originating gate (carried in the result detail) — so the
  # shadow must observe it as a :rejected outcome keyed on that originating gate, never as accepted.
  describe 'exact-price deterministic fallback is observed as the originating gate rejection (Step 18)' do
    let(:fallback_presenter) { double('presenter') }

    def execution_with_presenter(result)
      described_class.new(
        account: account, assistant: assistant, conversation: conversation, message: message,
        authority_result: result, presenter: fallback_presenter,
        generator: generator, fact_verifier: fact_verifier, context_builder: context_builder
      )
    end

    it 'maps each price_evidence_fallback origin back to its gate as a rejection (not accepted wording)' do
      {
        generation_failed: :generation_failed, fact_rejected: :fact_rejected,
        persona_rejected: :persona_rejected, fact_unverified: :fact_unverified
      }.each do |origin, expected_reason|
        allow(fallback_presenter).to receive(:call).and_return(
          Marine::Backend::EvidencePacketPresenter::Result.new(
            ok: true, text: 'Harga BD-4 adalah Rp 12.500 per yard.',
            reason: described_class::PRICE_EVIDENCE_FALLBACK, detail: origin, fallback: nil
          ).freeze
        )

        result = execution_with_presenter(authority_result).call

        expect(result.status).to eq(described_class::STATUS_REJECTED)
        expect(result.reason).to eq(expected_reason)
      end
    end
  end

  # BLOCKER: the DEFAULT generator/verifier must be built WITHOUT an account so a provider exception
  # inside Marine::Llm::BaseService#chat can never construct a ChatwootExceptionTracker (its #capture
  # is a no-op when account is nil) — honoring Step 3's no-log/no-track/no-publish contract. These
  # exercise the REAL default adapters; only the network/provider call itself is stubbed.
  describe 'default collaborators honor the silent no-track / no-log contract' do
    def execution_with_defaults(result = authority_result)
      described_class.new(
        account: account, assistant: assistant, conversation: conversation, message: message,
        authority_result: result, context_builder: context_builder
      )
    end

    it 'builds the default generator and verifier with account: nil' do
      execution = execution_with_defaults
      generator = execution.instance_variable_get(:@generator)
      verifier = execution.instance_variable_get(:@fact_verifier)

      expect(generator).to be_a(Marine::Backend::EvidenceReplyGenerator)
      expect(verifier).to be_a(Marine::Backend::EvidenceFactVerifier)
      expect(generator.instance_variable_get(:@account)).to be_nil
      expect(verifier.instance_variable_get(:@account)).to be_nil
    end

    it 'a provider failure on the real default generator path constructs no ChatwootExceptionTracker and logs nothing' do
      allow(Marine::Llm::Config).to receive(:configured?).and_return(true)
      allow_any_instance_of(Marine::Llm::BaseService).to receive(:run_chat).and_raise(StandardError.new('boom-secret-provider-text'))
      allow(Rails.logger).to receive(:error)

      expect(ChatwootExceptionTracker).not_to receive(:new)

      result = execution_with_defaults.call

      expect(Rails.logger).not_to have_received(:error)
      expect(result.status).to eq(described_class::STATUS_REJECTED)
      expect(result.reason).to eq(:generation_failed)
    end
  end
end
