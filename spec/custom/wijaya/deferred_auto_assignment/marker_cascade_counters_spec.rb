# frozen_string_literal: true

require 'rails_helper'

# Blocker: migration 20260912000005 established on_delete: :cascade on the marker foreign keys, so a
# DB-level cascade (conversation.delete_all / any parent FK cascade) removes a reconciliation-owned
# marker WITHOUT firing a Rails after_destroy — which would leave the run ledger with a stale
# no_eligible_agent and a missing dropped. The MarkerDropTrigger BEFORE DELETE trigger makes terminal
# accounting truthful for BOTH the DB-cascade path AND the ordinary Rails destroy path, exactly once,
# while Marker.resolve_and_record still owns the explicit ASSIGNED/DROPPED transitions (it suppresses
# the trigger for its own delete so the two never double-count).
#
# These tests execute TRUE DB-level deletes (delete_all / cascade) — not Rails destroy — to prove the
# trigger, and rely on spec/support/wijaya_deferred_marker_drop_trigger.rb having installed it.
RSpec.describe 'Deferred auto-assignment marker terminal counters on DB cascade', type: :model do
  let(:run_model) { Wijaya::Batteries::DeferredAutoAssignment::ReconciliationRun }
  let(:marker_model) { Wijaya::Batteries::DeferredAutoAssignment::Marker }

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

  def new_conversation
    Conversation.create!(account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox).tap do |c|
      # Drop any creation-time (generation-less) marker so each test controls the marker it asserts on.
      marker_model.where(conversation_id: c.id).delete_all
    end
  end

  # A reconciliation-owned marker (carrying a generation) in the given waiting +outcome+, tied to a run.
  def owned_marker(run, conversation, outcome: nil)
    marker_model.create!(account: account, inbox: inbox, conversation: conversation,
                         reconciliation_generation: run.generation, reconciliation_outcome: outcome)
  end

  def make_run(generation, **counters)
    run_model.create!({ generation: generation, status: 'running', started_at: Time.current,
                        cutoff_at: Time.current }.merge(counters))
  end

  describe 'a true DB cascade (conversation.delete_all) on a reconciliation-owned marker' do
    it 'reverses no_eligible_agent and records DROPPED exactly once' do
      run = make_run('gen-cascade-ne', registered: 1, no_eligible_agent: 1)
      conversation = new_conversation
      owned_marker(run, conversation, outcome: run_model::NO_ELIGIBLE_AGENT)

      # DB-level DELETE on the parent: on_delete: :cascade removes the marker with NO Rails callback.
      Conversation.where(id: conversation.id).delete_all

      expect(marker_model.where(conversation_id: conversation.id).count).to eq(0)
      expect(run.reload.dropped).to eq(1)
      expect(run.no_eligible_agent).to eq(0)
      expect(run.assigned).to eq(0)
    end

    it 'records DROPPED for a still-waiting marker that never got an async disposition (outcome nil)' do
      run = make_run('gen-cascade-nil', registered: 1)
      conversation = new_conversation
      owned_marker(run, conversation, outcome: nil)

      Conversation.where(id: conversation.id).delete_all

      expect(run.reload.dropped).to eq(1)
      expect(run.no_eligible_agent).to eq(0)
    end
  end

  describe 'a direct callback-less marker DELETE (the exact statement a parent cascade emits)' do
    it 'records DROPPED exactly once and is a no-op on a repeated delete of the (already-gone) row' do
      run = make_run('gen-direct', registered: 1, no_eligible_agent: 1)
      conversation = new_conversation
      marker = owned_marker(run, conversation, outcome: run_model::NO_ELIGIBLE_AGENT)

      expect(marker_model.where(id: marker.id).delete_all).to eq(1)
      expect(run.reload.dropped).to eq(1)
      expect(run.no_eligible_agent).to eq(0)

      # Repeated/no-op delete: the row is gone, so the trigger cannot fire again — no double count.
      expect(marker_model.where(id: marker.id).delete_all).to eq(0)
      expect(run.reload.dropped).to eq(1)
    end
  end

  describe 'an ordinary (generation-less) marker deleted by cascade' do
    it 'never touches any run ledger' do
      run = make_run('gen-ordinary', no_eligible_agent: 1)
      conversation = new_conversation
      marker_model.create!(account: account, inbox: inbox, conversation: conversation) # generation nil

      Conversation.where(id: conversation.id).delete_all

      expect(run.reload.no_eligible_agent).to eq(1) # untouched
      expect(run.dropped).to eq(0)
    end
  end

  describe 'explicit resolve_and_record suppresses the trigger (never double-counts)' do
    it 'records ASSIGNED once (not ASSIGNED + a trigger DROPPED) on resolve-to-assigned' do
      run = make_run('gen-assign', registered: 1, no_eligible_agent: 1)
      conversation = new_conversation
      owned_marker(run, conversation, outcome: run_model::NO_ELIGIBLE_AGENT)

      marker_model.resolve_and_record(conversation.id, run_model::ASSIGNED)

      expect(marker_model.where(conversation_id: conversation.id).count).to eq(0)
      expect(run.reload.assigned).to eq(1)
      expect(run.no_eligible_agent).to eq(0)
      expect(run.dropped).to eq(0) # the trigger did NOT also fire a DROPPED
    end

    it 'records DROPPED once (not twice) on resolve-to-dropped' do
      run = make_run('gen-drop', registered: 1, no_eligible_agent: 1)
      conversation = new_conversation
      owned_marker(run, conversation, outcome: run_model::NO_ELIGIBLE_AGENT)

      marker_model.resolve_and_record(conversation.id, run_model::DROPPED)

      expect(run.reload.dropped).to eq(1) # exactly once, not 2
      expect(run.no_eligible_agent).to eq(0)
    end
  end

  describe 'rollback safety' do
    it 'rolls the trigger ledger transition back with the enclosing transaction' do
      run = make_run('gen-rollback', registered: 1, no_eligible_agent: 1)
      conversation = new_conversation
      owned_marker(run, conversation, outcome: run_model::NO_ELIGIBLE_AGENT)

      ActiveRecord::Base.transaction do
        marker_model.where(conversation_id: conversation.id).delete_all # trigger fires in-txn
        raise ActiveRecord::Rollback
      end

      expect(marker_model.where(conversation_id: conversation.id).count).to eq(1) # delete rolled back
      expect(run.reload.dropped).to eq(0)                                         # counter transition rolled back too
      expect(run.no_eligible_agent).to eq(1)
    end
  end
end
