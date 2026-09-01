# frozen_string_literal: true

require 'rails_helper'

# Unit coverage for the shared fail-closed DELIVER/HANDOFF stock decision. The natural-wording
# service and the language detector are stubbed so each branch is asserted deterministically; the
# fact-protection eligibility check runs for real (BD-1 is a valid coded stock descriptor).
#
# STRICT CONTRACT: the ONLY text the composer DELIVERS for a stock turn is an accepted DYNAMIC
# natural candidate. The deterministic (English or localized) stock sentence is grounding ONLY — it
# is NEVER the delivered final answer. Every non-accepted path (rejected candidate, codeless/
# ineligible descriptor, unknown/source/known target, degraded localization) fails closed to the
# factless handoff.
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

    # --- RED: the deterministic/localized stock sentence must NEVER be the final answer -----------

    it 'HANDS OFF (never delivers the localized fallback) when the candidate is rejected — even if the fallback is reliably in-language' do
      stub_wording(nil)
      stub_detector(fallback => { language: 'id', reliable: true, confidence: 0.99 },
                    ack_id => { language: 'id', reliable: true, confidence: 0.99 })

      decision = compose(ack: -> { ack_id })
      expect(decision).to be_handoff
      expect(decision.text).to be_nil
      expect(decision.message).to eq(ack_id) # factless acknowledgement, not the stock line
      expect(decision.message).not_to eq(fallback)
    end

    it 'HANDS OFF (never delivers the English fallback) for an English (source) target when the candidate is rejected' do
      stub_wording(nil)
      stub_detector(ack_en => { language: 'en', reliable: true, confidence: 0.99 })

      decision = compose(reply_language: 'en', fall: english_source, ack: -> { ack_en })
      expect(decision).to be_handoff
      expect(decision.text).to be_nil
      expect(decision.message).to eq(ack_en) # visible English factless acknowledgement (source target)
      expect(decision.message).not_to eq(english_source)
    end

    it 'HANDS OFF (never delivers the fallback) for an unknown/malformed target when the candidate is rejected' do
      stub_wording(nil)
      stub_detector(ack_en => { language: 'en', reliable: true, confidence: 0.99 })

      %w[unknown].each do |lang|
        decision = compose(reply_language: lang, ack: -> { ack_en })
        expect(decision).to be_handoff
        expect(decision.text).to be_nil
      end
      expect(compose(reply_language: '  ', ack: -> { ack_en }).text).to be_nil
      expect(compose(reply_language: 'not a code', ack: -> { ack_en }).text).to be_nil
    end

    it 'HANDS OFF for a codeless/malformed stock descriptor without naturalizing (ineligible) — never a hardcoded stock claim' do
      expect(Marine::Catalog::GroundedProductWordingService).not_to receive(:new)
      stub_detector(ack_id => { language: 'id', reliable: true, confidence: 0.99 })

      decision = compose(desc: renderer.stock_available(nil),
                         fall: 'Good news — that item is currently in stock.', ack: -> { ack_id })
      expect(decision).to be_handoff
      expect(decision.text).to be_nil
      expect(decision.message).to eq(ack_id)
    end

    # --- Handoff acknowledgement language behaviour on the fail-closed path ------------------------

    it 'HANDS OFF with a visible in-language acknowledgement when it is provably in the target language' do
      stub_wording(nil)
      stub_detector(ack_id => { language: 'id', reliable: true, confidence: 0.99 })

      decision = compose(ack: -> { ack_id })
      expect(decision).to be_handoff
      expect(decision.message).to eq(ack_id)
      expect(decision.silent).to be(false)
    end

    it 'HANDS OFF SILENTLY when the acknowledgement cannot be proven in the target language' do
      stub_wording(nil)
      stub_detector(ack_en => { language: 'en', reliable: true, confidence: 0.99 })

      decision = compose(ack: -> { ack_en })
      expect(decision).to be_handoff
      expect(decision.message).to be_nil
      expect(decision.silent).to be(true)
      expect(decision.ack).to eq(ack_en) # still available for a preview surface to show
    end

    it 'passes a non-stock descriptor straight through without naturalizing (not its concern)' do
      expect(Marine::Catalog::GroundedProductWordingService).not_to receive(:new)

      decision = compose(desc: renderer.parent_info(code: 'BD', name: 'Baby Doll'), fall: 'anything')
      expect(decision).to be_deliver
      expect(decision.text).to eq('anything')
    end
  end

  describe '#degraded' do
    it 'ALWAYS hands off SILENTLY (localization already failed — no candidate, no localizable ack, no stock prose)' do
      decision = composer.degraded
      expect(decision).to be_handoff
      expect(decision.text).to be_nil
      expect(decision.message).to be_nil
      expect(decision.silent).to be(true)
    end
  end
end
