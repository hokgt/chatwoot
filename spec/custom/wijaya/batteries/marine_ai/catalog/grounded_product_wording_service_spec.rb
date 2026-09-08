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

  # Schema-aware chat stub for the stock language-proof path. Generation calls (REPLY_SCHEMA) are
  # answered from the queued messages in order (the last repeats); a provider language-PROOF call
  # (LANGUAGE_SCHEMA, made only for a stock candidate whose LOCAL read does not match the target)
  # is answered from `proofs`, keyed by the candidate string it is asked to classify. This lets a
  # test drive both the bounded generation retry AND the reliable-different/indeterminable provider
  # proof deterministically, and count the two call kinds separately.
  def stub_generations_and_proofs(gen_messages, proofs: {})
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    responses = gen_messages.map { |m| { ok: true, message: reply_envelope(m), error: nil } }
    idx = 0
    allow(llm).to receive(:chat) do |args|
      if args[:schema] == described_class::LANGUAGE_SCHEMA
        candidate = args[:messages].last[:content] || args[:messages].last['content']
        { ok: true, message: { language: proofs.fetch(candidate, 'unknown') }.to_json, error: nil }
      else
        resp = responses[idx] || responses.last
        idx += 1
        resp
      end
    end
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    llm
  end

  def call(action: :reply, descriptor: self.descriptor, fallback: self.fallback, # rubocop:disable Metrics/ParameterLists
           customer_request: 'what is impeller?', message_history: [], opening: true, reply_language: nil)
    service.call(action: action, descriptor: descriptor, fallback: fallback,
                 customer_request: customer_request, message_history: message_history, opening: opening,
                 reply_language: reply_language)
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

  # Gate F — a NON-stock product generation is requested at temperature 0.0 as a variance-reducing
  # control (greedy decoding minimizes sampling variance so the rephrase drifts less run-to-run);
  # temperature 0.0 is NOT a determinism guarantee. (A pure stock reply instead uses a small bounded
  # nonzero temperature — see 'stock natural-wording generation'.) It never relaxes
  # acceptance: the candidate stays fully untrusted and still passes the deterministic
  # ProductFactProtectionValidator and the separate semantic validator unchanged.
  it 'requests a non-stock generation at variance-reducing temperature 0.0' do
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

    it 'passes the latest inquiry and the structured availability status (never the fallback sentence) to generation' do
      captured = capture_generation_system(descriptor: in_stock_descriptor, fallback: in_stock_fallback,
                                           customer_request: 'is the impeller in stock?')

      # A stock reply now grounds on the structured availability data (identity + binary status), so the
      # provider is never handed the prewritten fallback sentence to echo.
      expect(captured[:system]).to include('"product":"IMP-3"').and include('"availability":"available"')
      expect(captured[:system]).not_to include(in_stock_fallback)
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
        # greetings/framing never cause rejection — including a brief offer of further help, the warm
        # closing pleasantry the judge otherwise miscounted as an added fact (the opening-turn over-rejection)
        expect(guidance).to match(/greetings/i).and match(/never let them cause rejection/i)
        expect(guidance).to match(/offer of further help/i)
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

        stub_generation(message: 'Good news — IMP-4 is on hand right now, happy to help!') # changed code
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

  # Customer-language binding — the final visible wording must be in the customer's own language.
  # The caller threads the authoritative reply/customer language (the provider classification of the
  # same turn). Under a KNOWN target the gate is fail-CLOSED: a candidate passes ONLY when the shared
  # detector RELIABLY reads it with the same primary subtag; a reliably-different read AND an
  # unreliable/unreadable read are both rejected (the caller then delivers a same-language fallback),
  # so no possibly-wrong-language candidate — e.g. an English reply to an Indonesian customer — can
  # pass. Only an absent/unknown/malformed target turns the gate off (no authoritative language to
  # bind to), keeping the pre-language behavior for callers that supply no target.
  describe 'customer-language consistency gate' do
    let(:in_stock_descriptor) { { kind: :stock_available, variant_code: 'IMP-3' } }
    let(:in_stock_fallback) { 'IMP-3 is currently in stock.' }

    # Stub the shared detector for ONE exact candidate string only (call_original elsewhere so the
    # real greeting policy is unaffected), so the gate is exercised without depending on CLD3 output.
    def stub_candidate_language(text, language:, reliable: true)
      allow(Marine::Llm::LanguageDetector).to receive(:new).and_call_original
      detector = instance_double(Marine::Llm::LanguageDetector,
                                 detect: { language: language, reliable: reliable, confidence: 1.0 })
      allow(Marine::Llm::LanguageDetector).to receive(:new).with(text).and_return(detector)
    end

    def call_stock(reply_language:, customer_request: 'apakah IMP-3 tersedia?')
      call(descriptor: in_stock_descriptor, fallback: in_stock_fallback,
           customer_request: customer_request, reply_language: reply_language)
    end

    it 'rejects an English candidate for an Indonesian customer (no English reply passes for an id request)' do
      # A natural English candidate for an id customer, so the language gate is what rejects it.
      candidate = 'Yes — IMP-3 is on hand right now!'
      stub_generation(message: candidate)
      stub_candidate_language(candidate, language: 'en')
      validator = stub_semantic(true)

      expect(call_stock(reply_language: 'id')).to be_nil
      # rejected deterministically BEFORE the semantic LLM call
      expect(validator).not_to have_received(:valid?)
    end

    it 'delivers a natural Indonesian candidate for an Indonesian customer' do
      candidate = 'Halo! Untuk IMP-3, saat ini tersedia ya.'
      stub_generation(message: candidate)
      stub_candidate_language(candidate, language: 'id')
      stub_semantic(true)

      expect(call_stock(reply_language: 'id')).to eq(candidate)
    end

    it 'keeps an English candidate for an English customer' do
      candidate = 'Yes — IMP-3 is on hand right now.'
      stub_generation(message: candidate)
      stub_candidate_language(candidate, language: 'en')
      stub_semantic(true)

      expect(call_stock(reply_language: 'en', customer_request: 'is IMP-3 in stock?')).to eq(candidate)
    end

    it 'rejects an Indonesian candidate for an English customer' do
      candidate = 'Ya, IMP-3 saat ini tersedia.'
      stub_generation(message: candidate)
      stub_candidate_language(candidate, language: 'id')
      stub_semantic(true)

      expect(call_stock(reply_language: 'en', customer_request: 'is IMP-3 in stock?')).to be_nil
    end

    it 'matches at the primary subtag so a regional variant is not a mismatch' do
      candidate = 'Ya, IMP-3 saat ini tersedia.'
      stub_generation(message: candidate)
      stub_candidate_language(candidate, language: 'id')
      stub_semantic(true)

      expect(call_stock(reply_language: 'id-id')).to eq(candidate)
    end

    it 'does not fire when no reply language is supplied (backward-compatible)' do
      candidate = 'Yes — IMP-3 is on hand right now!'
      stub_generation(message: candidate)
      # Detector would say en, but with no target the gate must not fire.
      stub_candidate_language(candidate, language: 'en')
      stub_semantic(true)

      expect(call_stock(reply_language: nil)).to eq(candidate)
    end

    # A stock candidate the LOCAL detector cannot classify (a very short availability line) is proven
    # via the provider — the same capability that produced the authoritative reply_language, which
    # classifies short text reliably. The chat stub answers the LANGUAGE_SCHEMA proof call and the
    # generation call distinctly so the real envelope-extraction path is exercised.
    def stub_generation_with_language_proof(reply:, proven:)
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      allow(llm).to receive(:chat) do |args|
        if args[:schema] == described_class::LANGUAGE_SCHEMA
          { ok: true, message: { language: proven }.to_json, error: nil }
        else
          { ok: true, message: reply_envelope(reply), error: nil }
        end
      end
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      llm
    end

    it 'delivers an INDETERMINABLE stock candidate only when the provider PROVES the target language' do
      # CLD3 cannot reliably classify a bare in-language availability line at its length; the provider
      # proves it is Indonesian, so it is delivered (a handoff on a KNOWN in-stock fact is avoided)
      # WITHOUT accepting an unproven candidate.
      candidate = 'Ya, IMP-3 tersedia.'
      stub_candidate_language(candidate, language: 'unknown', reliable: false)
      stub_generation_with_language_proof(reply: candidate, proven: 'id')
      validator = stub_semantic(true)

      expect(call_stock(reply_language: 'id')).to eq(candidate)
      expect(validator).to have_received(:valid?)
    end

    # RED for the prior `return stock` patch: it accepted EVERY indeterminable stock candidate, so a
    # wrong-language line CLD3 also cannot classify would ship. The provider proof rejects it.
    it 'rejects an INDETERMINABLE stock candidate the provider proves is a DIFFERENT language' do
      candidate = 'Yes, IMP-3 on hand.' # short English line CLD3 reads unreliably; provider proves en
      stub_candidate_language(candidate, language: 'unknown', reliable: false)
      stub_generation_with_language_proof(reply: candidate, proven: 'en')
      validator = stub_semantic(true)

      expect(call_stock(reply_language: 'id')).to be_nil
      expect(validator).not_to have_received(:valid?) # rejected before the semantic gate
    end

    it 'fails closed for an INDETERMINABLE stock candidate when the provider cannot prove the language' do
      candidate = 'Ya, IMP-3 tersedia.'
      stub_candidate_language(candidate, language: 'unknown', reliable: false)
      stub_generation_with_language_proof(reply: candidate, proven: 'unknown') # provider also cannot classify
      validator = stub_semantic(true)

      expect(call_stock(reply_language: 'id')).to be_nil
      expect(validator).not_to have_received(:valid?)
    end

    # CLD3 regularly reports genuine Indonesian as its confusable neighbour Malay ('ms') on a short
    # availability line, so a RELIABLY-different LOCAL read is not authoritative enough to force a handoff
    # on a KNOWN stock fact. For a STOCK reply the candidate's language is PROVEN via the provider (the
    # same capability that produced the target); a proven-target match is delivered.
    it 'delivers a STOCK candidate CLD3 reads as a reliably-different confusable language when the provider PROVES the target' do
      candidate = 'Ya, IMP-3 tersedia.'
      stub_candidate_language(candidate, language: 'ms', reliable: true) # CLD3 misreads id as ms
      stub_generation_with_language_proof(reply: candidate, proven: 'id') # provider proves it IS id
      validator = stub_semantic(true)

      expect(call_stock(reply_language: 'id')).to eq(candidate)
      expect(validator).to have_received(:valid?)
    end

    # Fail-closed is preserved: a genuine wrong-language reply (reliably-different local read that the
    # provider ALSO proves is a different language than the target) is rejected — the provider proof never
    # turns wrong-language output into a delivery.
    it 'rejects a STOCK candidate reliably-read as different when the provider proves a DIFFERENT language' do
      candidate = 'Yes, IMP-3 on hand.'
      stub_candidate_language(candidate, language: 'en', reliable: true)
      stub_generation_with_language_proof(reply: candidate, proven: 'en') # provider confirms genuine en
      validator = stub_semantic(true)

      expect(call_stock(reply_language: 'id')).to be_nil
      expect(validator).not_to have_received(:valid?) # rejected before the semantic gate
    end

    it 'fails closed for a NON-stock reply when the candidate language cannot be read reliably (no provider proof)' do
      # The indeterminable relaxation is stock-scoped: a rejected non-stock reply delivers its
      # same-language deterministic fallback (never a handoff), so it keeps the strict fail-closed floor.
      candidate = 'Tentang Impeller, varian mana yang Anda mau?'
      stub_candidate_language(candidate, language: 'unknown', reliable: false)
      llm = stub_generation(message: candidate)
      validator = stub_semantic(true)

      expect(call(descriptor: descriptor, fallback: fallback, reply_language: 'id')).to be_nil
      expect(validator).not_to have_received(:valid?)
      expect(llm).not_to have_received(:chat).with(hash_including(schema: described_class::LANGUAGE_SCHEMA))
    end

    it 'ignores a malformed reply-language code (gate off, not a crash)' do
      candidate = 'Yes — IMP-3 is on hand right now!'
      stub_generation(message: candidate)
      stub_candidate_language(candidate, language: 'en')
      stub_semantic(true)

      expect(call_stock(reply_language: 'not a code!!')).to eq(candidate)
    end
  end

  # The reused Phase-4 greeting policy is Indonesian-specific (Marine's business-hours courtesy); for
  # a KNOWN non-Indonesian customer an opening turn must neither ground nor leave an Indonesian
  # greeting, so the reply cannot become a language mismatch that would reject and fall back.
  describe 'target-language-aware opening greeting' do
    def capture_generation_system(reply_language:)
      captured = {}
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      allow(llm).to receive(:chat) do |args|
        captured.merge!(args)
        { ok: true, message: reply_envelope('About Impeller — which variant?'), error: nil }
      end
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      stub_semantic(true)
      call(opening: true, reply_language: reply_language)
      captured[:system]
    end

    it 'grounds the Indonesian time-of-day greeting for an Indonesian opening turn' do
      expect(capture_generation_system(reply_language: 'id')).to match(/Selamat (pagi|siang|sore|malam)/)
    end

    it 'keeps the Indonesian greeting when no target language is supplied (backward-compatible)' do
      expect(capture_generation_system(reply_language: nil)).to match(/Selamat (pagi|siang|sore|malam)/)
    end

    it 'does NOT impose the Indonesian greeting for a known non-Indonesian opening turn' do
      system = capture_generation_system(reply_language: 'en')
      expect(system).not_to match(/Selamat/)
      expect(system).to match(/customer's OWN language/i)
    end

    it 'strips a leaked Indonesian opening greeting from an English reply before the gates and delivers clean English' do
      # A natural English body carrying a leaked Indonesian opening greeting: after enforcement only the
      # English body remains, and once the gates pass it is delivered.
      stub_generation(message: 'Selamat pagi! Yes — IMP-3 is on hand right now.')
      detector = instance_double(Marine::Llm::LanguageDetector, detect: { language: 'en', reliable: true, confidence: 1.0 })
      allow(Marine::Llm::LanguageDetector).to receive(:new).and_call_original
      allow(Marine::Llm::LanguageDetector).to receive(:new).with('Yes — IMP-3 is on hand right now.').and_return(detector)
      stub_semantic(true)

      result = service.call(action: :reply, descriptor: { kind: :stock_available, variant_code: 'IMP-3' },
                            fallback: 'IMP-3 is currently in stock.', customer_request: 'is IMP-3 in stock?',
                            opening: true, reply_language: 'en')

      expect(result).to eq('Yes — IMP-3 is on hand right now.')
    end
  end

  # Generation must instruct the model to reply in the CUSTOMER's language, not the (English) Product
  # Reply's — the ambiguity that let availability replies come back in English for an id customer.
  it 'instructs the model to reply in the same language as the customer message, treating the English Product Reply as facts only' do
    captured = {}
    llm = instance_double(Marine::Llm::BaseService, configured?: true)
    allow(llm).to receive(:chat) do |args|
      captured.merge!(args)
      { ok: true, message: reply_envelope('About Impeller — which variant?'), error: nil }
    end
    allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
    stub_semantic(true)

    call

    expect(captured[:system]).to match(/same language as the customer/i)
    expect(captured[:system]).to match(/never switch to another language/i)
  end

  # The architectural correction: a pure stock reply is grounded on a STRUCTURED availability data block
  # (the already-validated variant identity + a binary in/out status) instead of the prewritten localized
  # fallback SENTENCE, so the provider is never handed a finished sentence to echo (the proven handoff root
  # cause). The deterministic fallback still judges the candidate in BOTH gates; a NON-stock reply is
  # unchanged and still grounds on the "Product Reply" sentence.
  describe 'structured stock generation context (no fallback prose)' do
    let(:in_stock_descriptor) { { kind: :stock_available, variant_code: 'IMP-3' } }
    let(:in_stock_fallback) { 'IMP-3 is currently in stock.' }
    let(:out_descriptor) { { kind: :stock_empty, variant_code: 'IMP-3' } }
    # An unavailable fallback deliberately carrying a QUANTITY ('0') and warehouse-ish prose that must
    # NEVER reach the generation prompt — only the binary status may.
    let(:out_fallback) { 'Sorry, IMP-3 is currently out of stock (0 remaining at the main warehouse).' }

    # Capture the GENERATION system prompt (REPLY_SCHEMA call), delivering a supplied dynamic candidate.
    def capture_stock_system(descriptor:, fallback:, reply:)
      captured = {}
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      allow(llm).to receive(:chat) do |args|
        captured.merge!(args) if args[:schema] == described_class::REPLY_SCHEMA
        { ok: true, message: reply_envelope(reply), error: nil }
      end
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      stub_semantic(true)
      service.call(action: :reply, descriptor: descriptor, fallback: fallback,
                   customer_request: 'is IMP-3 in stock?', opening: false, reply_language: nil)
      captured[:system]
    end

    # The Availability Data JSON object embedded in the system prompt, parsed for exact-shape assertions.
    def availability_data(system)
      JSON.parse(system[/\{"product".*?\}/])
    end

    it 'grounds an AVAILABLE stock generation on the exact identity + binary status, not the fallback prose' do
      system = capture_stock_system(descriptor: in_stock_descriptor, fallback: in_stock_fallback,
                                    reply: 'Yep — IMP-3 is on hand right now!')
      expect(system).to include('IMP-3')                       # exact public identity present
      expect(system).to include('"availability":"available"')  # binary status present as generic data
      expect(availability_data(system)).to eq('product' => 'IMP-3', 'availability' => 'available')
      # the prewritten fallback SENTENCE is never handed to the provider to echo
      expect(system).not_to include(in_stock_fallback)
      expect(system).not_to match(/Product Reply/)
    end

    it 'grounds an UNAVAILABLE stock generation on the binary status, leaking neither the fallback prose nor its quantity' do
      system = capture_stock_system(descriptor: out_descriptor, fallback: out_fallback,
                                    reply: 'Sorry, IMP-3 is not available right now.')
      expect(system).to include('"availability":"unavailable"')
      expect(availability_data(system)).to eq('product' => 'IMP-3', 'availability' => 'unavailable')
      # neither the fallback sentence, its quantity, nor its warehouse detail leaks into the prompt
      expect(system).not_to include(out_fallback)
      expect(system).not_to match(/warehouse|remaining/i)
      expect(availability_data(system).keys).to contain_exactly('product', 'availability') # no quantity/internal field
    end

    it 'still judges the stock candidate against the deterministic fallback in BOTH gates' do
      fp = instance_double(Marine::Catalog::ProductFactProtectionValidator, eligible?: true)
      fp_args = {}
      allow(fp).to receive(:accepts?) do |args|
        fp_args.merge!(args)
        true
      end
      allow(Marine::Catalog::ProductFactProtectionValidator).to receive(:new).and_return(fp)
      sem_args = {}
      validator = instance_double(Marine::Charge::FactPreservationValidator)
      allow(validator).to receive(:valid?) do |args|
        sem_args.merge!(args)
        true
      end
      allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(validator)
      stub_generation(message: 'Yep — IMP-3 is on hand right now!')

      service.call(action: :reply, descriptor: in_stock_descriptor, fallback: in_stock_fallback,
                   customer_request: 'is IMP-3 in stock?', opening: false)

      expect(fp_args[:fallback]).to eq(in_stock_fallback)         # deterministic gate judges against the fallback
      expect(sem_args[:approved_answer]).to eq(in_stock_fallback) # semantic gate's approved answer is the fallback
    end

    it 'leaves a NON-stock generation grounded on the Product Reply fallback (unchanged, no data block)' do
      captured = {}
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      allow(llm).to receive(:chat) do |args|
        captured.merge!(args)
        { ok: true, message: reply_envelope('About Impeller — which variant would you like?'), error: nil }
      end
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      stub_semantic(true)

      call # default parent_info (non-stock)

      expect(captured[:system]).to include("Product Reply:\n#{fallback}")
      expect(captured[:system]).not_to match(/Availability Data/)
    end

    it 'delivers a dynamically reworded AVAILABLE line (never the fallback sentence)' do
      stub_generation(message: 'Yep — IMP-3 is on hand right now!')
      stub_semantic(true)
      result = service.call(action: :reply, descriptor: in_stock_descriptor, fallback: in_stock_fallback,
                            customer_request: 'is IMP-3 in stock?', opening: false)
      expect(result).to eq('Yep — IMP-3 is on hand right now!')
      expect(result).not_to eq(in_stock_fallback)
    end

    it 'delivers a dynamically reworded UNAVAILABLE line (never the fallback sentence)' do
      stub_generation(message: 'Sorry, IMP-3 is not available at the moment.')
      stub_semantic(true)
      result = service.call(action: :reply, descriptor: out_descriptor, fallback: 'IMP-3 is currently out of stock.',
                            customer_request: 'is IMP-3 in stock?', opening: false)
      expect(result).to eq('Sorry, IMP-3 is not available at the moment.')
    end
  end

  # Stock natural-wording generation — a pure stock reply is generated dynamically by the configured
  # provider from the STRUCTURED availability data (identity + binary status), at a small bounded nonzero
  # temperature so the wording can vary. The delivered text is ALWAYS a provider-generated candidate that
  # cleared every gate; it is NEVER rejected merely for equalling or structurally matching the localized
  # fallback. Equality with the fallback is a harmless coincidence, not a safety boundary — the customer
  # explicitly accepts a concise reply that naturally coincides with the fallback — so a passing candidate
  # is delivered on the FIRST attempt. Retries are reserved for ACTUAL generation/gate failures (covered in
  # the block below); this scope is stock kinds only.
  describe 'stock natural-wording generation (dynamic, fallback-equality allowed)' do
    let(:in_stock_descriptor) { { kind: :stock_available, variant_code: 'IMP-3' } }
    let(:in_stock_fallback) { 'IMP-3 is currently in stock.' }
    let(:id_fallback) { 'IMP-3 saat ini tersedia.' }

    # Successive chat replies (envelope-wrapped), one consumed per generation attempt; the last repeats.
    def stub_generations(*messages)
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      responses = messages.map { |m| { ok: true, message: reply_envelope(m), error: nil } }
      allow(llm).to receive(:chat).and_return(*responses)
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      llm
    end

    it 'requests a stock reply at a small bounded nonzero temperature (not greedy 0.0)' do
      captured = {}
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      allow(llm).to receive(:chat) do |args|
        captured.merge!(args)
        { ok: true, message: reply_envelope('Sure — IMP-3 is on hand right now!'), error: nil }
      end
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      stub_semantic(true)

      call(descriptor: in_stock_descriptor, fallback: in_stock_fallback, customer_request: 'is IMP-3 in stock?')

      expect(captured[:temperature]).to be > 0.0
      expect(captured[:temperature]).to be <= 0.6
    end

    # The corrective fix: a provider-generated candidate that happens to equal the localized fallback is
    # DELIVERED once every gate passes — generation still happened, and equality is not rejection.
    it 'delivers a dynamically generated candidate identical to the fallback after all gates (equality is not rejection)' do
      llm = stub_generations(id_fallback) # provider output coincides with the localized fallback
      stub_semantic(true)

      result = service.call(action: :reply, descriptor: in_stock_descriptor, fallback: id_fallback,
                            customer_request: 'apakah IMP-3 tersedia?', opening: false)

      expect(result).to eq(id_fallback)
      expect(llm).to have_received(:chat).once # generation was called; a passing candidate is not retried
    end

    # English parity: a candidate reproducing the fallback's sentence structure verbatim is likewise
    # delivered — the anti-copy rejection is gone, so no dynamic candidate is dropped for resembling it.
    it 'delivers a candidate structurally matching the fallback once every gate passes (English)' do
      llm = stub_generations('Yes, IMP-3 is currently in stock.') # carries the fallback skeleton verbatim
      stub_semantic(true)

      expect(call(descriptor: in_stock_descriptor, fallback: in_stock_fallback,
                  customer_request: 'is IMP-3 in stock?')).to eq('Yes, IMP-3 is currently in stock.')
      expect(llm).to have_received(:chat).once
    end

    it 'delivers the reported Indonesian availability line "<code> saat ini tersedia" once the gates pass' do
      llm = stub_generations('IMP-3 saat ini tersedia.')
      stub_semantic(true)

      result = service.call(action: :reply, descriptor: in_stock_descriptor, fallback: id_fallback,
                            customer_request: 'apakah IMP-3 tersedia?', opening: false)
      expect(result).to eq('IMP-3 saat ini tersedia.')
      expect(llm).to have_received(:chat).once
    end

    it 'accepts a genuinely natural Indonesian candidate on the FIRST try (not a language phrase ban)' do
      llm = stub_generations('Selamat pagi! Stok IMP-3 masih ada kok.')
      stub_semantic(true)

      travel_to(Time.utc(2026, 7, 20, 2, 37)) do # 09:37 WIB -> pagi, so the opening greeting is not normalized
        result = service.call(action: :reply, descriptor: in_stock_descriptor, fallback: id_fallback,
                              customer_request: 'apakah IMP-3 tersedia?', opening: true)
        expect(result).to eq('Selamat pagi! Stok IMP-3 masih ada kok.')
      end
      expect(llm).to have_received(:chat).once
    end

    it 'delivers a non-stock reply identical to the fallback on a single attempt (scope is stock only)' do
      llm = stub_generations(fallback) # default parent_info: candidate identical to the fallback
      stub_semantic(true)

      expect(call).to eq(fallback)
      expect(llm).to have_received(:chat).once
    end

    # A genuinely WARM, framed reply that keeps the faithful availability phrase ("saat ini tersedia") is
    # delivered as-is on the first try.
    it 'accepts a warm, framed reply that keeps the faithful availability phrase' do
      warm = 'Selamat pagi! 😊 Ya, IMP-3 saat ini tersedia kok. Ada lagi yang bisa saya bantu?'
      llm = stub_generations(warm)
      stub_semantic(true)

      travel_to(Time.utc(2026, 7, 20, 2, 37)) do # 09:37 WIB -> pagi, so the opening greeting is not normalized
        result = service.call(action: :reply, descriptor: in_stock_descriptor, fallback: id_fallback,
                              customer_request: 'apakah IMP-3 tersedia?', opening: true)
        expect(result).to eq(warm)
      end
      expect(llm).to have_received(:chat).once
    end

    # A concise, directly generated one-sentence confirmation is delivered on the first try — no forced
    # greeting, no offer of further help, and no rejection for coinciding with the fallback wording.
    it 'accepts a concise, one-sentence availability confirmation with no greeting or help offer' do
      concise = 'Ya, IMP-3 tersedia saat ini.'
      llm = stub_generations(concise)
      stub_semantic(true)

      result = service.call(action: :reply, descriptor: in_stock_descriptor, fallback: id_fallback,
                            customer_request: 'apakah IMP-3 tersedia?', opening: false)
      expect(result).to eq(concise)
      expect(llm).to have_received(:chat).once
    end

    # Unavailable parity: a concise, one-sentence UNAVAILABLE confirmation is likewise delivered on the
    # first try.
    it 'accepts a concise, one-sentence UNAVAILABLE confirmation on the first try' do
      unavailable_fallback = 'Maaf, IMP-3 saat ini tidak tersedia.'
      concise = 'Maaf ya, IMP-3 tidak tersedia saat ini.'
      llm = stub_generations(concise)
      stub_semantic(true)

      result = service.call(action: :reply, descriptor: { kind: :stock_empty, variant_code: 'IMP-3' },
                            fallback: unavailable_fallback, customer_request: 'apakah IMP-3 tersedia?', opening: false)
      expect(result).to eq(concise)
      expect(llm).to have_received(:chat).once
    end

    it 'appends the stock warmth mandate to a stock generation only' do
      captured = {}
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      allow(llm).to receive(:chat) do |args|
        captured.merge!(args)
        { ok: true, message: reply_envelope('Yep! IMP-3 is on hand right now, happy to help!'), error: nil }
      end
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      stub_semantic(true)

      call(descriptor: in_stock_descriptor, fallback: in_stock_fallback, customer_request: 'is IMP-3 in stock?')
      expect(captured[:system]).to include(described_class::STOCK_WARMTH_INSTRUCTION)

      captured.clear
      call # default parent_info (non-stock)
      expect(captured[:system]).not_to include(described_class::STOCK_WARMTH_INSTRUCTION)
    end
  end

  # Second follow-up — bounded stock-retry across ALL non-accepted branches. The configured provider is
  # non-deterministic (an identical unavailable probe handed off on one run and delivered on the next), so
  # a pure stock reply spends the bounded MAX_STOCK_ATTEMPTS budget on a FRESH resample for EVERY
  # non-accepted candidate outcome (a malformed/blank or greeting-enforced-blank generation, a
  # deterministic fact/code rejection, a wrong/unreadable language, or a semantic rejection/uncertainty).
  # Each retry stays fully untrusted and is re-gated from scratch; two unsafe candidates still fail closed
  # to nil (the caller hands off) with no
  # deterministic/static fallback ever delivered. Non-stock replies keep their single attempt. Provider and
  # semantic-validator call counts are asserted EXACTLY so the budget is provably bounded.
  describe 'bounded stock retry across all non-accepted branches' do
    let(:in_stock_descriptor) { { kind: :stock_available, variant_code: 'IMP-3' } }
    let(:in_stock_fallback) { 'IMP-3 is currently in stock.' }
    let(:id_fallback) { 'IMP-3 saat ini tersedia.' }

    # Successive envelope-wrapped chat replies, one consumed per generation attempt; the last repeats.
    def stub_generations(*messages)
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      responses = messages.map { |m| { ok: true, message: reply_envelope(m), error: nil } }
      allow(llm).to receive(:chat).and_return(*responses)
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      llm
    end

    # Detector stub for EXACT candidate strings (call_original elsewhere so the real greeting policy is
    # unaffected), exercising the language gate without depending on CLD3 output.
    def stub_languages(map)
      allow(Marine::Llm::LanguageDetector).to receive(:new).and_call_original
      map.each do |text, language|
        detector = instance_double(Marine::Llm::LanguageDetector,
                                   detect: { language: language, reliable: true, confidence: 1.0 })
        allow(Marine::Llm::LanguageDetector).to receive(:new).with(text).and_return(detector)
      end
    end

    def stock_call(descriptor: in_stock_descriptor, fallback: in_stock_fallback,
                   customer_request: 'is IMP-3 in stock?', opening: true, reply_language: nil)
      service.call(action: :reply, descriptor: descriptor, fallback: fallback,
                   customer_request: customer_request, opening: opening, reply_language: reply_language)
    end

    # ---- malformed / blank generation ----
    it 'retries a malformed/blank generation, then delivers the second safe candidate' do
      llm = stub_generations('', 'Yep! We have IMP-3 on hand right now, happy to help.')
      validator = stub_semantic(true)

      expect(stock_call).to eq('Yep! We have IMP-3 on hand right now, happy to help.')
      expect(llm).to have_received(:chat).twice
      expect(validator).to have_received(:valid?).once # only the safe second candidate reaches the semantic gate
    end

    it 'fails closed to nil after two malformed generations (no fallback delivered)' do
      llm = stub_generations('', '')
      validator = stub_semantic(true)

      expect(stock_call).to be_nil
      expect(llm).to have_received(:chat).twice
      expect(validator).not_to have_received(:valid?)
    end

    # ---- greeting-enforced blank (follow-up greeting-only reply) ----
    it 'retries a greeting-enforced-blank candidate, then delivers the second safe candidate' do
      llm = stub_generations('Halo!', 'Sure — IMP-3 is on hand right now, glad to help.')
      validator = stub_semantic(true)

      expect(stock_call(opening: false)).to eq('Sure — IMP-3 is on hand right now, glad to help.')
      expect(llm).to have_received(:chat).twice
      expect(validator).to have_received(:valid?).once
    end

    # ---- deterministic fact rejection: extra quantity ----
    it 'retries an injected-quantity candidate, then delivers a clean second candidate' do
      llm = stub_generations('Yes, we currently have 24 of IMP-3 on hand.', # extra quantity -> deterministic reject
                             'Yes — IMP-3 is on hand right now, happy to help.')
      validator = stub_semantic(true)

      expect(stock_call).to eq('Yes — IMP-3 is on hand right now, happy to help.')
      expect(llm).to have_received(:chat).twice
      expect(validator).to have_received(:valid?).once # the rejected quantity candidate never reaches the semantic gate
    end

    it 'fails closed after two injected-quantity candidates, never reaching the semantic gate' do
      llm = stub_generations('Yes, we currently have 24 of IMP-3 on hand.',
                             'Sure, all 12 units of IMP-3 are ready.')
      validator = stub_semantic(true)

      expect(stock_call).to be_nil
      expect(llm).to have_received(:chat).twice
      expect(validator).not_to have_received(:valid?)
    end

    # ---- deterministic fact rejection: changed / dropped / extra code ----
    it 'retries a changed-code candidate, then delivers a code-preserving second candidate' do
      llm = stub_generations('Good news — IMP-4 is on hand right now.', # changed code -> deterministic reject
                             'Good news — IMP-3 is on hand right now, happy to help.')
      validator = stub_semantic(true)

      expect(stock_call).to eq('Good news — IMP-3 is on hand right now, happy to help.')
      expect(llm).to have_received(:chat).twice
      expect(validator).to have_received(:valid?).once
    end

    # ---- wrong / unreliable language ----
    it 'retries a wrong-language candidate, then delivers a correct-language second candidate' do
      wrong = 'Yes — IMP-3 is on hand right now.'
      right = 'IMP-3 saat ini tersedia ya, ada yang bisa dibantu?'
      # attempt 1 reads reliably 'en' and the provider PROVES 'en' (rejected before semantic); attempt 2
      # reads reliably 'id' matching the target, so it is delivered with no provider proof spent.
      llm = stub_generations_and_proofs([wrong, right], proofs: { wrong => 'en' })
      stub_languages(wrong => 'en', right => 'id')
      validator = stub_semantic(true)

      expect(stock_call(fallback: id_fallback, reply_language: 'id',
                        customer_request: 'apakah IMP-3 tersedia?', opening: false)).to eq(right)
      expect(llm).to have_received(:chat).with(hash_including(schema: described_class::REPLY_SCHEMA)).twice
      expect(llm).to have_received(:chat).with(hash_including(schema: described_class::LANGUAGE_SCHEMA)).once
      expect(validator).to have_received(:valid?).once # the wrong-language candidate is rejected before the semantic gate
    end

    it 'fails closed after two wrong-language candidates, never reaching the semantic gate' do
      wrong1 = 'Yes — IMP-3 is on hand right now.'
      wrong2 = 'Sure, IMP-3 is available right now.'
      # both read reliably 'en' and the provider PROVES 'en' each time, so both fail closed before the
      # semantic gate — the reliably-different provider proof never accepts a genuine wrong-language reply.
      llm = stub_generations_and_proofs([wrong1, wrong2], proofs: { wrong1 => 'en', wrong2 => 'en' })
      stub_languages(wrong1 => 'en', wrong2 => 'en')
      validator = stub_semantic(true)

      expect(stock_call(fallback: id_fallback, reply_language: 'id',
                        customer_request: 'apakah IMP-3 tersedia?', opening: false)).to be_nil
      expect(llm).to have_received(:chat).with(hash_including(schema: described_class::REPLY_SCHEMA)).twice
      expect(llm).to have_received(:chat).with(hash_including(schema: described_class::LANGUAGE_SCHEMA)).twice
      expect(validator).not_to have_received(:valid?)
    end

    # ---- semantic rejection / uncertainty (a fresh verdict is required on each attempt) ----
    it 'retries a semantically rejected candidate, then delivers a second candidate the judge accepts' do
      first = 'IMP-3 might be in stock, ready for next-week delivery.' # semantically unsafe: uncertainty + lead time
      second = 'Yes — IMP-3 is on hand right now, happy to help.'
      llm = stub_generations(first, second)
      validator = instance_double(Marine::Charge::FactPreservationValidator)
      allow(validator).to receive(:valid?).and_return(false, true)
      allow(Marine::Charge::FactPreservationValidator).to receive(:new).and_return(validator)

      expect(stock_call).to eq(second)
      expect(llm).to have_received(:chat).twice
      expect(validator).to have_received(:valid?).twice # each attempt gets its OWN fresh verdict; uncertainty is never reused
    end

    it 'fails closed after two semantically rejected candidates (uncertainty is never turned into acceptance)' do
      llm = stub_generations('IMP-3 might be in stock, maybe.', 'Possibly IMP-3 is around somewhere.')
      validator = stub_semantic(false)

      expect(stock_call).to be_nil
      expect(llm).to have_received(:chat).twice
      expect(validator).to have_received(:valid?).twice
    end

    # ---- unavailable (stock_empty) parity: the reported intermittent kind ----
    it 'retries an unavailable stock reply and delivers the second dynamic candidate, code preserved' do
      second = 'Sayang sekali, IMP-3 sedang tidak tersedia saat ini.'
      llm = stub_generations('', second) # transient malformed generation, then a valid dynamic unavailable answer
      stub_languages(second => 'id')
      stub_semantic(true)

      result = service.call(action: :reply, descriptor: { kind: :stock_empty, variant_code: 'IMP-3' },
                            fallback: 'Maaf, IMP-3 saat ini tidak tersedia.', reply_language: 'id',
                            customer_request: 'apakah IMP-3 tersedia?', opening: false)
      expect(result).to eq(second)
      expect(result).to include('IMP-3') # exact code preserved on the unavailable outcome
      expect(llm).to have_received(:chat).twice
    end

    # ---- retry nudge is generic; never leaks the rejected candidate ----
    it 'sends the generic corrective nudge (never the rejected text) on a retry' do
      first = 'Yes, we currently have 24 of IMP-3 on hand.' # deterministic reject (extra quantity)
      second = 'Yes — IMP-3 is on hand right now, happy to help.'
      systems = []
      replies = [reply_envelope(first), reply_envelope(second)]
      idx = 0
      llm = instance_double(Marine::Llm::BaseService, configured?: true)
      allow(llm).to receive(:chat) do |args|
        systems << args[:system]
        reply = replies[idx]
        idx += 1
        { ok: true, message: reply, error: nil }
      end
      allow(Marine::Llm::BaseService).to receive(:new).and_return(llm)
      stub_semantic(true)

      # Fixed time so the opening-turn greeting timestamp can never coincidentally contain the rejected
      # candidate's digits ('24'), keeping the no-leak assertion below about content, not the wall clock.
      travel_to(Time.utc(2026, 7, 20, 2, 37)) { stock_call }

      expect(systems.first).not_to include(described_class::CORRECTIVE_NUDGE)
      expect(systems.last).to include(described_class::CORRECTIVE_NUDGE)
      expect(systems.last).not_to include('24') # the rejected candidate's content never leaks into the retry prompt
      # the corrective nudge names no product, language, phrase, or example
      expect(described_class::CORRECTIVE_NUDGE).not_to match(/IMP-3|SR-20|tersedia|in stock/i)
    end

    # ---- non-stock is UNCHANGED: a rejection is a SINGLE attempt, no retry ----
    it 'does NOT retry a non-stock reply on semantic rejection (single attempt, scope is stock only)' do
      llm = stub_generations('About Impeller — which variant would you like?')
      validator = stub_semantic(false)

      expect(call).to be_nil # default parent_info descriptor (non-stock)
      expect(llm).to have_received(:chat).once
      expect(validator).to have_received(:valid?).once
    end
  end
end
