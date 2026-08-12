# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Conversation::ProcessingClaim do
  let(:message) { create(:message, message_type: :incoming) }
  let(:clock_state) { { now: Time.zone.parse('2026-01-01T00:00:00Z') } }
  let(:clock) { -> { clock_state[:now] } }

  def build_claim(msg: message, id: 'claim-a', stale_after: described_class::DEFAULT_STALE_AFTER)
    described_class.new(message: msg, clock: clock, id_generator: -> { id }, stale_after: stale_after)
  end

  def stored_claim(msg = message)
    msg.reload.additional_attributes.dig('wijaya_marine_ai', 'processing_claim_v1')
  end

  def advance(seconds)
    clock_state[:now] += seconds
  end

  describe 'first acquisition' do
    it 'acquires ownership and persists an allowlisted processing claim under the Marine namespace' do
      result = build_claim(id: 'claim-a').acquire!

      expect(result.status).to eq('acquired')
      expect(result.owner?).to be(true)
      expect(result.claim).to eq(
        'claim_id' => 'claim-a', 'claimed_at' => clock_state[:now].iso8601, 'message_id' => message.id, 'status' => 'processing'
      )
      expect(stored_claim.keys).to contain_exactly('claim_id', 'claimed_at', 'message_id', 'status')
      expect(stored_claim['status']).to eq('processing')
    end
  end

  describe 'duplicate fresh claim' do
    it 'does not create a second owner and does not overwrite the existing claim' do
      build_claim(id: 'claim-a').acquire!

      result = build_claim(id: 'claim-b').acquire!

      expect(result.status).to eq('duplicate')
      expect(result.owner?).to be(false)
      expect(result.claim['claim_id']).to eq('claim-a')
      expect(stored_claim['claim_id']).to eq('claim-a')
    end
  end

  describe 'stale reclaim' do
    it 'reclaims atomically with a new claim identity and time' do
      build_claim(id: 'claim-a').acquire!

      advance(described_class::DEFAULT_STALE_AFTER + 1)
      result = build_claim(id: 'claim-b').acquire!

      expect(result.status).to eq('reclaimed')
      expect(result.owner?).to be(true)
      expect(result.claim['claim_id']).to eq('claim-b')
      expect(result.claim['claimed_at']).to eq(clock_state[:now].iso8601)
      expect(stored_claim['claim_id']).to eq('claim-b')
    end
  end

  describe 'malformed reclaim' do
    it 'reclaims, replacing only the claim namespace and preserving siblings' do
      message.update!(
        additional_attributes: {
          'top' => 'keep',
          'wijaya_marine_ai' => { 'sibling_v1' => { 'x' => 1 }, 'processing_claim_v1' => 'corrupt' }
        }
      )

      result = build_claim(id: 'claim-b').acquire!

      expect(result.status).to eq('reclaimed')
      expect(result.owner?).to be(true)
      attributes = message.reload.additional_attributes
      expect(attributes['top']).to eq('keep')
      expect(attributes['wijaya_marine_ai']['sibling_v1']).to eq('x' => 1)
      expect(attributes['wijaya_marine_ai']['processing_claim_v1']['claim_id']).to eq('claim-b')
    end
  end

  describe 'message-bound claim' do
    def store_fresh_claim(extra = {})
      base = { 'claim_id' => 'claim-a', 'claimed_at' => clock_state[:now].iso8601, 'status' => 'processing' }
      message.update!(additional_attributes: { 'wijaya_marine_ai' => { 'processing_claim_v1' => base.merge(extra) } })
    end

    it 'reclaims a fresh claim whose message_id is missing' do
      store_fresh_claim

      result = build_claim(id: 'claim-b').acquire!

      expect(result.status).to eq('reclaimed')
      expect(result.owner?).to be(true)
      expect(stored_claim['claim_id']).to eq('claim-b')
      expect(stored_claim['message_id']).to eq(message.id)
    end

    it 'reclaims a fresh claim whose message_id belongs to another message' do
      store_fresh_claim('message_id' => message.id + 999)

      result = build_claim(id: 'claim-b').acquire!

      expect(result.status).to eq('reclaimed')
      expect(result.owner?).to be(true)
      expect(stored_claim['claim_id']).to eq('claim-b')
      expect(stored_claim['message_id']).to eq(message.id)
    end
  end

  describe 'non-incoming message' do
    it 'raises and writes no claim' do
      outgoing = create(:message, message_type: :outgoing)

      expect { build_claim(msg: outgoing).acquire! }.to raise_error(ArgumentError)
      expect(stored_claim(outgoing)).to be_nil
    end

    it 'raises on complete! for a non-incoming message and writes nothing' do
      outgoing = create(:message, message_type: :outgoing)

      expect { build_claim(msg: outgoing).complete!(claim_id: 'claim-a') }.to raise_error(ArgumentError)
      expect(stored_claim(outgoing)).to be_nil
    end
  end

  describe 'completion lifecycle' do
    it 'lets the current owner complete under the lock and stamps a completion time' do
      acquired = build_claim(id: 'claim-a').acquire!
      advance(30)

      result = build_claim.complete!(claim_id: acquired.claim['claim_id'])

      expect(result.status).to eq('completed')
      expect(result.completed?).to be(true)
      expect(result.owner?).to be(true)
      expect(result.claim['status']).to eq('completed')
      expect(result.claim['completed_at']).to eq(clock_state[:now].iso8601)
      expect(result.claim['claimed_at']).to eq((clock_state[:now] - 30).iso8601)
      expect(stored_claim['status']).to eq('completed')
      expect(stored_claim['claim_id']).to eq('claim-a')
    end

    it 'treats a later delivery of a completed message as a permanent, non-owner duplicate' do
      acquired = build_claim(id: 'claim-a').acquire!
      build_claim.complete!(claim_id: acquired.claim['claim_id'])

      result = build_claim(id: 'claim-b').acquire!

      expect(result.status).to eq('completed')
      expect(result.completed?).to be(true)
      expect(result.owner?).to be(false)
      expect(result.claim['claim_id']).to eq('claim-a')
      expect(stored_claim['claim_id']).to eq('claim-a')
      expect(stored_claim['status']).to eq('completed')
    end

    it 'never reclaims a completed claim, even long after stale_after' do
      acquired = build_claim(id: 'claim-a').acquire!
      build_claim.complete!(claim_id: acquired.claim['claim_id'])

      advance(described_class::DEFAULT_STALE_AFTER + 999)
      result = build_claim(id: 'claim-b').acquire!

      expect(result.status).to eq('completed')
      expect(result.owner?).to be(false)
      expect(stored_claim['claim_id']).to eq('claim-a')
      expect(stored_claim['status']).to eq('completed')
    end

    it 'stops a stale old owner from completing a reclaimed claim' do
      build_claim(id: 'claim-a').acquire!
      advance(described_class::DEFAULT_STALE_AFTER + 1)
      build_claim(id: 'claim-b').acquire! # reclaimed; new owner is claim-b

      result = build_claim.complete!(claim_id: 'claim-a')

      expect(result.status).to eq('conflict')
      expect(result.conflict?).to be(true)
      expect(result.owner?).to be(false)
      expect(stored_claim['claim_id']).to eq('claim-b')
      expect(stored_claim['status']).to eq('processing')
    end

    it 'rejects completion with a wrong claim_id and writes nothing' do
      build_claim(id: 'claim-a').acquire!

      result = build_claim.complete!(claim_id: 'not-the-owner')

      expect(result.status).to eq('conflict')
      expect(result.owner?).to be(false)
      expect(stored_claim['claim_id']).to eq('claim-a')
      expect(stored_claim['status']).to eq('processing')
    end

    it 'ignores a foreign message_id for completion and completed-duplicate detection' do
      message.update!(additional_attributes: { 'wijaya_marine_ai' => { 'processing_claim_v1' => {
                        'claim_id' => 'claim-a', 'claimed_at' => clock_state[:now].iso8601,
                        'message_id' => message.id + 999, 'status' => 'completed', 'completed_at' => clock_state[:now].iso8601
                      } } })

      expect(build_claim.complete!(claim_id: 'claim-a').status).to eq('conflict')

      result = build_claim(id: 'claim-b').acquire!
      expect(result.status).to eq('reclaimed')
      expect(stored_claim['status']).to eq('processing')
      expect(stored_claim['message_id']).to eq(message.id)
    end

    it 'is idempotent when the same owner completes twice (no second stamp)' do
      acquired = build_claim(id: 'claim-a').acquire!
      first = build_claim.complete!(claim_id: acquired.claim['claim_id'])
      completed_at = first.claim['completed_at']

      advance(60)
      second = build_claim.complete!(claim_id: acquired.claim['claim_id'])

      expect(second.status).to eq('completed')
      expect(second.owner?).to be(true)
      expect(second.claim['completed_at']).to eq(completed_at)
      expect(stored_claim['completed_at']).to eq(completed_at)
    end

    it 'fails safely when the claim is malformed and writes nothing' do
      message.update!(additional_attributes: { 'wijaya_marine_ai' => { 'processing_claim_v1' => 'corrupt' } })

      result = build_claim.complete!(claim_id: 'claim-a')

      expect(result.status).to eq('conflict')
      expect(result.owner?).to be(false)
      expect(stored_claim).to eq('corrupt')
    end

    it 'preserves top-level and Marine sibling keys on completion' do
      message.update!(additional_attributes: { 'top' => 'keep', 'wijaya_marine_ai' => { 'sibling_v1' => { 'x' => 1 } } })
      acquired = build_claim(id: 'claim-a').acquire!

      build_claim.complete!(claim_id: acquired.claim['claim_id'])

      attributes = message.reload.additional_attributes
      expect(attributes['top']).to eq('keep')
      expect(attributes['wijaya_marine_ai']['sibling_v1']).to eq('x' => 1)
      expect(attributes['wijaya_marine_ai']['processing_claim_v1']['status']).to eq('completed')
    end
  end

  describe 'write failure' do
    it 'propagates an acquire write failure so a future job can retry' do
      allow(message).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(message))

      expect { build_claim(msg: message).acquire! }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe 'per-message isolation' do
    it 'claims are scoped to a single message id' do
      other = create(:message, message_type: :incoming, conversation: message.conversation)

      build_claim(msg: message, id: 'claim-a').acquire!
      result = build_claim(msg: other, id: 'claim-b').acquire!

      expect(result.status).to eq('acquired')
      expect(stored_claim(message)['claim_id']).to eq('claim-a')
      expect(stored_claim(other)['claim_id']).to eq('claim-b')
    end
  end

  describe 'preservation and no generic keys' do
    it 'preserves top-level and Marine sibling keys and never writes a generic top-level claim key' do
      message.update!(additional_attributes: { 'top' => 'keep', 'wijaya_marine_ai' => { 'sibling_v1' => { 'x' => 1 } } })

      build_claim(id: 'claim-a').acquire!

      attributes = message.reload.additional_attributes
      expect(attributes['top']).to eq('keep')
      expect(attributes['wijaya_marine_ai']['sibling_v1']).to eq('x' => 1)
      expect(attributes).not_to have_key('claim_id')
      expect(attributes).not_to have_key('processing_claim_v1')
    end
  end
end
