# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 4 + Stage 5 — the DEFAULT-OFF, fire-and-forget ShadowJob. These examples drive
# perform with scalar IDs + stubbed finders/execution/metrics and pin: it re-checks the
# assistant-scoped shadow flag with the SCALAR id AND again with the LOADED assistant id BEFORE
# running the execution (so the Runner/provider never runs for an unlisted assistant), loads
# records account-scoped, ignores a missing/private/outgoing/cross-account turn, records a
# privacy-safe observation for a genuine comparison, records NOTHING for a nil execution, and
# swallows any observation/metrics failure without re-raising.
RSpec.describe Marine::Decision::ShadowJob do
  subject(:job) { described_class.new }

  let(:account) { double('account', id: 1, conversations: conversations) }
  let(:assistant) { double('assistant', id: 3) }
  let(:conversation) { double('conversation', id: 5, messages: messages) }
  let(:message) { double('message', id: 9, incoming?: true, private?: false) }
  let(:conversations) { double('conversations') }
  let(:messages) { double('messages') }
  let(:result) { { legacy_scenario_key: 'scenario_3', candidate_plan: {} }.freeze }

  before { allow(Marine::Decision::ShadowConfig).to receive(:enabled_for?).with(3).and_return(true) }

  # Account-scoped finders: account -> assistant (scoped by account_id) -> conversation
  # (via account.conversations) -> message (via conversation.messages).
  def stub_loads
    allow(Account).to receive(:find_by).and_return(account)
    allow(Marine::Assistant).to receive(:find_by).with(id: 3, account_id: 1).and_return(assistant)
    allow(conversations).to receive(:find_by).and_return(conversation)
    allow(messages).to receive(:find_by).and_return(message)
  end

  def stub_execution(returns:)
    execution = instance_double(Marine::Decision::ShadowExecution, call: returns)
    allow(Marine::Decision::ShadowExecution).to receive(:new).and_return(execution)
    execution
  end

  # Simulate the Redis NX completion marker: a genuine first claim (true) then release/re-claim.
  def stub_marker(claim: true)
    allow(Redis::Alfred).to receive(:set).and_return(claim)
    allow(Redis::Alfred).to receive(:delete_if_equals).and_return(true)
  end

  it 'does nothing (no load, no execution, no metrics) when the shadow flag is off for the assistant' do
    allow(Marine::Decision::ShadowConfig).to receive(:enabled_for?).with(3).and_return(false)
    expect(Account).not_to receive(:find_by)
    expect(Marine::Decision::ShadowExecution).not_to receive(:new)
    expect(Marine::Decision::ShadowMetricsStore).not_to receive(:record)
    job.perform(1, 3, 5, 9)
  end

  it 're-checks the loaded assistant id and does not run the execution when no longer allowlisted' do
    stub_loads
    allow(Marine::Decision::ShadowConfig).to receive(:enabled_for?).with(3).and_return(true, false)
    expect(Marine::Decision::ShadowExecution).not_to receive(:new)
    expect(Marine::Decision::ShadowMetricsStore).not_to receive(:record)
    job.perform(1, 3, 5, 9)
  end

  it 'records a privacy-safe observation for a genuine comparison' do
    stub_loads
    stub_execution(returns: result)
    stub_marker
    observation = instance_double(Marine::Decision::ShadowObservation)
    expect(Marine::Decision::ShadowObservation).to receive(:build)
      .with(result: result, account_id: 1, assistant_id: 3).and_return(observation)
    expect(Marine::Decision::ShadowMetricsStore).to receive(:record).with(observation).and_return(true)

    expect(job.perform(1, 3, 5, 9)).to be_nil
  end

  it 'records NOTHING (no fake comparison) when the execution returns nil' do
    stub_loads
    stub_execution(returns: nil)
    expect(Marine::Decision::ShadowObservation).not_to receive(:build)
    expect(Marine::Decision::ShadowMetricsStore).not_to receive(:record)

    expect(job.perform(1, 3, 5, 9)).to be_nil
  end

  it 'ignores the metrics result (never influences the flow)' do
    stub_loads
    stub_execution(returns: result)
    stub_marker
    allow(Marine::Decision::ShadowObservation).to receive(:build).and_return(double('observation'))
    allow(Marine::Decision::ShadowMetricsStore).to receive(:record).and_return(false)

    expect(job.perform(1, 3, 5, 9)).to be_nil
  end

  it 'stops safely when a scoped record is missing' do
    stub_loads
    allow(Marine::Assistant).to receive(:find_by).with(id: 3, account_id: 1).and_return(nil)
    expect(Marine::Decision::ShadowExecution).not_to receive(:new)
    expect { job.perform(1, 3, 5, 9) }.not_to raise_error
  end

  it 'ignores a private message' do
    stub_loads
    allow(message).to receive(:private?).and_return(true)
    expect(Marine::Decision::ShadowExecution).not_to receive(:new)
    job.perform(1, 3, 5, 9)
  end

  it 'ignores an outgoing message' do
    stub_loads
    allow(message).to receive(:incoming?).and_return(false)
    expect(Marine::Decision::ShadowExecution).not_to receive(:new)
    job.perform(1, 3, 5, 9)
  end

  it 'swallows an execution failure without re-raising or logging' do
    stub_loads
    execution = instance_double(Marine::Decision::ShadowExecution)
    allow(Marine::Decision::ShadowExecution).to receive(:new).and_return(execution)
    allow(execution).to receive(:call).and_raise(StandardError, 'boom')
    expect(ChatwootExceptionTracker).not_to receive(:new)

    expect { job.perform(1, 3, 5, 9) }.not_to raise_error
  end

  it 'swallows an observation build failure without re-raising' do
    stub_loads
    stub_execution(returns: result)
    allow(Marine::Decision::ShadowObservation).to receive(:build).and_raise(Marine::Decision::ShadowObservation::Invalid)
    expect(Marine::Decision::ShadowMetricsStore).not_to receive(:record)

    expect { job.perform(1, 3, 5, 9) }.not_to raise_error
  end

  it 'swallows a metrics failure without re-raising' do
    stub_loads
    stub_execution(returns: result)
    stub_marker
    allow(Marine::Decision::ShadowObservation).to receive(:build).and_return(double('observation'))
    allow(Marine::Decision::ShadowMetricsStore).to receive(:record).and_raise(StandardError, 'redis down')

    expect { job.perform(1, 3, 5, 9) }.not_to raise_error
  end

  # Phase 2 / Stage 5 — AGGREGATE-recording idempotency against a duplicate/redelivered ActiveJob.
  # The marker keys on the stable, non-customer ActiveJob job_id (a UUID) so the same delivery can
  # never increment counters twice, while a genuine retry after a failed record can still record.
  describe 'metrics idempotency (job_id NX completion marker)' do
    # An in-memory NX marker store keyed exactly as the job constructs it, so redelivery/retry
    # semantics are exercised for real (claim, duplicate-skip, compare-and-delete release).
    def fake_marker_store
      store = {}
      allow(Redis::Alfred).to receive(:set) do |key, value, nx:, ex:|
        expect(nx).to be(true)
        expect(ex).to eq(described_class::COMPLETION_TTL_SECONDS)
        if store.key?(key)
          nil
        else
          store[key] = value
          true
        end
      end
      allow(Redis::Alfred).to receive(:delete_if_equals) do |key, value|
        store.delete(key) if store[key] == value
      end
      store
    end

    it 'records once for the same job_id delivered twice, keying only on the job_id' do
      stub_loads
      stub_execution(returns: result)
      allow(Marine::Decision::ShadowObservation).to receive(:build).and_return(double('observation'))
      store = fake_marker_store
      expect(Marine::Decision::ShadowMetricsStore).to receive(:record).once.and_return(true)

      job.perform(1, 3, 5, 9)
      job.perform(1, 3, 5, 9) # same instance => same job_id => redelivery is skipped

      expect(store.keys).to eq(["#{described_class::COMPLETION_KEY_PREFIX}:#{job.job_id}"])
    end

    it 'releases the owner on a failed first record so a genuine retry can record' do
      stub_loads
      stub_execution(returns: result)
      allow(Marine::Decision::ShadowObservation).to receive(:build).and_return(double('observation'))
      store = fake_marker_store
      allow(Marine::Decision::ShadowMetricsStore).to receive(:record).and_return(false, true)

      job.perform(1, 3, 5, 9) # record fails => marker released
      expect(store).to be_empty
      job.perform(1, 3, 5, 9) # retry re-claims and records

      expect(Marine::Decision::ShadowMetricsStore).to have_received(:record).twice
      expect(store.keys).to eq(["#{described_class::COMPLETION_KEY_PREFIX}:#{job.job_id}"])
    end

    it 'records for two different job_ids (each delivery is distinct)' do
      stub_loads
      stub_execution(returns: result)
      allow(Marine::Decision::ShadowObservation).to receive(:build).and_return(double('observation'))
      store = fake_marker_store
      expect(Marine::Decision::ShadowMetricsStore).to receive(:record).twice.and_return(true)

      described_class.new.perform(1, 3, 5, 9)
      described_class.new.perform(1, 3, 5, 9) # a distinct job instance => distinct job_id

      expect(store.size).to eq(2)
    end

    it 'claims the exact key/TTL/token and releases the same key+token on record failure' do
      stub_loads
      stub_execution(returns: result)
      allow(Marine::Decision::ShadowObservation).to receive(:build).and_return(double('observation'))
      key = "#{described_class::COMPLETION_KEY_PREFIX}:#{job.job_id}"
      allow(Marine::Decision::ShadowMetricsStore).to receive(:record).and_return(false)
      expect(Redis::Alfred).to receive(:set)
        .with(key, kind_of(String), nx: true, ex: described_class::COMPLETION_TTL_SECONDS).and_return(true)
      expect(Redis::Alfred).to receive(:delete_if_equals).with(key, kind_of(String))

      job.perform(1, 3, 5, 9)
    end

    it 'records nothing (no raise) for an invalid job_id' do
      stub_loads
      stub_execution(returns: result)
      allow(Marine::Decision::ShadowObservation).to receive(:build).and_return(double('observation'))
      allow(job).to receive(:job_id).and_return('!!bad!!')
      expect(Redis::Alfred).not_to receive(:set)
      expect(Marine::Decision::ShadowMetricsStore).not_to receive(:record)

      expect { job.perform(1, 3, 5, 9) }.not_to raise_error
    end

    it 'records nothing (no raise) when the Redis claim itself fails' do
      stub_loads
      stub_execution(returns: result)
      allow(Marine::Decision::ShadowObservation).to receive(:build).and_return(double('observation'))
      allow(Redis::Alfred).to receive(:set).and_raise(StandardError, 'redis down')
      expect(Marine::Decision::ShadowMetricsStore).not_to receive(:record)

      expect { job.perform(1, 3, 5, 9) }.not_to raise_error
    end

    it 'skips the record when the marker is already held (duplicate claim)' do
      stub_loads
      stub_execution(returns: result)
      allow(Marine::Decision::ShadowObservation).to receive(:build).and_return(double('observation'))
      allow(Redis::Alfred).to receive(:set).and_return(nil) # NX conflict
      expect(Marine::Decision::ShadowMetricsStore).not_to receive(:record)
      expect(Redis::Alfred).not_to receive(:delete_if_equals)

      expect(job.perform(1, 3, 5, 9)).to be_nil
    end

    it 'builds the marker key from the job_id only — never a message/conversation/contact id' do
      key = job.send(:completion_key, job.job_id)
      # The only dynamic segment is the job_id; the account/conversation/message ids never appear.
      expect(key.split(':')).to eq(%w[marine decision shadow done v1] + [job.job_id])
    end
  end
end
