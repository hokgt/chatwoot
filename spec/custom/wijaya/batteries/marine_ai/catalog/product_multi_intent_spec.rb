# frozen_string_literal: true

require 'rails_helper'

# D6 — supported multi-intent handling. A single customer turn may carry an ordered, bounded set of
# supported intents (at minimum price+stock). The orchestrator resolves entity/family/variant ONCE
# and assembles a COMPOSITE reply descriptor from the existing price/stock descriptors, so one turn
# yields one reply carrying BOTH authorized outcomes without a second delivery or a downgrade to
# handoff. These specs exercise the decision layer (with doubles), the renderer/presenter wording,
# the deterministic fact-protection gate over the composite, and the bounded flow persistence that
# lets a clarification later fulfill the still-valid pair.
RSpec.describe 'Marine multi-intent (D6)' do
  describe Marine::Catalog::ProductQueryOrchestrator do
    subject(:orchestrator) do
      described_class.new(
        repositories: { family: family_repository, variant: variant_repository, price: price_repository, stock: stock_repository },
        variant_resolver: variant_resolver
      )
    end

    let(:family_repository) { instance_double(Marine::Catalog::ProductFamilyRepository) }
    let(:variant_repository) { instance_double(Marine::Catalog::VariantRepository) }
    let(:price_repository) { instance_double(Marine::Catalog::PriceRepository) }
    let(:stock_repository) { instance_double(Marine::Catalog::StockRepository) }
    let(:variant_resolver) { instance_double(Marine::Catalog::VariantResolver) }
    let(:available_price) { { status: :available, price_list_rate: '125.50', currency: 'USD', uom: 'Nos' } }
    let(:price_part) { { kind: :price_available, variant_code: 'CHILD-1', price_list_rate: '125.50', currency: 'USD', uom: 'Nos' } }
    # The stock leg now carries the SAME validated variant code as the price leg (the composite is one
    # variant); the fact-protection gate collapses the repeated code rather than rejecting it.
    let(:stock_part) { { kind: :stock_available, variant_code: 'CHILD-1' } }

    before do
      allow(family_repository).to receive(:resolve_exact).and_return(code: 'FAM-1', name: 'Impeller')
      allow(family_repository).to receive(:active_candidates).and_return([])
      allow(variant_repository).to receive(:attribute_names).and_return(%w[Size])
      allow(variant_repository).to receive(:resolve_child).and_return(nil)
      allow(variant_resolver).to receive(:resolve).and_return(status: :resolved, code: 'CHILD-1')
      allow(price_repository).to receive(:price_for).with('CHILD-1').and_return(available_price)
      allow(stock_repository).to receive(:status_for).with('CHILD-1').and_return(:available)
    end

    def intent(overrides = {})
      {
        product_related: true, intent: 'price', requested_intents: %w[price stock],
        family_mention: 'Impeller', explicit_child_code: 'CHILD-1', attribute_candidates: [],
        requires_exact_variant: true, clarification_reply: nil, family_changed: false, intent_changed: false,
        multiple_numeric_candidates: false, quantity_inquiry: false, unsupported_request: nil,
        confidence: 'high', customer_language: nil, reason: 'extracted'
      }.merge(overrides)
    end

    def active_flow(overrides = {})
      {
        'version' => 2, 'flow_id' => 'flow-1', 'status' => 'active',
        'expires_at' => '2999-01-01T00:00:00Z', 'expected_attributes' => [],
        'validated_family' => 'FAM-1', 'current_intent' => 'price'
      }.merge(overrides)
    end

    it 'assembles ONE composite reply with both price and stock for a same-turn price+stock request' do
      plan = orchestrator.plan_for_intent(intent: intent(requested_intents: %w[price stock]), flow: nil)

      expect(plan[:action]).to eq(:reply)
      expect(plan[:reply][:kind]).to eq(:composite)
      expect(plan[:reply][:parts]).to eq([price_part, stock_part])
      expect(plan[:state][:changes]).to include('validated_variant' => 'CHILD-1', 'current_intent' => 'price')
    end

    it 'produces the SAME composite for stock+price ordering (canonical, LLM-order independent)' do
      plan = orchestrator.plan_for_intent(intent: intent(intent: 'stock', requested_intents: %w[stock price]), flow: nil)

      expect(plan[:reply][:kind]).to eq(:composite)
      expect(plan[:reply][:parts]).to eq([price_part, stock_part])
    end

    it 'resolves family + variant exactly once for the shared request' do
      orchestrator.plan_for_intent(intent: intent(requested_intents: %w[price stock]), flow: nil)

      expect(family_repository).to have_received(:resolve_exact).once
      expect(variant_resolver).to have_received(:resolve).once
      expect(price_repository).to have_received(:price_for).with('CHILD-1').once
      expect(stock_repository).to have_received(:status_for).with('CHILD-1').once
    end

    it 'dedupes repeated labels into a single composite (no duplicated delivery of a fact)' do
      plan = orchestrator.plan_for_intent(intent: intent(requested_intents: %w[price price stock stock]), flow: nil)

      expect(plan[:reply][:parts]).to eq([price_part, stock_part])
    end

    it 'collapses stock across warehouses to a binary availability status and never exposes a quantity' do
      allow(stock_repository).to receive(:status_for).with('CHILD-1').and_return(:available)

      plan = orchestrator.plan_for_intent(intent: intent(requested_intents: %w[price stock]), flow: nil)

      stock = plan[:reply][:parts].last
      # Binary status + the validated variant code ONLY — no numeric quantity or warehouse detail.
      expect(stock).to eq(kind: :stock_available, variant_code: 'CHILD-1')
      expect(stock.keys).to eq(%i[kind variant_code])
    end

    it 'still yields a composite when price is factually unavailable (both outcomes reported)' do
      allow(price_repository).to receive(:price_for).with('CHILD-1').and_return(status: :unavailable)

      plan = orchestrator.plan_for_intent(intent: intent(requested_intents: %w[price stock]), flow: nil)

      expect(plan[:reply][:parts]).to eq([{ kind: :price_unavailable }, stock_part])
    end

    it 'reports empty stock alongside an available price' do
      allow(stock_repository).to receive(:status_for).with('CHILD-1').and_return(:empty)

      plan = orchestrator.plan_for_intent(intent: intent(requested_intents: %w[price stock]), flow: nil)

      expect(plan[:reply][:parts]).to eq([price_part, { kind: :stock_empty, variant_code: 'CHILD-1' }])
    end

    it 'fails closed to a single handoff (never a partial answer) when the price conflicts' do
      allow(price_repository).to receive(:price_for).with('CHILD-1').and_return(status: :conflict)

      plan = orchestrator.plan_for_intent(intent: intent(requested_intents: %w[price stock]), flow: nil)

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply]).to eq(kind: :price_conflict)
    end

    it 'fails closed to a single handoff when the stock repository is unavailable' do
      allow(stock_repository).to receive(:status_for).with('CHILD-1').and_raise(Marine::Catalog::Errors::CatalogUnavailableError)

      plan = orchestrator.plan_for_intent(intent: intent(requested_intents: %w[price stock]), flow: nil)

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply]).to eq(kind: :catalog_unavailable)
    end

    it 'preserves the exact-quantity handoff precedence when the pair also asks for an exact count' do
      plan = orchestrator.plan_for_intent(
        intent: intent(requested_intents: %w[price stock], quantity_inquiry: true), flow: nil
      )

      expect(plan[:action]).to eq(:handoff)
      expect(plan[:reply]).to eq(kind: :unsupported)
      expect(plan[:handoff_category]).to eq('exact_quantity')
      # No fact is partially exposed: the reply carries neither a price part nor a stock part.
      expect(plan[:reply]).not_to have_key(:parts)
    end

    it 'clarifies once for the shared request when the variant is missing' do
      allow(variant_resolver).to receive(:resolve).and_return(status: :unresolved, reason: :missing)

      plan = orchestrator.plan_for_intent(
        intent: intent(requested_intents: %w[price stock], explicit_child_code: 'NOPE'),
        flow: active_flow('catalog_sent' => true)
      )

      expect(plan[:action]).to eq(:clarify_variant)
      # The bounded pair is persisted so the follow-up can fulfill both still-valid intents.
      expect(plan[:state][:changes]).to include('requested_intents' => %w[price stock])
    end

    it 'fulfills BOTH still-valid intents on a bare follow-up after a variant clarification' do
      # Follow-up is a bare code turn: the extractor cannot re-derive the pair, so it is inherited
      # from the securely persisted, bounded flow field.
      flow = active_flow('requested_intents' => %w[price stock], 'validated_variant' => nil,
                         'current_intent' => 'price', 'expected_attributes' => %w[Size])
      bare = intent(intent: 'unknown', requested_intents: nil, family_mention: nil,
                    explicit_child_code: 'CHILD-1', requires_exact_variant: false)

      plan = orchestrator.plan_for_intent(intent: bare, flow: flow)

      expect(plan[:reply][:kind]).to eq(:composite)
      expect(plan[:reply][:parts]).to eq([price_part, stock_part])
      # Validated progress clears the pending pair so a later bare turn does not re-fulfill it.
      expect(plan[:state][:changes]).to include('requested_intents' => nil)
    end

    it 'does NOT revive a stale pending pair when the follow-up states a new single intent' do
      flow = active_flow('requested_intents' => %w[price stock], 'validated_variant' => nil,
                         'current_intent' => 'price', 'expected_attributes' => %w[Size])
      # The follow-up genuinely asks only for price: latest stated intent replaces the pending pair.
      follow = intent(intent: 'price', requested_intents: %w[price], explicit_child_code: 'CHILD-1',
                      requires_exact_variant: true)

      plan = orchestrator.plan_for_intent(intent: follow, flow: flow)

      expect(plan[:reply]).to eq(price_part)
    end

    it 'leaves an ordinary single-intent price reply unchanged (scalar backwards compatibility)' do
      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'price', requested_intents: %w[price]), flow: nil
      )

      expect(plan[:reply]).to eq(price_part)
    end

    it 'leaves an ordinary single-intent stock reply unchanged when no array is supplied' do
      plan = orchestrator.plan_for_intent(
        intent: intent(intent: 'stock', requested_intents: nil), flow: nil
      )

      expect(plan[:reply]).to eq(stock_part)
    end
  end

  describe Marine::Catalog::ReplyRenderer do
    let(:price_desc) { described_class.new.price_available({ price_list_rate: '9.00', currency: 'USD', uom: 'Nos' }, 'C-1') }
    let(:stock_desc) { described_class.new.stock_available('C-1') }

    it 'builds a frozen composite descriptor holding the ordered child descriptors' do
      composite = described_class.new.composite([price_desc, stock_desc])

      expect(composite[:kind]).to eq(:composite)
      expect(composite[:parts]).to eq([price_desc, stock_desc])
      expect(composite).to be_frozen
      expect(composite[:parts]).to be_frozen
    end
  end

  describe Marine::Catalog::ReplyPresenter do
    subject(:presenter) { described_class.new }

    let(:renderer) { Marine::Catalog::ReplyRenderer.new }
    let(:price_desc) { renderer.price_available({ price_list_rate: '125.50', currency: 'USD', uom: 'Nos' }, 'CHILD-1') }

    def composite_plan(parts)
      { action: :reply, reply: renderer.composite(parts), state: { operation: :none, changes: {} } }
    end

    it 'names the shared variant code once and refers back to it in the stock clause (one code occurrence)' do
      text = presenter.reply_text(composite_plan([price_desc, renderer.stock_available('CHILD-1')]))

      expect(text).to eq('The price for CHILD-1 is USD 125.50 per Nos. It is currently in stock.')
      expect(text.scan('CHILD-1').length).to eq(1)
    end

    it 'renders price + out-of-stock in one reply, naming the code once' do
      text = presenter.reply_text(composite_plan([price_desc, renderer.stock_empty('CHILD-1')]))

      expect(text).to eq("The price for CHILD-1 is USD 125.50 per Nos. I'm sorry, it is currently out of stock.")
      expect(text.scan('CHILD-1').length).to eq(1)
    end

    it 'falls back to the per-part join (each leg naming its own code) for a conflicting-code composite' do
      # A conflicting-code composite is not the canonical same-variant shape, so the referential
      # rendering is skipped and the fail-closed join names each leg's own validated code. The
      # fact-protection gate independently marks such a composite ineligible, so this exact
      # deterministic text is delivered rather than a naturalized rephrase.
      text = presenter.reply_text(composite_plan([price_desc, renderer.stock_available('OTHER-9')]))

      expect(text).to eq('The price for CHILD-1 is USD 125.50 per Nos. OTHER-9 is currently in stock.')
    end
  end

  describe Marine::Catalog::ProductFactProtectionValidator do
    subject(:validator) { described_class.new }

    let(:renderer) { Marine::Catalog::ReplyRenderer.new }
    let(:price_desc) { renderer.price_available({ price_list_rate: '125.50', currency: 'USD', uom: 'Nos' }, 'CHILD-1') }
    let(:composite) { renderer.composite([price_desc, renderer.stock_available('CHILD-1')]) }
    # The canonical composite fallback names the shared code ONCE (price clause) and refers back to it
    # in the stock clause, so the token inventory admits a natural one-code candidate.
    let(:fallback) { 'The price for CHILD-1 is USD 125.50 per Nos. It is currently in stock.' }

    it 'is eligible for a well-formed price+stock composite (same variant) under the reply action' do
      expect(validator.eligible?(action: :reply, descriptor: composite)).to be(true)
    end

    it 'accepts a natural rephrase that names the exact code once and preserves every price + stock fact' do
      candidate = 'CHILD-1 is priced at USD 125.50 per Nos, and it is currently in stock.'

      expect(validator.accepts?(action: :reply, descriptor: composite, fallback: fallback, candidate: candidate)).to be(true)
    end

    it 'rejects a candidate that drops or alters a protected price fact' do
      candidate = 'CHILD-1 is priced at USD 130.00 per Nos, and it is currently in stock.'

      expect(validator.accepts?(action: :reply, descriptor: composite, fallback: fallback, candidate: candidate)).to be(false)
    end

    it 'rejects a candidate that changes, drops, or adds the shared variant code' do
      changed = 'The price for CHILD-2 is USD 125.50 per Nos, and it is currently in stock.'
      dropped = 'The price is USD 125.50 per Nos, and it is currently in stock.'
      added = 'The price for CHILD-1 is USD 125.50 per Nos, and CHILD-9 is currently in stock.'

      expect(validator.accepts?(action: :reply, descriptor: composite, fallback: fallback, candidate: changed)).to be(false)
      expect(validator.accepts?(action: :reply, descriptor: composite, fallback: fallback, candidate: dropped)).to be(false)
      expect(validator.accepts?(action: :reply, descriptor: composite, fallback: fallback, candidate: added)).to be(false)
    end

    it 'rejects a composite candidate that injects a quantity number (fails closed)' do
      candidate = 'CHILD-1 is priced at USD 125.50 per Nos, and we have 12 of it in stock.'

      expect(validator.accepts?(action: :reply, descriptor: composite, fallback: fallback, candidate: candidate)).to be(false)
    end

    it 'collapses the SAME variant code repeated across the price and stock legs (still eligible)' do
      # Both legs reference CHILD-1; the shared code is one protected value, not an ambiguous duplicate.
      expect(validator.send(:protected_values, composite)).to eq(%w[CHILD-1 USD 125.50 Nos])
    end

    it 'fails closed on a composite whose legs carry CONFLICTING variant codes' do
      conflicting = renderer.composite([price_desc, renderer.stock_available('OTHER-9')])

      expect(validator.eligible?(action: :reply, descriptor: conflicting)).to be(false)
    end

    it 'is ineligible when a part is not a naturalizable kind (price unavailable), so wording is skipped' do
      other = renderer.composite([renderer.price_unavailable, renderer.stock_available('CHILD-1')])

      expect(validator.eligible?(action: :reply, descriptor: other)).to be(false)
    end
  end

  describe Marine::Catalog::ProductFlowStateStore do
    # Reloaded so the record is clean before row-locking (the factory leaves display_id dirty).
    let(:conversation) { create(:conversation).reload }
    let(:store) { described_class.new(conversation: conversation) }

    it 'persists a bounded, canonical requested_intents pair and reads it back' do
      store.start!('validated_family' => 'FAM-1', 'current_intent' => 'price', 'requested_intents' => %w[stock price])

      expect(store.current['requested_intents']).to eq(%w[price stock])
    end

    it 'drops forged / unsupported requested_intents entries on read (fail closed)' do
      store.start!('validated_family' => 'FAM-1', 'requested_intents' => %w[price wire_funds stock])

      expect(store.current['requested_intents']).to eq(%w[price stock])
    end

    it 'omits requested_intents entirely when none are supported' do
      store.start!('validated_family' => 'FAM-1', 'requested_intents' => %w[nonsense])

      expect(store.current).not_to have_key('requested_intents')
    end

    it 'survives the signed Playground token round-trip (state persists across turns)' do
      account = conversation.account
      assistant = create(:marine_assistant, account: account)
      token = Marine::Catalog::PlaygroundStateToken.new(account: account, assistant: assistant)
      snapshot = described_class.new(conversation: nil).apply_snapshot(
        nil, operation: :start, changes: { 'validated_family' => 'FAM-1', 'requested_intents' => %w[price stock] }
      )

      decoded = described_class.new(conversation: nil).normalize_snapshot(token.decode(token.encode(snapshot)))

      expect(decoded['requested_intents']).to eq(%w[price stock])
    end
  end
end
