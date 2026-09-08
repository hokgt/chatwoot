# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Circuit::HandoffStateStore do
  subject(:store) { described_class.new(conversation: conversation, clock: clock) }

  # Reloaded so the record is clean before row-locking (the factory leaves display_id
  # dirty in memory); a real caller row-locks a DB-loaded conversation.
  let(:conversation) { create(:conversation).reload }
  let(:clock) { -> { Time.zone.parse('2026-01-01T00:00:00Z') } }

  describe 'namespace' do
    it 'writes the marker under exactly additional_attributes.wijaya_marine_ai.handoff_v1' do
      store.activate!(message_ids: [1, 2])

      attributes = conversation.reload.additional_attributes
      expect(attributes.keys).to eq(['wijaya_marine_ai'])
      expect(attributes['wijaya_marine_ai'].keys).to eq(['handoff_v1'])
      expect(attributes['wijaya_marine_ai']['handoff_v1']).to eq(
        'version' => 1, 'status' => 'active', 'announced_at' => '2026-01-01T00:00:00Z', 'message_ids' => [1, 2]
      )
    end
  end

  describe '#active?' do
    it 'is false with no marker' do
      expect(store.active?).to be(false)
    end

    it 'is true once activated' do
      store.activate!(message_ids: [7])
      expect(store.active?).to be(true)
    end

    it 'fails closed: a present-but-malformed marker (missing required lifecycle field) reads active' do
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'handoff_v1' => { 'status' => 'active' } } })
      expect(store.active?).to be(true)
    end

    it 'fails closed: a present non-hash marker value reads active' do
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'handoff_v1' => 'garbage' } })
      expect(store.active?).to be(true)
    end

    it 'fails closed: a present handoff_v1 key whose value is null reads active' do
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'handoff_v1' => nil } })
      conversation.reload

      # Presence of the null key -- not its value -- is what makes this terminal.
      expect(conversation.additional_attributes['wijaya_marine_ai'].key?('handoff_v1')).to be(true)
      expect(store.active?).to be(true)
    end
  end

  describe '#activate! preserves a present-but-unusable marker' do
    it 'does not overwrite or repair a present-but-malformed marker (no fresh write)' do
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'handoff_v1' => { 'status' => 'active' } } })

      returned = store.activate!(message_ids: [1, 2])

      stored = conversation.reload.additional_attributes.dig('wijaya_marine_ai', 'handoff_v1')
      expect(stored).to eq('status' => 'active')
      expect(returned).to eq('status' => 'active')
    end

    it 'does not overwrite a present handoff_v1 key whose value is null' do
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'handoff_v1' => nil } })

      store.activate!(message_ids: [1, 2])

      feature = conversation.reload.additional_attributes.fetch('wijaya_marine_ai')
      expect(feature.key?('handoff_v1')).to be(true)
      expect(feature['handoff_v1']).to be_nil
    end
  end

  describe 'idempotency' do
    it 'leaves an already-active marker untouched (no re-version, same message ids)' do
      first = store.activate!(message_ids: [3, 4])
      again = described_class.new(conversation: conversation.reload, clock: -> { Time.zone.parse('2026-06-01T00:00:00Z') })
                             .activate!(message_ids: [99])

      expect(again).to eq(first)
      expect(again['announced_at']).to eq('2026-01-01T00:00:00Z')
      expect(again['message_ids']).to eq([3, 4])
    end
  end

  describe 'sibling preservation' do
    it 'preserves unrelated top-level keys and sibling Marine namespaces' do
      conversation.update!(additional_attributes: {
                             'referer' => 'https://example.com',
                             'wijaya_marine_ai' => { 'product_flow_v1' => { 'flow_id' => 'x' } }
                           })

      store.activate!(message_ids: [5])

      attributes = conversation.reload.additional_attributes
      expect(attributes['referer']).to eq('https://example.com')
      expect(attributes['wijaya_marine_ai']['product_flow_v1']).to eq('flow_id' => 'x')
      expect(attributes['wijaya_marine_ai']['handoff_v1']['status']).to eq('active')
    end
  end

  describe 'bounded / allowlisted' do
    it 'drops non-integer and non-positive ids and caps the stored id list at two' do
      store.activate!(message_ids: [0, -3, 'nope', nil] + (1..20).to_a)

      marker = conversation.reload.additional_attributes['wijaya_marine_ai']['handoff_v1']
      expect(marker['message_ids']).to eq([1, 2])
    end
  end

  describe '#reset!' do
    it 'clears an active marker so the store reads inactive again' do
      store.activate!(message_ids: [7])
      expect(store.active?).to be(true)

      store.reset!

      expect(conversation.reload.additional_attributes.dig('wijaya_marine_ai', 'handoff_v1')).to be_nil
      expect(described_class.new(conversation: conversation.reload).active?).to be(false)
    end

    it 'also clears a present-but-malformed (fail-closed active) marker' do
      conversation.update!(additional_attributes: { 'wijaya_marine_ai' => { 'handoff_v1' => 'garbage' } })

      store.reset!

      feature = conversation.reload.additional_attributes.fetch('wijaya_marine_ai')
      expect(feature.key?('handoff_v1')).to be(false)
    end

    it 'preserves unrelated top-level keys and sibling Marine namespaces' do
      conversation.update!(additional_attributes: {
                             'referer' => 'https://example.com',
                             'wijaya_marine_ai' => { 'product_flow_v1' => { 'flow_id' => 'x' },
                                                     'handoff_v1' => { 'version' => 1, 'status' => 'active',
                                                                       'announced_at' => '2026-01-01T00:00:00Z', 'message_ids' => [] } }
                           })

      store.reset!

      attributes = conversation.reload.additional_attributes
      expect(attributes['referer']).to eq('https://example.com')
      expect(attributes['wijaya_marine_ai']['product_flow_v1']).to eq('flow_id' => 'x')
      expect(attributes['wijaya_marine_ai'].key?('handoff_v1')).to be(false)
    end

    it 'is an idempotent no-op when no marker is present (creates no message)' do
      expect { store.reset! }.not_to(change { conversation.reload.messages.count })
      expect(store.active?).to be(false)
    end
  end
end
