# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::ProductFlowStateStore do
  subject(:store) { described_class.new(conversation: conversation, clock: clock, id_generator: id_generator) }

  # Reloaded so the record is clean before row-locking (the factory leaves
  # display_id dirty in memory); a real caller row-locks a DB-loaded conversation.
  let(:conversation) { create(:conversation).reload }
  # A mutable clock holder so examples can deterministically advance time.
  let(:clock_state) { { now: Time.zone.parse('2026-01-01T00:00:00Z') } }
  let(:clock) { -> { clock_state[:now] } }
  let(:id_generator) { -> { 'flow-fixed-id' } }

  def advance(seconds)
    clock_state[:now] += seconds
  end

  describe 'namespace' do
    it 'writes state under exactly additional_attributes.wijaya_marine_ai.product_flow_v1' do
      store.start!(current_intent: 'price')

      attributes = conversation.reload.additional_attributes
      expect(attributes.keys).to eq(['wijaya_marine_ai'])
      expect(attributes['wijaya_marine_ai'].keys).to eq(['product_flow_v1'])
      expect(attributes['wijaya_marine_ai']['product_flow_v1']).to include('flow_id' => 'flow-fixed-id')
    end
  end

  describe 'sibling preservation' do
    it 'preserves every unrelated top-level key' do
      conversation.update!(additional_attributes: { 'referer' => 'https://example.com', 'browser' => { 'name' => 'x' } })

      store.start!(current_intent: 'price')

      attributes = conversation.reload.additional_attributes
      expect(attributes['referer']).to eq('https://example.com')
      expect(attributes['browser']).to eq('name' => 'x')
    end

    it 'preserves every sibling under wijaya_marine_ai' do
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'other_feature_v1' => { 'keep' => true } } })

      store.start!(current_intent: 'price')

      feature = conversation.reload.additional_attributes['wijaya_marine_ai']
      expect(feature['other_feature_v1']).to eq('keep' => true)
      expect(feature['product_flow_v1']).to be_present
    end
  end

  describe 'version semantics' do
    it 'starts a fresh flow at version 1 and increments on each mutation' do
      expect(store.start!(current_intent: 'price')['version']).to eq(1)
      expect(store.update!(validated_family: 'Bearings')['version']).to eq(2)
      expect(store.update!(validated_variant: 'B-100')['version']).to eq(3)
    end

    it 'ignores a caller-supplied version (the store owns it)' do
      expect(store.start!(version: 99)['version']).to eq(1)
    end
  end

  describe 'allowlisting and normalization' do
    it 'drops raw stock/quantity/price/error/LLM keys and keeps only allowlisted fields' do
      flow = store.start!(
        current_intent: 'stock',
        validated_family: 'Bearings',
        actual_qty: 42,
        quantity: 7,
        price: 199.5,
        raw_error: 'PG::Error boom',
        llm_response: { 'text' => 'secret' },
        sql: 'SELECT * FROM items'
      )

      expect(flow.keys).to contain_exactly(
        'version', 'flow_id', 'status', 'expires_at', 'expected_attributes',
        'original_intent', 'current_intent', 'validated_family'
      )
      expect(flow.to_json).not_to match(/actual_qty|quantity|price|raw_error|llm_response|PG::Error|SELECT/)
    end

    it 'normalizes types and bounds fields' do
      flow = store.start!(
        origin_message_id: '55',
        catalog_sent: 'true',
        expected_attributes: ['size', 'size', 'color', 123],
        status: 'completed'
      )

      expect(flow['origin_message_id']).to eq(55)
      expect(flow['catalog_sent']).to be(true)
      expect(flow['expected_attributes']).to eq(%w[size color 123])
      expect(flow['status']).to eq('completed')
    end

    it 'coerces an unknown status back to active' do
      expect(store.start!(status: 'haxx')['status']).to eq('active')
    end

    it 'normalizes an unknown caller status on update! while keeping a valid one' do
      store.start!(current_intent: 'price')

      expect(store.update!(status: 'haxx')['status']).to eq('active')
      expect(store.update!(status: 'completed')['status']).to eq('completed')
    end
  end

  describe 'original and current intent' do
    it 'start! seeds original_intent and current_intent from the caller intent' do
      flow = store.start!(current_intent: 'price')

      expect(flow['original_intent']).to eq('price')
      expect(flow['current_intent']).to eq('price')
    end

    it 'start! seeds both intents from original_intent when only original is supplied' do
      flow = store.start!(original_intent: 'price')

      expect(flow['original_intent']).to eq('price')
      expect(flow['current_intent']).to eq('price')
    end

    it 'start! normalizes a conflicting original/current pair so current_intent seeds both' do
      flow = store.start!(original_intent: 'price', current_intent: 'stock')

      expect(flow['original_intent']).to eq('stock')
      expect(flow['current_intent']).to eq('stock')
    end

    it 'update! changes current_intent but preserves the immutable original_intent' do
      store.start!(current_intent: 'price')

      updated = store.update!(current_intent: 'stock')

      expect(updated['current_intent']).to eq('stock')
      expect(updated['original_intent']).to eq('price')
    end

    it 'update! cannot overwrite original_intent' do
      store.start!(current_intent: 'price')

      updated = store.update!(original_intent: 'hacked', current_intent: 'stock')

      expect(updated['original_intent']).to eq('price')
      expect(updated['current_intent']).to eq('stock')
    end

    it 'a fresh start! establishes a new original/current pair over an existing flow' do
      store.start!(current_intent: 'price')
      store.update!(current_intent: 'stock')

      fresh = store.start!(current_intent: 'lead_time')

      expect(fresh['version']).to eq(1)
      expect(fresh['original_intent']).to eq('lead_time')
      expect(fresh['current_intent']).to eq('lead_time')
    end

    it 'keeps intent values allowlisted and bounded, seeding both intents alike' do
      flow = store.start!(current_intent: "  #{'a' * 400}  ")

      expect(flow['current_intent'].length).to eq(described_class::MAX_STRING_LENGTH)
      expect(flow['original_intent']).to eq(flow['current_intent'])
    end

    it 'drops a legacy singular intent key without migrating it into original/current' do
      # A persisted flow with a valid lifecycle but only the old singular `intent`
      # key: `intent` is not allowlisted, so it is dropped like any unknown key.
      # No silent migration into original_intent/current_intent.
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'product_flow_v1' => {
                             'version' => 3, 'flow_id' => 'legacy-id', 'status' => 'active',
                             'expires_at' => (clock_state[:now] + 3600).iso8601, 'intent' => 'price'
                           } } })

      flow = store.current

      expect(flow['version']).to eq(3)
      expect(flow).not_to have_key('intent')
      expect(flow).not_to have_key('original_intent')
      expect(flow).not_to have_key('current_intent')
    end
  end

  describe 'malformed reset isolation' do
    it 'resets only product_flow_v1 while preserving siblings' do
      conversation.update!(
        additional_attributes: {
          'top' => 'keep',
          'wijaya_marine_ai' => { 'sibling_v1' => { 'x' => 1 }, 'product_flow_v1' => 'corrupt-not-a-hash' }
        }
      )

      flow = store.update!(current_intent: 'price')

      expect(flow['version']).to eq(1)
      expect(flow['current_intent']).to eq('price')
      expect(flow['original_intent']).to eq('price') # a reset opens a fresh intent pair
      attributes = conversation.reload.additional_attributes
      expect(attributes['top']).to eq('keep')
      expect(attributes['wijaya_marine_ai']['sibling_v1']).to eq('x' => 1)
    end

    it 'reads nil for a malformed current flow' do
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'product_flow_v1' => 'garbage' } })

      expect(store.current).to be_nil
    end
  end

  describe 'persisted-read validation (never fabricates identity/lifecycle)' do
    # A counting id_generator so we can prove reads never mint an id.
    let(:id_calls) { { count: 0 } }
    let(:id_generator) do
      lambda do
        id_calls[:count] += 1
        "gen-#{id_calls[:count]}"
      end
    end

    def write_flow(value)
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'product_flow_v1' => value } })
    end

    it 'reads nil for an empty hash across repeated reads and never invokes the id generator' do
      write_flow({})

      3.times { expect(store.current).to be_nil }
      expect(id_calls[:count]).to eq(0)
    end

    it 'reads nil for a partial hash missing a required lifecycle field and never invokes the id generator' do
      write_flow('intent' => 'price', 'version' => 2) # no flow_id / status / expires_at

      2.times { expect(store.current).to be_nil }
      expect(id_calls[:count]).to eq(0)
    end

    it 'treats a persisted flow with an unknown lifecycle status as malformed and resets it to fresh v1' do
      write_flow(
        'version' => 5, 'flow_id' => 'persisted-id', 'status' => 'haxx',
        'expires_at' => (Time.zone.parse('2026-01-01T00:00:00Z') + 3600).iso8601
      )

      expect(store.current).to be_nil
      expect(id_calls[:count]).to eq(0)

      flow = store.update!(current_intent: 'price')
      expect(flow['version']).to eq(1)
      expect(flow['status']).to eq('active')
      expect(flow['flow_id']).to eq('gen-1')
    end

    it 'update! resets a malformed persisted hash to a fresh version-1 flow with a generated id, preserving siblings' do
      conversation.update!(
        additional_attributes: {
          'top' => 'keep',
          'wijaya_marine_ai' => { 'sibling_v1' => { 'x' => 1 }, 'product_flow_v1' => { 'intent' => 'price' } }
        }
      )

      flow = store.update!(validated_family: 'Bearings')

      expect(flow['version']).to eq(1)
      expect(flow['flow_id']).to eq('gen-1')
      expect(flow['validated_family']).to eq('Bearings')
      attributes = conversation.reload.additional_attributes
      expect(attributes['top']).to eq('keep')
      expect(attributes['wijaya_marine_ai']['sibling_v1']).to eq('x' => 1)
    end

    it 'keeps a valid persisted flow readable and increments deterministically without regenerating its id' do
      store.start!(current_intent: 'price') # valid v1 persisted; id generated exactly once

      expect(store.current['version']).to eq(1)
      id_before = store.current['flow_id']

      updated = store.update!(validated_variant: 'B-100')

      expect(updated['version']).to eq(2)
      expect(updated['flow_id']).to eq(id_before)
      expect(store.current['version']).to eq(2)
      expect(id_calls[:count]).to eq(1)
    end
  end

  describe 'expiry and fresh-flow behavior' do
    it 'sets an expiry from the injected clock and reports the flow active' do
      store.start!(current_intent: 'price')

      expect(store.active?).to be(true)
      expect(store.current['expires_at']).to eq((clock_state[:now] + described_class::DEFAULT_TTL).iso8601)
    end

    it 'expires an active flow and then allows a fresh flow' do
      store.start!(current_intent: 'price')

      advance(described_class::DEFAULT_TTL + 1)
      expect(store.expired?).to be(true)
      expect(store.active?).to be(false)

      expect(store.expire!['status']).to eq('expired')
      expect(store.current['status']).to eq('expired')

      fresh = store.start!(current_intent: 'stock')
      expect(fresh['version']).to eq(1)
      expect(fresh['status']).to eq('active')
    end

    it 'is a no-op when expiring with no flow present' do
      expect(store.expire!).to be_nil
      expect(store.current).to be_nil
    end
  end

  # Phase 3 — read-only EFFECTIVE planning snapshot for the orchestrator. An elapsed active
  # flow reads as expired WITHOUT persisting the transition or bumping the version.
  describe '#current_for_planning' do
    it 'returns the active flow unchanged before expiry' do
      store.start!(current_intent: 'price', validated_family: 'Bearings')

      snapshot = store.current_for_planning

      expect(snapshot['status']).to eq('active')
      expect(snapshot['validated_family']).to eq('Bearings')
    end

    it 'presents an active-but-elapsed flow as expired at exactly the expiry instant' do
      store.start!(current_intent: 'price')

      advance(described_class::DEFAULT_TTL) # now == expires_at (expired? is <=)

      expect(store.current_for_planning['status']).to eq('expired')
    end

    it 'does not persist the expiry transition or bump the version during planning' do
      store.start!(current_intent: 'price') # version 1, active
      advance(described_class::DEFAULT_TTL + 1)

      2.times { expect(store.current_for_planning['status']).to eq('expired') }

      # The persisted row is still the original active version-1 flow (no write happened).
      persisted = conversation.reload.additional_attributes['wijaya_marine_ai']['product_flow_v1']
      expect(persisted['status']).to eq('active')
      expect(persisted['version']).to eq(1)
    end

    it 'reads nil for a malformed flow (strict fail-closed)' do
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'product_flow_v1' => 'garbage' } })

      expect(store.current_for_planning).to be_nil
    end

    it 'returns an already-expired or completed flow unchanged (still inactive)' do
      store.start!(current_intent: 'price')
      store.update!(status: 'completed')

      expect(store.current_for_planning['status']).to eq('completed')

      other = described_class.new(conversation: create(:conversation).reload, clock: clock, id_generator: id_generator)
      other.start!(current_intent: 'price')
      other.expire!
      expect(other.current_for_planning['status']).to eq('expired')
    end

    it 'lets a fresh start! after expiry reset version/id/TTL and drop clarification metadata, preserving siblings' do
      conversation.update!(additional_attributes: { 'top' => 'keep', 'wijaya_marine_ai' => { 'sibling_v1' => { 'x' => 1 } } })
      store.start!(current_intent: 'price', validated_family: 'Bearings',
                   clarification_kind: 'variant', clarification_count: 2)
      store.update!(validated_variant: 'B-100') # version 2
      advance(described_class::DEFAULT_TTL + 1)
      expect(store.current_for_planning['status']).to eq('expired')

      fresh = store.start!(current_intent: 'stock')

      expect(fresh['version']).to eq(1)
      expect(fresh['flow_id']).to eq('flow-fixed-id')
      expect(fresh['expires_at']).to eq((clock_state[:now] + described_class::DEFAULT_TTL).iso8601)
      expect(fresh).not_to have_key('validated_family')
      expect(fresh).not_to have_key('validated_variant')
      expect(fresh).not_to have_key('clarification_kind')
      expect(fresh).not_to have_key('clarification_count')
      attributes = conversation.reload.additional_attributes
      expect(attributes['top']).to eq('keep')
      expect(attributes['wijaya_marine_ai']['sibling_v1']).to eq('x' => 1)
    end
  end

  describe 'clarification metadata allowlisting' do
    it 'persists a valid enum kind and bounded count' do
      flow = store.start!(current_intent: 'price', clarification_kind: 'variant', clarification_count: 2)

      expect(flow['clarification_kind']).to eq('variant')
      expect(flow['clarification_count']).to eq(2)
    end

    it 'drops an unknown clarification kind and an out-of-range/forged count (never trusted to force handoff)' do
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'product_flow_v1' => {
                             'version' => 3, 'flow_id' => 'id', 'status' => 'active',
                             'expires_at' => (clock_state[:now] + 3600).iso8601,
                             'clarification_kind' => 'haxx', 'clarification_count' => 99
                           } } })

      flow = store.current

      expect(flow).not_to have_key('clarification_kind')
      expect(flow).not_to have_key('clarification_count')
    end

    it 'clears clarification metadata when a subsequent update! sends nil (progress)' do
      store.start!(current_intent: 'price', clarification_kind: 'variant', clarification_count: 2)

      updated = store.update!('clarification_kind' => nil, 'clarification_count' => nil, 'validated_variant' => 'B-1')

      expect(updated).not_to have_key('clarification_kind')
      expect(updated).not_to have_key('clarification_count')
      expect(updated['validated_variant']).to eq('B-1')
    end
  end

  # Phase 3 — the ONE canonical expected-attributes normalization owned by the store's trust
  # boundary. Persistence (bounded_array) and the orchestrator's clarification identity BOTH
  # reuse this, so a pathological repository list normalizes identically on either side.
  describe '.normalize_expected_attributes' do
    it 'control-strips, blank-rejects, truncates, dedupes, and caps at MAX_ATTRIBUTES (order preserved)' do
      raw = ['Size', 'Size', '  Color  ', "Volt\u0000age", '', '   ',
             'L' * (described_class::MAX_ATTRIBUTE_LENGTH + 20)] +
            Array.new(described_class::MAX_ATTRIBUTES) { |i| "Attr#{i}" }

      result = described_class.normalize_expected_attributes(raw)

      expect(result.length).to eq(described_class::MAX_ATTRIBUTES)                 # capped
      expect(result).to eq(result.uniq)                                           # deduped
      expect(result).not_to include('', '   ')                                    # blanks rejected
      expect(result.first(4)).to eq(['Size', 'Color', 'Volt age',
                                     'L' * described_class::MAX_ATTRIBUTE_LENGTH]) # strip + control + truncate
    end

    it 'normalizes a non-array (or nil) to []' do
      expect(described_class.normalize_expected_attributes('nope')).to eq([])
      expect(described_class.normalize_expected_attributes(nil)).to eq([])
    end

    it 'equals the value the store actually persists for the same pathological list (persistence delegates here)' do
      raw = ['Size', 'Size', '  Color  ', '', 'D' * 200] + Array.new(20) { |i| "A#{i}" }

      flow = store.start!(current_intent: 'variant_info', expected_attributes: raw)

      expect(flow['expected_attributes']).to eq(described_class.normalize_expected_attributes(raw))
    end
  end

  describe 'reset!' do
    it 'removes only product_flow_v1 and preserves siblings' do
      conversation.update!(additional_attributes: { 'top' => 'keep', 'wijaya_marine_ai' => { 'sibling_v1' => { 'x' => 1 } } })
      store.start!(current_intent: 'price')

      store.reset!

      attributes = conversation.reload.additional_attributes
      expect(attributes['wijaya_marine_ai']).not_to have_key('product_flow_v1')
      expect(attributes['wijaya_marine_ai']['sibling_v1']).to eq('x' => 1)
      expect(attributes['top']).to eq('keep')
    end
  end

  # In-memory (NON-PERSISTING) snapshot transforms used by the source-less Playground preview. They
  # reuse the exact allowlisting/bounding/lifecycle semantics of the persisted path with NO
  # Conversation, lock, or DB write, so a preview and a real conversation normalize/transition state
  # identically.
  describe 'in-memory snapshot transforms (no conversation / no persistence)' do
    subject(:mem) { described_class.new(conversation: nil, clock: clock, id_generator: id_generator) }

    describe '#apply_snapshot :start' do
      it 'begins a fresh version-1 flow with allowlisted changes and drops unknown keys' do
        snap = mem.apply_snapshot(nil, operation: :start,
                                       changes: { 'current_intent' => 'catalog', 'validated_family' => 'BD', 'evil' => 'x' })

        expect(snap).to include('version' => 1, 'status' => 'active', 'flow_id' => 'flow-fixed-id',
                                'current_intent' => 'catalog', 'original_intent' => 'catalog', 'validated_family' => 'BD')
        expect(snap).not_to have_key('evil')
      end
    end

    describe '#apply_snapshot :update' do
      let(:existing) do
        mem.apply_snapshot(nil, operation: :start, changes: { 'current_intent' => 'catalog', 'validated_family' => 'BD' })
      end

      it 'bumps the version, merges allowlisted changes, and keeps original_intent immutable' do
        snap = mem.apply_snapshot(existing, operation: :update,
                                            changes: { 'current_intent' => 'price', 'original_intent' => 'hack', 'catalog_sent' => true })

        expect(snap).to include('version' => 2, 'current_intent' => 'price', 'original_intent' => 'catalog',
                                'validated_family' => 'BD', 'catalog_sent' => true)
      end

      it 'seeds a fresh flow when there is no prior snapshot' do
        snap = mem.apply_snapshot(nil, operation: :update, changes: { 'current_intent' => 'catalog' })
        expect(snap).to include('version' => 1, 'current_intent' => 'catalog')
      end
    end

    describe '#apply_snapshot :none' do
      it 'returns the normalized prior snapshot unchanged' do
        existing = mem.apply_snapshot(nil, operation: :start, changes: { 'current_intent' => 'catalog' })
        expect(mem.apply_snapshot(existing, operation: :none)).to eq(existing)
      end
    end

    describe '#snapshot_for_planning' do
      it 'presents an ACTIVE but elapsed flow as expired without mutating it' do
        active = mem.apply_snapshot(nil, operation: :start, changes: { 'current_intent' => 'catalog' })
        advance(described_class::DEFAULT_TTL + 1)

        expect(mem.snapshot_for_planning(active)['status']).to eq('expired')
        expect(active['status']).to eq('active')
      end

      it 'returns nil for a malformed snapshot' do
        expect(mem.snapshot_for_planning({ 'garbage' => true })).to be_nil
        expect(mem.snapshot_for_planning(nil)).to be_nil
      end
    end

    describe '#normalize_snapshot' do
      it 'drops keys outside the allowlist and returns nil for a non-hash' do
        normalized = mem.normalize_snapshot('version' => 1, 'flow_id' => 'f', 'status' => 'active',
                                            'expires_at' => clock_state[:now].iso8601, 'validated_family' => 'BD', 'secret' => 'x')
        expect(normalized).to include('validated_family' => 'BD')
        expect(normalized).not_to have_key('secret')
        expect(mem.normalize_snapshot('nope')).to be_nil
      end
    end
  end

  describe 'under lock: reloads the latest persisted state' do
    it 'does not clobber a concurrent writer and preserves keys it never saw' do
      store.start!(current_intent: 'price') # version 1 persisted

      # A separate, stale in-memory conversation object loaded before the write below.
      stale_conversation = Conversation.find(conversation.id)
      stale_store = described_class.new(conversation: stale_conversation, clock: clock, id_generator: id_generator)

      # Another top-level key lands after stale_conversation was loaded.
      conversation.reload.update!(additional_attributes: conversation.additional_attributes.merge('late_key' => 'keep'))

      result = stale_store.update!(validated_family: 'Bearings')

      expect(result['version']).to eq(2) # reloaded latest (v1) under lock, then +1
      expect(conversation.reload.additional_attributes['late_key']).to eq('keep')
    end
  end
end
