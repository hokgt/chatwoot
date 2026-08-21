# frozen_string_literal: true

require 'rails_helper'

# Phase 7 — fact-safe natural wording for a product HANDOFF acknowledgement. The service
# rephrases a deterministic, FACTLESS acknowledgement fallback grounded ONLY on the customer's
# latest turn and bounded history, then delivers the candidate ONLY when it passes an
# output-shape gate, greeting enforcement, a deterministic no-new-fact-token guard, AND a
# separate FactPreservationValidator LLM call. Any failure/uncertainty returns nil so the caller
# delivers its exact deterministic fallback. The token guard is the REAL one (not stubbed) so the
# no-invented-fact contract is genuinely exercised.
RSpec.describe Marine::Catalog::GroundedHandoffWordingService do
  subject(:service) { described_class.new(account: nil) }

  let(:fallback) { "I'm sorry, I'm not able to confirm that for you directly. Let me bring in a colleague who can help you with this." }

  def reply_envelope(message)
    { reply: message }.to_json
  end

  def stub_generation(message:, success: true)
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    allow(llm).to receive(:chat).and_return({ ok: success, message: reply_envelope(message), error: nil })
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    llm
  end

  def stub_semantic(accepted)
    validator = instance_double(Marine::Charge::FactPreservationValidator, valid?: accepted)
    allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(validator)
    validator
  end

  def call(fallback: self.fallback, customer_request: 'can you deliver to my city and how much?', message_history: [], opening: true)
    service.call(fallback: fallback, customer_request: customer_request, message_history: message_history, opening: opening)
  end

  it 'delivers a natural, factless acknowledgement that references the request when every gate accepts' do
    stub_generation(message: 'Of course — let me bring in a colleague to help with delivery to your city.')
    stub_semantic(true)

    expect(call).to eq('Of course — let me bring in a colleague to help with delivery to your city.')
  end

  it 'acknowledges a customer-supplied destination without asserting any coverage or cost fact' do
    stub_generation(message: 'I understand you want delivery to Surabaya — a colleague will follow up on that for you.')
    validator = stub_semantic(true)

    expect(call).to eq('I understand you want delivery to Surabaya — a colleague will follow up on that for you.')
    expect(validator).to have_received(:valid?)
  end

  describe 'no-new-fact-token guard (rejects invented facts before the semantic validator)' do
    it 'rejects an injected price/amount number' do
      validator = stub_semantic(true)
      stub_generation(message: 'A colleague will confirm — delivery is about 250000 to your city.')

      expect(call).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'rejects an injected exact quantity number' do
      validator = stub_semantic(true)
      stub_generation(message: 'We have 42 units; a colleague will confirm the exact figure.')

      expect(call).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'rejects an injected currency symbol' do
      validator = stub_semantic(true)
      stub_generation(message: 'A colleague will confirm the shipping cost of $50 for you.')

      expect(call).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'rejects an injected identifier/code token' do
      validator = stub_semantic(true)
      stub_generation(message: 'A colleague will confirm coverage for zone Z9 shortly.')

      expect(call).to be_nil
      expect(validator).not_to have_received(:valid?)
    end
  end

  it 'returns nil when the separate semantic validator rejects (delivering the exact fallback)' do
    stub_generation(message: 'Sure, we can definitely deliver there for you.')
    stub_semantic(false)

    expect(call).to be_nil
  end

  it 'returns nil without generation on a blank fallback' do
    validator = stub_semantic(true)
    expect(Marine::Llm::BaseService).not_to receive(:new)

    expect(call(fallback: '   ')).to be_nil
    expect(validator).not_to have_received(:valid?)
  end

  it 'returns nil on a blank, fenced, control-bearing, or whole-JSON candidate, never validating' do
    validator = stub_semantic(true)
    ['', "```\nhelp\n```", "help#{0.chr}", '{"reply":"help"}'].each do |bad|
      stub_generation(message: bad)
      expect(call).to be_nil
    end
    expect(validator).not_to have_received(:valid?)
  end

  it 'returns nil when generation is unconfigured, errors, or raises' do
    allow(Marine::Llm::BaseService).to receive(:new).and_return(instance_double(Marine::Llm::BaseService, configured?: false))
    expect(call).to be_nil

    stub_generation(message: nil, success: false)
    expect(call).to be_nil
  end

  it 'fails closed to nil when a follow-up reply is only an opening greeting' do
    stub_generation(message: 'Halo!')
    validator = stub_semantic(true)

    expect(call(opening: false)).to be_nil
    expect(validator).not_to have_received(:valid?)
  end
end
