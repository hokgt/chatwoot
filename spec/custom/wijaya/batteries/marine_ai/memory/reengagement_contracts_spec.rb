# frozen_string_literal: true

require 'rails_helper'

# Deterministic structured-contract specs for the re-engagement collaborators: the strict
# parsing of the provider envelopes (never repaired, always fail-closed) behind the greeting
# classifier, the topic extractor, and the semantic verifier.
RSpec.describe 'Marine memory re-engagement structured contracts' do
  let(:account) { create(:account) }

  def service_returning(raw, provider_ok: true)
    service = double('llm_service')
    allow(service).to receive(:configured?).and_return(true)
    allow(service).to receive(:chat).and_return({ ok: provider_ok, message: raw })
    service
  end

  describe Marine::Memory::Reengagement::GreetingClassifier do
    def classify(raw, provider_ok: true)
      described_class.new(account: account, service: service_returning(raw, provider_ok: provider_ok))
                     .classify(trigger: 'selamat pagi')
    end

    it 'accepts an affirmative structured pure-greeting decision with a language' do
      decision = classify(JSON.generate({ 'pure_greeting' => true, 'language' => 'id' }))
      expect(decision).to be_eligible
      expect(decision.language).to eq('id')
    end

    it 'is ineligible for a non-pure greeting (greeting plus a current need)' do
      decision = classify(JSON.generate({ 'pure_greeting' => false, 'language' => 'id' }))
      expect(decision).not_to be_eligible
    end

    it 'is ineligible for unknown/missing language, malformed shape, provider failure, or error' do
      expect(classify(JSON.generate({ 'pure_greeting' => true, 'language' => 'unknown' }))).not_to be_eligible
      expect(classify(JSON.generate({ 'pure_greeting' => true, 'language' => '' }))).not_to be_eligible
      expect(classify(JSON.generate({ 'pure_greeting' => true }))).not_to be_eligible
      expect(classify(JSON.generate({ 'pure_greeting' => 'yes', 'language' => 'id' }))).not_to be_eligible
      expect(classify('not json at all', provider_ok: false)).not_to be_eligible
      raising = double('llm_service')
      allow(raising).to receive(:configured?).and_return(true)
      allow(raising).to receive(:chat).and_raise(StandardError)
      expect(described_class.new(account: account, service: raising).classify(trigger: 'halo')).not_to be_eligible
      expect(described_class.new(account: account, service: service_returning('')).classify(trigger: '')).not_to be_eligible
    end
  end

  describe Marine::Memory::Reengagement::TopicExtractor do
    def extract(raw)
      described_class.new(account: account, service: service_returning(raw))
                     .extract(notes: ['Customer menanyakan seragam serikat.'])
    end

    it 'projects a single structured topic (with optional product)' do
      extraction = extract(JSON.generate({ 'topics' => [{ 'topic' => 'seragam serikat', 'product' => 'SRG-01' }] }))
      expect(extraction.topics.size).to eq(1)
      expect(extraction.topics.first.topic).to eq('seragam serikat')
      expect(extraction.topics.first.product).to eq('SRG-01')
    end

    it 'treats an empty product as nil and an empty list as no topics' do
      extraction = extract(JSON.generate({ 'topics' => [{ 'topic' => 'seragam', 'product' => '' }] }))
      expect(extraction.topics.first.product).to be_nil
      expect(extract(JSON.generate({ 'topics' => [] })).topics).to eq([])
    end

    it 'fails closed on malformed shapes, missing notes, or provider errors' do
      expect(extract(JSON.generate({ 'topics' => 'nope' })).topics).to eq([])
      expect(extract(JSON.generate({ 'topics' => [{ 'topic' => 7, 'product' => '' }] })).topics).to eq([])
      expect(extract('fenced junk').topics).to eq([])
      expect(described_class.new(account: account, service: service_returning('')).extract(notes: []).topics).to eq([])
    end
  end

  describe Marine::Memory::Reengagement::Verifier do
    def verdict(fields)
      JSON.generate({ 'verdict' => JSON.generate(fields) })
    end

    def valid?(raw)
      described_class.new(account: account, service: service_returning(raw))
                     .valid?(candidate: 'Kita pernah membahas seragam. Mau lanjut? Ada yang lain?',
                             topic: 'seragam serikat', product: nil, language: 'id')
    end

    let(:all_true) do
      verdict({ 'mentions_prior_discussion' => true, 'asks_whether_to_continue' => true,
                'offers_other_help' => true, 'no_continued_interest_assertion' => true,
                'no_unsupported_claims' => true, 'in_target_language' => true, 'certain' => true })
    end

    it 'accepts only a complete all-true verdict' do
      expect(valid?(all_true)).to be(true)
    end

    it 'rejects any false field, missing field, non-boolean value, or malformed envelope' do
      expect(valid?(verdict({ 'mentions_prior_discussion' => false, 'asks_whether_to_continue' => true,
                              'offers_other_help' => true, 'no_continued_interest_assertion' => true,
                              'no_unsupported_claims' => true, 'in_target_language' => true, 'certain' => true }))).to be(false)
      expect(valid?(verdict({ 'asks_whether_to_continue' => true, 'offers_other_help' => true,
                              'no_continued_interest_assertion' => true, 'no_unsupported_claims' => true,
                              'in_target_language' => true, 'certain' => true }))).to be(false)
      expect(valid?(verdict({ 'mentions_prior_discussion' => 'true', 'asks_whether_to_continue' => true,
                              'offers_other_help' => true, 'no_continued_interest_assertion' => true,
                              'no_unsupported_claims' => true, 'in_target_language' => true, 'certain' => true }))).to be(false)
      expect(valid?('{"verdict": "not json"}')).to be(false)
      expect(valid?('plain prose')).to be(false)
    end

    it 'fails closed on provider failure or error' do
      failing = double('llm_service')
      allow(failing).to receive(:chat).and_return({ ok: false, message: nil })
      expect(described_class.new(account: account, service: failing)
              .valid?(candidate: 'x', topic: 'y', product: nil, language: 'id')).to be(false)
      raising = double('llm_service')
      allow(raising).to receive(:chat).and_raise(StandardError)
      expect(described_class.new(account: account, service: raising)
              .valid?(candidate: 'x', topic: 'y', product: nil, language: 'id')).to be(false)
    end
  end
end
