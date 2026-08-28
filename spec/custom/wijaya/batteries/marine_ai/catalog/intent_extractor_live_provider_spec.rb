# frozen_string_literal: true

require 'rails_helper'

# Configured-provider probe. Exercises the REAL working-tree IntentExtractor against the ACTUALLY
# configured Marine LLM provider (never a stub) to prove the structured answer-shape contract lets the
# provider distinguish an exact-quantity ("how many units") stock ask from a plain availability ask,
# including Indonesian / mixed-language phrasings. It is READ-ONLY and NON-DELIVERING: it only
# classifies intent — no Message/Attachment, DB row, catalog lookup, or state mutation — and uses
# purely SYNTHETIC inputs (no real conversation, and the code token is an opaque placeholder).
#
# It self-skips unless probe credentials are supplied via MARINE_PROBE_* ENV, so ordinary CI runs
# never make a network call. Credentials are resolved from the deployed installation config and passed
# in out-of-band, so the probe runs the working tree without this (test) database carrying the MARINE_*
# InstallationConfig rows. Gemini's rubyllm_provider is the OpenAI-compatible adapter, so injecting the
# resolved api_key/api_base/model reproduces the deployed provider exactly.
RSpec.describe Marine::Catalog::IntentExtractor, :marine_live_provider do
  subject(:extractor) { described_class.new(base_service: base_service) }

  let(:base_service) do
    Marine::Llm::BaseService.new(
      api_key: ENV.fetch('MARINE_PROBE_API_KEY'),
      api_base: ENV['MARINE_PROBE_API_BASE'].presence,
      model: ENV['MARINE_PROBE_MODEL'].presence
    )
  end

  before do
    skip 'set MARINE_PROBE_API_KEY to run the configured-provider probe' if ENV['MARINE_PROBE_API_KEY'].to_s.strip.empty?

    WebMock.allow_net_connect!
  end

  # Restore the suite's global WebMock posture (real net blocked, localhost still allowed) rather than
  # blocking localhost outright, which some other specs / infrastructure rely on.
  after { WebMock.disable_net_connect!(allow_localhost: true) }

  def classify(text)
    extractor.extract(text: text, context: [], state: nil)
  end

  it 'classifies an Indonesian "how much stock" ask as an exact quantity inquiry' do
    result = classify('ada berapa stock SR-20?')

    expect(result[:quantity_inquiry]).to be(true)
    expect(result[:unsupported_request]).to eq('exact_quantity')
  end

  it 'classifies an Indonesian "how much stock is available" ask as an exact quantity inquiry' do
    result = classify('berapa stok SR-20 yang tersedia?')

    expect(result[:quantity_inquiry]).to be(true)
    expect(result[:unsupported_request]).to eq('exact_quantity')
  end

  it 'keeps a plain availability control binary (quantity_inquiry false, category nil)' do
    result = classify('apakah SR-20 tersedia?')

    expect(result[:quantity_inquiry]).to be(false)
    expect(result[:unsupported_request]).to be_nil
  end
end
