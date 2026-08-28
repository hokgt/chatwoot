# frozen_string_literal: true

require 'rails_helper'

# Phase 6 — fact-protected natural wording for a deterministic product reply. The service
# generates an untrusted candidate grounded ONLY on the deterministic localized fallback plus
# the Phase 2 bounded trigger/history, then delivers it ONLY when BOTH the deterministic
# ProductFactProtectionValidator (first) AND a separate FactPreservationValidator LLM call
# (second) accept the EXACT candidate. Any ineligibility, generation failure, or rejection
# returns nil. The real deterministic checker is used here (not stubbed) so the
# deterministic-before-semantic ordering is genuinely exercised.
RSpec.describe Marine::Catalog::GroundedProductWordingService do
  subject(:service) { described_class.new(account: nil) }

  let(:descriptor) { { kind: :parent_info, family_code: 'IMP', family_name: 'Impeller' } }
  let(:fallback) { "You're asking about Impeller. Which variant would you like?" }

  # The provider now enforces a bare { "reply": <string> } generation envelope and BaseService
  # returns its JSON text; stub_generation wraps the intended reply body in that envelope so specs
  # still express the reply the model produced while exercising the real envelope-extraction path.
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

  def call(action: :reply, descriptor: self.descriptor, fallback: self.fallback, # rubocop:disable Metrics/ParameterLists
           customer_request: 'what is impeller?', message_history: [], opening: true)
    service.call(action: action, descriptor: descriptor, fallback: fallback,
                 customer_request: customer_request, message_history: message_history, opening: opening)
  end

  it 'returns the candidate when generation, deterministic, and semantic gates all accept' do
    stub_generation(message: 'About Impeller — which variant would you like?')
    stub_semantic(true)

    expect(call).to eq('About Impeller — which variant would you like?')
  end

  # Phase 4 greeting policy is REUSED exactly as the FAQ wording path: enforcement runs on the
  # candidate BEFORE both gates, so both validators judge — and the caller delivers — the exact
  # enforced text, and there is no second transform after validation.
  it 'removes a follow-up opening salutation before both gates and delivers the exact enforced text' do
    stub_generation(message: 'Hello! About Impeller — which variant would you like?')
    validator = instance_double(Marine::Charge::FactPreservationValidator)
    captured = {}
    allow(validator).to receive(:valid?) do |args|
      captured.merge!(args)
      true
    end
    allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(validator)

    result = call(opening: false)

    # the follow-up opening salutation is removed BEFORE the deterministic + semantic gates
    expect(captured[:candidate]).to eq('About Impeller — which variant would you like?')
    # the delivered text is exactly the validated (enforced) text — no second transform
    expect(result).to eq('About Impeller — which variant would you like?')
  end

  it 'fails closed without validating when a follow-up reply is only an opening greeting' do
    stub_generation(message: 'Halo!')
    validator = stub_semantic(true)

    expect(call(opening: false)).to be_nil
    expect(validator).not_to have_received(:valid?)
  end

  it 'normalizes a wrong-time opening greeting before both gates on an opening turn' do
    stub_generation(message: 'Selamat sore. About Impeller — which variant would you like?')
    validator = instance_double(Marine::Charge::FactPreservationValidator)
    captured = {}
    allow(validator).to receive(:valid?) do |args|
      captured.merge!(args)
      true
    end
    allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(validator)

    travel_to(Time.utc(2026, 7, 20, 2, 37)) do # 09:37 WIB -> pagi
      result = call(opening: true)
      expect(captured[:candidate]).to eq('Selamat pagi. About Impeller — which variant would you like?')
      expect(result).to eq('Selamat pagi. About Impeller — which variant would you like?')
    end
  end

  it 'returns nil when the semantic validator rejects the candidate' do
    stub_generation(message: 'About Impeller — which variant would you like?')
    stub_semantic(false)

    expect(call).to be_nil
  end

  it 'runs the deterministic checker BEFORE the semantic validator (a deterministic rejection skips the semantic call)' do
    stub_generation(message: 'About Propeller — which variant would you like?') # changed family: deterministic reject
    validator = stub_semantic(true)

    expect(call).to be_nil
    expect(validator).not_to have_received(:valid?)
  end

  it 'passes the exact fallback as the semantic authority and the exact candidate' do
    stub_generation(message: 'About Impeller — which variant would you like?')
    validator = instance_double(Marine::Charge::FactPreservationValidator)
    captured = {}
    allow(validator).to receive(:valid?) do |args|
      captured.merge!(args)
      true
    end
    allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(validator)

    call
    expect(captured[:approved_answer]).to eq(fallback)
    expect(captured[:candidate]).to eq('About Impeller — which variant would you like?')
  end

  it 'never invokes an LLM for an unsupported descriptor kind' do
    stub_semantic(true)
    expect(Marine::Llm::BaseService).not_to receive(:new)

    expect(service.call(action: :reply, descriptor: { kind: :price_unavailable }, fallback: "I'm sorry, no price.", customer_request: 'x')).to be_nil
  end

  it 'never invokes an LLM when the kind is presented under the wrong action' do
    stub_semantic(true)
    expect(Marine::Llm::BaseService).not_to receive(:new)

    expect(call(action: :clarify_family)).to be_nil
  end

  it 'grounds generation only on the fallback plus the latest request and bounded history' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    captured = {}
    allow(llm).to receive(:chat) do |args|
      captured[:system] = args[:system]
      captured[:messages] = args[:messages]
      { ok: true, message: reply_envelope('About Impeller — which variant?'), error: nil }
    end
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    stub_semantic(true)

    history = [{ role: 'user', content: 'earlier question' }, { role: 'assistant', content: 'earlier answer' }]
    call(message_history: history, customer_request: 'what is impeller?')

    expect(captured[:system]).to include(fallback)
    expect(captured[:system]).to include('ONLY source of facts')
    contents = captured[:messages].map { |m| m[:content] || m['content'] }
    expect(contents).to eq(['earlier question', 'earlier answer', 'what is impeller?'])
    expect(contents.count('what is impeller?')).to eq(1)
  end

  it 'injects the reused Phase 4 greeting policy: business-time grounding when opening, no-greeting when follow-up' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    systems = []
    allow(llm).to receive(:chat) do |args|
      systems << args[:system]
      { ok: true, message: reply_envelope('About Impeller — which variant?'), error: nil }
    end
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    stub_semantic(true)

    travel_to(Time.utc(2026, 7, 20, 2, 37)) { call(opening: true) } # 09:37 WIB -> pagi
    call(opening: false)

    expect(systems.first).to include('Selamat pagi')   # opening: authoritative business-time greeting grounding
    expect(systems.last).to include('follow-up')        # follow-up: no-new-greeting policy
    expect(systems.last).not_to include('Selamat pagi')
  end

  # Tier 3 price_available exercises the deterministic amount/currency/UOM protection BEFORE the
  # semantic gate: a preserving candidate passes both and is delivered; a changed/extra price is
  # rejected deterministically so the semantic validator is never consulted.
  describe 'price_available (Tier 3) two-gate protection' do
    let(:price_descriptor) { { kind: :price_available, variant_code: 'IMP-3', currency: 'IDR', price_list_rate: '150000', uom: 'pcs' } }
    let(:price_fallback) { 'The price for IMP-3 is IDR 150000 per pcs.' }

    it 'delivers a price candidate preserving the variant code, exact amount/currency/UOM after semantic validation' do
      stub_generation(message: 'IMP-3 costs IDR 150000 per pcs.')
      validator = stub_semantic(true)

      expect(call(descriptor: price_descriptor, fallback: price_fallback)).to eq('IMP-3 costs IDR 150000 per pcs.')
      expect(validator).to have_received(:valid?)
    end

    it 'rejects a changed or extra price deterministically and never reaches the semantic validator' do
      validator = stub_semantic(true)

      stub_generation(message: 'IMP-3 costs IDR 15000 per pcs.') # changed amount
      expect(call(descriptor: price_descriptor, fallback: price_fallback)).to be_nil

      stub_generation(message: 'IMP-3 costs IDR 150000 per pcs, with 5 in stock.') # extra number
      expect(call(descriptor: price_descriptor, fallback: price_fallback)).to be_nil

      expect(validator).not_to have_received(:valid?)
    end
  end

  describe 'fail-closed handling (no repair, no partial use)' do
    it 'returns nil and never validates on a blank generation' do
      stub_generation(message: '')
      validator = stub_semantic(true)
      expect(call).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil on a non-String, control-bearing, fenced, or whole-JSON candidate' do
      validator = stub_semantic(true)
      [{ reply: 'x' }, "About Impeller#{0.chr}", "```\nAbout Impeller\n```", '{"reply":"About Impeller"}'].each do |bad|
        stub_generation(message: bad)
        expect(call).to be_nil
      end
      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil when generation is unconfigured, errors, or raises' do
      allow(Marine::Llm::BaseService).to receive(:new).and_return(instance_double(Marine::Llm::BaseService, configured?: false))
      validator = stub_semantic(true)
      expect(call).to be_nil

      stub_generation(message: nil, success: false)
      expect(call).to be_nil

      raising = instance_double(Marine::Llm::BaseService, configured?: true)
      allow(raising).to receive(:chat).and_raise(StandardError, 'boom')
      allow(Marine::Llm::BaseService).to receive(:new).and_return(raising)
      expect(call).to be_nil

      expect(validator).not_to have_received(:valid?)
    end

    it 'returns nil when the semantic validator errors or raises' do
      stub_generation(message: 'About Impeller — which variant would you like?')
      raising = instance_double(Marine::Charge::FactPreservationValidator)
      allow(raising).to receive(:valid?).and_raise(StandardError, 'boom')
      allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(raising)
      expect(call).to be_nil
    end
  end

  # Gate F — product generation is requested at temperature 0.0 as a variance-reducing control
  # (greedy decoding minimizes sampling variance so the rephrase drifts less run-to-run);
  # temperature 0.0 is NOT a determinism guarantee. It never relaxes acceptance: the candidate stays
  # fully untrusted and still passes the deterministic ProductFactProtectionValidator and the
  # separate semantic validator unchanged.
  it 'requests the generation at variance-reducing temperature 0.0' do
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    captured = {}
    allow(llm).to receive(:chat) do |args|
      captured.merge!(args)
      { ok: true, message: reply_envelope('About Impeller — which variant would you like?'), error: nil }
    end
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    stub_semantic(true)

    call

    expect(captured[:temperature]).to eq(0.0)
  end

  # Gate F structural stabilization — product generation is requested as a provider-enforced
  # { "reply": <string> } envelope (REPLY_SCHEMA) parsed as an EXACT object with NO fence
  # stripping/extraction/repair. Anything that is not a bare { "reply": <string> } fails closed to
  # nil and the caller delivers its exact deterministic fallback; NEITHER the deterministic
  # ProductFactProtectionValidator nor the semantic validator can be satisfied by a malformed
  # envelope. The reply body stays a same-language natural rephrase — nothing here requires the
  # fallback to appear verbatim.
  describe 'generation envelope' do
    def stub_raw_generation(raw)
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      allow(llm).to receive(:chat).and_return({ ok: true, message: raw, error: nil })
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      llm
    end

    it 'requests provider-enforced structured output with the strict reply envelope schema' do
      captured = {}
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      allow(llm).to receive(:chat) do |args|
        captured.merge!(args)
        { ok: true, message: reply_envelope('About Impeller — which variant would you like?'), error: nil }
      end
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      stub_semantic(true)

      call

      schema = captured[:schema]
      expect(schema[:strict]).to be(true)
      expect(schema.dig(:schema, :type)).to eq('object')
      expect(schema.dig(:schema, :additionalProperties)).to be(false)
      expect(schema.dig(:schema, :required)).to eq(%w[reply])
      expect(schema.dig(:schema, :properties, 'reply')).to eq({ type: 'string' })
    end

    it 'extracts and delivers the reply body from a well-formed envelope after both gates' do
      stub_raw_generation(reply_envelope('About Impeller — which variant would you like?'))
      stub_semantic(true)

      expect(call).to eq('About Impeller — which variant would you like?')
    end

    it 'fails closed on a malformed/wrong/extra/duplicate/passed-through envelope' do
      validator = stub_semantic(true)
      [
        { reply: { nested: 'x' } }.to_json, # reply not a string
        { note: 'x' }.to_json, # missing reply key
        { reply: 'About Impeller — which variant?', note: 'x' }.to_json, # extra key
        '{"reply": "first", "reply": "second"}', # duplicate reply key
        '{"reply": "About Impeller",', # malformed JSON (no repair)
        "```json\n#{reply_envelope('About Impeller — which variant?')}\n```", # fenced passthrough
        '["reply"]', # wrong top-level type
        (+"\xff\xfe").force_encoding('UTF-8') # invalid encoding
      ].each do |raw|
        stub_raw_generation(raw)
        expect(call).to be_nil
      end
      expect(validator).not_to have_received(:valid?)
    end
  end

  # Stock-availability naturalization — the reply must sound natural and adapt to the latest
  # inquiry rather than echoing one rigid canned availability sentence. The generation prompt must
  # therefore preserve the concrete token-protected facts exactly while allowing the availability to
  # be expressed in FRESH, varied words (its binary meaning still guarded by the two gates), and must
  # never let wording inject a quantity or flip the in-stock/out-of-stock boolean.
  describe 'stock-availability natural wording' do
    let(:in_stock_descriptor) { { kind: :stock_available, variant_code: 'IMP-3' } }
    let(:in_stock_fallback) { 'IMP-3 is currently in stock.' }
    let(:out_of_stock_descriptor) { { kind: :stock_empty, variant_code: 'IMP-3' } }
    let(:out_of_stock_fallback) { "I'm sorry, IMP-3 is currently out of stock." }

    def capture_generation_system(descriptor:, fallback:, customer_request: 'is it available?')
      captured = {}
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      allow(llm).to receive(:chat) do |args|
        captured.merge!(args)
        { ok: true, message: reply_envelope('Yes, that one is available right now.'), error: nil }
      end
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      stub_semantic(true)
      call(descriptor: descriptor, fallback: fallback, customer_request: customer_request)
      captured
    end

    it 'instructs the model to keep the availability MEANING but express it in fresh, varied words (not a fixed sentence)' do
      system = capture_generation_system(descriptor: in_stock_descriptor, fallback: in_stock_fallback)[:system]

      # Root-cause guard: the old prompt froze the "availability statement ... exactly and unchanged",
      # forcing the model to echo one canned sentence for every stock reply.
      expect(system).not_to include('availability statement')
      expect(system).to include('fresh, natural words')
      expect(system).to include('varying your wording')
      # The concrete facts (and the no-quantity rule) are still preserved verbatim.
      expect(system).to include('ONLY source of facts')
      expect(system).to include('exactly and unchanged')
      expect(system).to match(/never state or imply a quantity/i)
    end

    it 'delivers a varied, natural in-stock reply adapted to the latest question through both gates' do
      stub_generation(message: 'Yes — we do have IMP-3 on hand right now, happy to help!')
      stub_semantic(true)

      result = call(descriptor: in_stock_descriptor, fallback: in_stock_fallback, customer_request: 'do you still have it?')

      expect(result).to eq('Yes — we do have IMP-3 on hand right now, happy to help!')
      expect(result).not_to eq(in_stock_fallback) # no longer forced to the rigid canned sentence
    end

    it 'delivers a varied, natural out-of-stock reply naming the exact code through both gates' do
      stub_generation(message: "Unfortunately IMP-3's sold out at the moment — sorry about that.")
      stub_semantic(true)

      expect(call(descriptor: out_of_stock_descriptor, fallback: out_of_stock_fallback))
        .to eq("Unfortunately IMP-3's sold out at the moment — sorry about that.")
    end

    it 'rejects a quantity injected by naturalization deterministically, before the semantic gate' do
      validator = stub_semantic(true)
      stub_generation(message: 'Yes, we currently have 24 of IMP-3 on hand.') # invents a quantity

      expect(call(descriptor: in_stock_descriptor, fallback: in_stock_fallback)).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    it 'rejects a candidate that flips the in-stock boolean via the semantic gate (safe fallback)' do
      stub_generation(message: "I'm sorry, IMP-3 is out of stock right now.") # contradicts in-stock truth
      stub_semantic(false)

      expect(call(descriptor: in_stock_descriptor, fallback: in_stock_fallback)).to be_nil
    end

    it 'passes the latest inquiry and stock fallback to generation so wording can adapt to it' do
      captured = capture_generation_system(descriptor: in_stock_descriptor, fallback: in_stock_fallback,
                                           customer_request: 'is the impeller in stock?')

      expect(captured[:system]).to include(in_stock_fallback)
      contents = captured[:messages].map { |m| m[:content] || m['content'] }
      expect(contents.last).to eq('is the impeller in stock?')
    end

    it 'falls back safely (nil) when stock generation fails, so the caller delivers the exact fallback' do
      allow(Marine::Llm::BaseService).to receive(:new)
        .and_return(instance_double(Marine::Llm::BaseService, configured?: false))
      validator = stub_semantic(true)

      expect(call(descriptor: in_stock_descriptor, fallback: in_stock_fallback)).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    # Live-acceptance fix: the semantic judge applied the general rubric with no notion that a binary
    # stock reply's ONLY material fact is one boolean, so it over-rejected benign same-direction
    # rephrasings and returned nil. The fix threads a binary-stock fact-focus into the semantic
    # validator for the two pure stock kinds ONLY; every other path keeps the unscoped rubric (nil).
    # Delivery/flip/quantity behaviour through the two gates is already covered above.
    describe 'stock-only semantic fact-focus guidance' do
      def captured_fact_focus(descriptor:, fallback:, message:)
        stub_generation(message: message)
        validator = instance_double(Marine::Charge::FactPreservationValidator)
        captured = {}
        allow(validator).to receive(:valid?) do |args|
          captured.merge!(args)
          true
        end
        allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(validator)
        call(descriptor: descriptor, fallback: fallback)
        captured
      end

      it 'sends binary-stock fact-focus for a stock_available reply' do
        focus = captured_fact_focus(descriptor: in_stock_descriptor, fallback: in_stock_fallback,
                                    message: 'Yes, we have IMP-3 right now.')[:fact_focus]
        expect(focus).to match(/binary/i).and match(/in stock|out of stock/i)
      end

      it 'sends binary-stock fact-focus for a stock_empty reply' do
        focus = captured_fact_focus(descriptor: out_of_stock_descriptor, fallback: out_of_stock_fallback,
                                    message: "Unfortunately IMP-3's sold out at the moment — sorry about that.")[:fact_focus]
        expect(focus).to be_present
      end

      it 'keeps the unscoped rubric (nil fact-focus) for a non-stock product reply' do
        captured = captured_fact_focus(descriptor: descriptor, fallback: fallback,
                                       message: 'About Impeller — which variant would you like?')
        expect(captured).to have_key(:fact_focus)
        expect(captured[:fact_focus]).to be_nil
      end

      it 'keeps the unscoped rubric (nil fact-focus) for a price reply' do
        captured = captured_fact_focus(
          descriptor: { kind: :price_available, variant_code: 'IMP-3', currency: 'IDR', price_list_rate: '150000', uom: 'pcs' },
          fallback: 'The price for IMP-3 is IDR 150000 per pcs.', message: 'IMP-3 costs IDR 150000 per pcs.'
        )
        expect(captured[:fact_focus]).to be_nil
      end

      # Contract of the guidance itself. The stock Approved Answer now names the validated variant
      # code, so the focus must declare TWO material facts (the identity AND the binary outcome),
      # state that repeating the exact identity is preservation (not an added fact), accept ordinary
      # greetings/framing, and still reject a changed/dropped/different identity, an availability flip,
      # uncertainty/conditionality, a quantity, a location, a price, or a delivery/lead time.
      it 'declares identity + outcome as the two facts, treats an exact-identity repeat as preservation, accepts greetings, rejects unsafe changes' do
        guidance = described_class::STOCK_FACT_FOCUS
        expect(guidance).to match(/two material facts/i)
        expect(guidance).to match(/identity/i).and match(/code, model, or name/i)
        expect(guidance).to match(/binary/i).and match(/in stock/i).and match(/out of stock/i)
        # exact identity repeated is preservation, not an added fact
        expect(guidance).to match(/NOT a new or added fact/i).and match(/preservation/i)
        # greetings/framing never cause rejection
        expect(guidance).to match(/greetings/i).and match(/never let them cause rejection/i)
        # unsafe changes still reject
        expect(guidance).to match(/changes, drops, or substitutes a DIFFERENT/i)
        expect(guidance).to match(/reverses the availability/i)
        expect(guidance).to match(/uncertain or conditional/i)
        expect(guidance).to match(/quantity/i).and match(/warehouse, location, or bin/i)
          .and match(/price/i).and match(/delivery or lead time/i)
        # no product-specific or phrase-list hardcoding
        expect(guidance).not_to match(/IMP-3|SR-20/)
      end

      # A faithful, greeting-bearing candidate that keeps the exact code and availability clears the
      # deterministic gate (greetings add no protected/inventory tokens) and reaches the semantic
      # validator carrying the binary-stock focus; when the semantic gate accepts, it is delivered.
      it 'passes a greeting-bearing faithful candidate through the deterministic gate to the semantic validator, then delivers it' do
        stub_generation(message: 'Hi there! Yes — IMP-3 is in stock right now.')
        validator = instance_double(Marine::Charge::FactPreservationValidator)
        captured = {}
        allow(validator).to receive(:valid?) do |args|
          captured.merge!(args)
          true
        end
        allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(validator)

        result = call(descriptor: in_stock_descriptor, fallback: in_stock_fallback, customer_request: 'is it available?')

        expect(captured[:fact_focus]).to eq(described_class::STOCK_FACT_FOCUS)
        expect(captured[:candidate]).to eq('Hi there! Yes — IMP-3 is in stock right now.')
        expect(result).to eq('Hi there! Yes — IMP-3 is in stock right now.')
      end

      # The deterministic gate — running BEFORE the semantic one — already fails closed on a changed,
      # dropped, or different variant identity, so those never reach (and cannot be rescued by) the
      # semantic validator.
      it 'rejects a changed, dropped, or different variant identity deterministically, before the semantic gate' do
        validator = stub_semantic(true)

        stub_generation(message: 'Good news — IMP-4 is currently in stock.') # changed code
        expect(call(descriptor: in_stock_descriptor, fallback: in_stock_fallback)).to be_nil

        stub_generation(message: 'Yes, that one is available right now.') # dropped code
        expect(call(descriptor: in_stock_descriptor, fallback: in_stock_fallback)).to be_nil

        stub_generation(message: 'Yes — IMP-3 and IMP-9 are both in stock.') # extra/different code
        expect(call(descriptor: in_stock_descriptor, fallback: in_stock_fallback)).to be_nil

        expect(validator).not_to have_received(:valid?)
      end

      # A candidate that keeps the exact code but is semantically unsafe (an availability flip,
      # uncertainty/conditionality, or an added location/price/delivery fact the deterministic
      # inventory cannot see) clears the deterministic gate and is refused by the semantic validator,
      # so the caller falls back to the exact deterministic reply. The stock focus is still supplied.
      it 'lets the semantic validator veto a code-preserving but unsafe candidate, falling back safely' do
        stub_generation(message: 'IMP-3 might be in stock, ready for next-week delivery.') # uncertainty + lead time
        validator = instance_double(Marine::Charge::FactPreservationValidator)
        captured = {}
        allow(validator).to receive(:valid?) do |args|
          captured.merge!(args)
          false
        end
        allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(validator)

        expect(call(descriptor: in_stock_descriptor, fallback: in_stock_fallback)).to be_nil
        expect(captured[:fact_focus]).to eq(described_class::STOCK_FACT_FOCUS)
      end
    end
  end
end
