# frozen_string_literal: true

require 'rails_helper'

# Unit coverage for the shared DELIVER/HANDOFF stock decision. The natural-wording service and the
# language detector are stubbed so each branch is asserted deterministically; the fact-protection
# eligibility check runs for real (BD-1 is a valid coded stock descriptor).
RSpec.describe Marine::Catalog::StockReplyComposer do
  subject(:composer) { described_class.new(account: nil) }

  let(:renderer) { Marine::Catalog::ReplyRenderer.new }
  let(:descriptor) { renderer.stock_available('BD-1') }
  let(:fallback) { 'BD-1 saat ini tersedia.' }
  let(:english_source) { 'BD-1 is currently in stock.' }
  let(:ack_id) { 'Maaf, saya belum bisa memastikannya. Saya akan menghubungkan Anda dengan rekan.' }
  let(:ack_en) { Marine::Catalog::ReplyPresenter::HANDOFF_ACK_TEXT }

  # GroundedProductWordingService stubbed to return a fixed candidate (or nil = rejected).
  def stub_wording(result)
    service = instance_double(Marine::Catalog::GroundedProductWordingService, call: result)
    allow(Marine::Catalog::GroundedProductWordingService).to receive(:new).and_return(service)
  end

  # LanguageDetector stubbed by text -> reading (default: unreliable/unknown -> fails closed).
  def stub_detector(map)
    allow(Marine::Llm::LanguageDetector).to receive(:new) do |text|
      reading = map.fetch(text, { language: 'unknown', reliable: false, confidence: 0.0 })
      instance_double(Marine::Llm::LanguageDetector, detect: reading)
    end
  end

  def compose(reply_language: 'id', ack: -> { ack_en }, fall: nil, desc: nil)
    composer.compose(descriptor: desc || descriptor, fallback: fall || fallback,
                     reply_language: reply_language, customer_request: 'apakah BD-1 tersedia',
                     message_history: [], opening: true, localized_ack: ack)
  end

  describe '#compose' do
    it 'DELIVERS an accepted natural candidate verbatim' do
      stub_wording('Ya, BD-1 saat ini tersedia!')

      decision = compose
      expect(decision).to be_deliver
      expect(decision.text).to eq('Ya, BD-1 saat ini tersedia!')
    end

    it 'DELIVERS the localized fallback when the candidate is rejected but the fallback is reliably in-language' do
      stub_wording(nil)
      stub_detector(fallback => { language: 'id', reliable: true, confidence: 0.99 })

      decision = compose
      expect(decision).to be_deliver
      expect(decision.text).to eq(fallback)
    end

    it 'HANDS OFF with a visible in-language acknowledgement when the fallback is not provably in-language' do
      stub_wording(nil)
      stub_detector(fallback => { language: 'en', reliable: true, confidence: 0.99 },
                    ack_id => { language: 'id', reliable: true, confidence: 0.99 })

      decision = compose(ack: -> { ack_id })
      expect(decision).to be_handoff
      expect(decision.message).to eq(ack_id)
      expect(decision.silent).to be(false)
    end

    it 'HANDS OFF SILENTLY when neither the fallback nor the acknowledgement can be proven in-language' do
      stub_wording(nil)
      stub_detector(fallback => { language: 'en', reliable: true, confidence: 0.99 },
                    ack_en => { language: 'en', reliable: true, confidence: 0.99 })

      decision = compose(ack: -> { ack_en })
      expect(decision).to be_handoff
      expect(decision.message).to be_nil
      expect(decision.silent).to be(true)
      expect(decision.ack).to eq(ack_en) # still available for a preview surface to show
    end

    it 'DELIVERS the English fallback for an English (source) target without any handoff' do
      stub_wording(nil)

      decision = compose(reply_language: 'en', fall: english_source)
      expect(decision).to be_deliver
      expect(decision.text).to eq(english_source)
    end

    it 'DELIVERS the fallback for an unknown/malformed target (no in-language guarantee claimed)' do
      stub_wording(nil)

      expect(compose(reply_language: 'unknown').text).to eq(fallback)
      expect(compose(reply_language: '  ').text).to eq(fallback)
      expect(compose(reply_language: 'not a code').text).to eq(fallback)
    end

    it 'DELIVERS a codeless stock fallback without naturalizing or gating (ineligible descriptor)' do
      expect(Marine::Catalog::GroundedProductWordingService).not_to receive(:new)
      expect(Marine::Llm::LanguageDetector).not_to receive(:new)

      decision = compose(desc: renderer.stock_available(nil), fall: 'Good news — that item is currently in stock.')
      expect(decision).to be_deliver
      expect(decision.text).to eq('Good news — that item is currently in stock.')
    end

    it 'passes a non-stock descriptor straight through without naturalizing (not its concern)' do
      expect(Marine::Catalog::GroundedProductWordingService).not_to receive(:new)

      decision = compose(desc: renderer.parent_info(code: 'BD', name: 'Baby Doll'), fall: 'anything')
      expect(decision).to be_deliver
      expect(decision.text).to eq('anything')
    end
  end

  describe '#degraded' do
    it 'DELIVERS the English text for an unknown/source target' do
      expect(composer.degraded(text: english_source, reply_language: 'en')).to be_deliver
      expect(composer.degraded(text: english_source, reply_language: nil)).to be_deliver
    end

    it 'HANDS OFF SILENTLY under a known non-source target when the English text is not in-language' do
      stub_detector(english_source => { language: 'en', reliable: true, confidence: 0.99 })

      decision = composer.degraded(text: english_source, reply_language: 'id')
      expect(decision).to be_handoff
      expect(decision.silent).to be(true)
      expect(decision.message).to be_nil
    end
  end
end
