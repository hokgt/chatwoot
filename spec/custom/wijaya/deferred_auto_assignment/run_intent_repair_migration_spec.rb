# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('db/migrate/20260912000007_ensure_deferred_reconciliation_initial_run_intent')

# Blocker: 20260912000003 was rewritten in place from a Redis perform_later into an INSERT of a
# durable run intent. An environment that already recorded the OLD 20260912000003 in schema_migrations
# never re-runs its rewritten up, so the durable one-time reconciliation run intent would simply never
# exist there. This forward migration idempotently ensures that intent exists (no Redis), no-ops when
# it already exists in any state, and never duplicates it.
RSpec.describe EnsureDeferredReconciliationInitialRunIntent, type: :model do
  let(:migration) { described_class.new.tap { |m| m.verbose = false } }
  let(:run_model) { Wijaya::Batteries::DeferredAutoAssignment::ReconciliationRun }
  let(:generation) { described_class::GENERATION }
  let(:drainer) { Wijaya::Batteries::DeferredAutoAssignment::RecoveryDrainerJob }
  let(:recon_job) { Wijaya::Batteries::DeferredAutoAssignment::ReconciliationJob }
  let(:process_inbox_job) { Wijaya::Batteries::DeferredAutoAssignment::ProcessInboxJob }

  # Simulate an already-recorded-old-000003 database: the rewritten 000003 up never ran here, so no
  # run intent exists (the model transaction fixture starts empty, so this is the natural state).
  before { run_model.where(generation: generation).delete_all }

  it 'repairs a drifted install by inserting the exact one-time run intent (running, never executed)' do
    expect(run_model.where(generation: generation)).to be_empty

    migration.up

    run = run_model.find_by(generation: generation)
    expect(run).to be_present
    expect(run.status).to eq('running')
    expect(run.started_at).to be_nil        # never executed yet — the coordinator runs it later
    expect(run.cutoff_at).to be_present      # full history up to this upgrade
  end

  it 'is idempotent: a second application never creates a second intent' do
    migration.up
    expect { migration.up }.not_to change { run_model.where(generation: generation).count }.from(1)
  end

  it 'no-ops when the intent already completed (never reverts a completed run to running)' do
    run_model.create!(generation: generation, status: 'completed', started_at: 1.day.ago,
                      finished_at: 1.day.ago, cutoff_at: 1.day.ago)

    migration.up

    expect(run_model.where(generation: generation).count).to eq(1)
    expect(run_model.find_by(generation: generation).status).to eq('completed')
  end

  it 'no-ops when a fresh install already inserted the running intent (belt-and-suspenders)' do
    original = run_model.create!(generation: generation, status: 'running', started_at: nil, cutoff_at: Time.current)

    migration.up

    expect(run_model.where(generation: generation).count).to eq(1)
    expect(run_model.find_by(generation: generation).id).to eq(original.id)
  end

  it 'the repaired intent is picked up by the drainer coordinator and completes truthfully' do
    account = create(:account)
    account.disable_features!(:assignment_v2)
    migration.up

    perform_enqueued_jobs(only: [recon_job, process_inbox_job]) { drainer.perform_now }

    run = run_model.find_by(generation: generation)
    expect(run.status).to eq('completed')
    expect(run.scanned).to eq(0)   # no provenance on this install
    expect(run.retries).to eq(0)   # first execution of a pre-persisted intent is NOT a retry
  end
end
