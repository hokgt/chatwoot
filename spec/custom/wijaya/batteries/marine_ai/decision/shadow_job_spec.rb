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

  before do
    allow(Marine::Decision::ShadowConfig).to receive(:enabled_for?).with(3).and_return(true)
    # The Phase 2A authority hook is now part of #perform; default it to a no-op double so the
    # Decision metrics examples below stay focused on the metrics contract. The dedicated
    # 'authority shadow hook (Phase 2A)' describe overrides this with concrete expectations.
    allow(Marine::Backend::AuthorityShadowExecution).to receive(:new)
      .and_return(instance_double(Marine::Backend::AuthorityShadowExecution, call: nil))
  end

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

  # Phase 2A (PRICE-ONLY shadow bridge) — the additive, independently-rescued AuthorityShadowExecution
  # hook. It runs AFTER the existing metrics attempt, inside the same enabled_for? gate, reusing the
  # already-computed result[:candidate_plan] (no second Decision Runner / provider call), and can never
  # affect the Decision shadow/metrics behavior or the primary flow.
  describe 'authority shadow hook (Phase 2A)' do
    before do
      stub_loads
      stub_execution(returns: result)
      stub_marker
      allow(Marine::Decision::ShadowObservation).to receive(:build).and_return(double('observation'))
      allow(Marine::Decision::ShadowMetricsStore).to receive(:record).and_return(true)
      # Keep these examples focused on the Authority hook; the Langkah 3 Model 2 hook has its own
      # describe below. Default it to a no-op so a non-nil authority result does not drive the real
      # Model 2 execution against these bare record doubles.
      allow(Marine::Backend::Model2ShadowExecution).to receive(:new)
        .and_return(instance_double(Marine::Backend::Model2ShadowExecution, call: nil))
    end

    it 'invokes AuthorityShadowExecution with the full records + the REUSED candidate_plan' do
      authority = instance_double(Marine::Backend::AuthorityShadowExecution, call: double('authority_result'))
      expect(Marine::Backend::AuthorityShadowExecution).to receive(:new).with(
        account: account, assistant: assistant, conversation: conversation, message: message,
        candidate_plan: result[:candidate_plan]
      ).and_return(authority)

      expect(job.perform(1, 3, 5, 9)).to be_nil
    end

    it 'never runs a second Decision Runner / shadow execution (reuses the plan)' do
      allow(Marine::Backend::AuthorityShadowExecution).to receive(:new).and_return(double('authority', call: nil))
      # ShadowExecution.new was already stubbed once by stub_execution; the hook must not build another.
      expect(Marine::Decision::Runner).not_to receive(:new)

      job.perform(1, 3, 5, 9)
    end

    it 'swallows an authority-hook failure without re-raising or disturbing metrics' do
      allow(Marine::Decision::ShadowMetricsStore).to receive(:record).and_return(true)
      authority = instance_double(Marine::Backend::AuthorityShadowExecution)
      allow(Marine::Backend::AuthorityShadowExecution).to receive(:new).and_return(authority)
      allow(authority).to receive(:call).and_raise(StandardError, 'boom')
      expect(ChatwootExceptionTracker).not_to receive(:new)

      expect { job.perform(1, 3, 5, 9) }.not_to raise_error
    end

    it 'does not run the authority hook when the execution returned nil' do
      stub_execution(returns: nil)
      expect(Marine::Backend::AuthorityShadowExecution).not_to receive(:new)

      job.perform(1, 3, 5, 9)
    end
  end

  # Langkah 3 (Evidence Packet -> Model 2 SHADOW) — the additive, independently-rescued Model 2 shadow
  # hook. It runs AFTER AuthorityShadowExecution inside the same enabled_for? gate, REUSING that hook's
  # single AuthorityCoordinator::Result (no second Authority/Decision/JEV call), and can never affect
  # the Authority shadow, Decision metrics, or the primary flow.
  describe 'model 2 shadow hook (Langkah 3)' do
    let(:authority_result) { double('authority_result') }

    before do
      stub_loads
      stub_execution(returns: result)
      stub_marker
      allow(Marine::Decision::ShadowObservation).to receive(:build).and_return(double('observation'))
      allow(Marine::Decision::ShadowMetricsStore).to receive(:record).and_return(true)
      allow(Marine::Backend::AuthorityShadowExecution).to receive(:new)
        .and_return(instance_double(Marine::Backend::AuthorityShadowExecution, call: authority_result))
    end

    it 'invokes Model2ShadowExecution with the full records + the REUSED authority result' do
      model2 = instance_double(Marine::Backend::Model2ShadowExecution, call: double('result'))
      expect(Marine::Backend::Model2ShadowExecution).to receive(:new).with(
        account: account, assistant: assistant, conversation: conversation, message: message,
        authority_result: authority_result
      ).and_return(model2)

      expect(job.perform(1, 3, 5, 9)).to be_nil
    end

    it 'does not run Model 2 when the authority hook returned nil' do
      allow(Marine::Backend::AuthorityShadowExecution).to receive(:new)
        .and_return(instance_double(Marine::Backend::AuthorityShadowExecution, call: nil))
      expect(Marine::Backend::Model2ShadowExecution).not_to receive(:new)

      job.perform(1, 3, 5, 9)
    end

    it 'swallows a Model 2 failure without re-raising or disturbing metrics' do
      model2 = instance_double(Marine::Backend::Model2ShadowExecution)
      allow(Marine::Backend::Model2ShadowExecution).to receive(:new).and_return(model2)
      allow(model2).to receive(:call).and_raise(StandardError, 'boom')
      expect(ChatwootExceptionTracker).not_to receive(:new)

      expect { job.perform(1, 3, 5, 9) }.not_to raise_error
    end

    it 'reuses one Decision result and one Authority result (no second Runner call)' do
      allow(Marine::Backend::Model2ShadowExecution).to receive(:new)
        .and_return(instance_double(Marine::Backend::Model2ShadowExecution, call: nil))
      expect(Marine::Decision::Runner).not_to receive(:new)
      expect(Marine::Backend::AuthorityShadowExecution).to receive(:new).once
                                                                        .and_return(instance_double(Marine::Backend::AuthorityShadowExecution,
                                                                                                    call: authority_result))

      job.perform(1, 3, 5, 9)
    end
  end

  # Langkah 3 observability — the Model 2 Result is OBSERVED (projected to a bounded status/reason
  # aggregate counter) but NEVER delivered. These examples pin: a genuine deep-frozen Result projects
  # to a privacy-safe observation and records ONE aggregate per delivery under an INDEPENDENT job_id
  # marker; the raw Result object is never handed to the store; a non-Result / Redis failure is
  # swallowed without disturbing the Decision metric or the primary flow; and perform stays nil.
  describe 'model 2 aggregate observability (Langkah 3)' do
    let(:authority_result) { double('authority_result') }

    def model2_result(status, reason)
      Marine::Backend::Model2ShadowExecution::Result.new(status: status, reason: reason).freeze
    end

    def stub_model2(returns:)
      model2 = instance_double(Marine::Backend::Model2ShadowExecution, call: returns)
      allow(Marine::Backend::Model2ShadowExecution).to receive(:new).and_return(model2)
      model2
    end

    # In-memory NX marker store keyed exactly as the job builds it, so both the Decision and the
    # Model 2 markers (distinct prefixes, same job_id) are exercised for real.
    def fake_marker_store
      store = {}
      allow(Redis::Alfred).to receive(:set) do |key, value, nx:, ex:|
        expect(nx).to be(true)
        expect(ex).to eq(described_class::COMPLETION_TTL_SECONDS)
        store.key?(key) ? nil : (store[key] = value) && true
      end
      allow(Redis::Alfred).to receive(:delete_if_equals) { |key, value| store.delete(key) if store[key] == value }
      store
    end

    before do
      stub_loads
      stub_execution(returns: result)
      allow(Marine::Decision::ShadowObservation).to receive(:build).and_return(double('decision_observation'))
      allow(Marine::Decision::ShadowMetricsStore).to receive(:record).and_return(true)
      allow(Marine::Backend::AuthorityShadowExecution).to receive(:new)
        .and_return(instance_double(Marine::Backend::AuthorityShadowExecution, call: authority_result))
    end

    it 'projects a genuine accepted Result and records ONE aggregate carrying only status/reason' do
      stub_model2(returns: model2_result(:accepted, :deliverable_wording))
      fake_marker_store
      recorded = nil
      expect(Marine::Backend::Model2ShadowMetricsStore).to(receive(:record).once do |obs|
        recorded = obs
        true
      end)

      expect(job.perform(1, 3, 5, 9)).to be_nil
      expect(recorded).to be_a(Marine::Backend::Model2ShadowObservation)
      expect(recorded.status).to eq(:accepted)
      expect(recorded.reason).to eq(:deliverable_wording)
    end

    it 'records a skipped.not_exact_price aggregate for a skipped Result' do
      stub_model2(returns: model2_result(:skipped, :not_exact_price))
      fake_marker_store
      recorded = nil
      expect(Marine::Backend::Model2ShadowMetricsStore).to(receive(:record).once do |obs|
        recorded = obs
        true
      end)

      job.perform(1, 3, 5, 9)
      expect([recorded.status, recorded.reason]).to eq(%i[skipped not_exact_price])
    end

    it 'never hands the raw Model 2 Result object to the store (projection only)' do
      raw = model2_result(:rejected, :fact_unverified)
      stub_model2(returns: raw)
      fake_marker_store
      expect(Marine::Backend::Model2ShadowMetricsStore).to receive(:record) do |obs|
        expect(obs).not_to be(raw)
        expect(obs).to be_a(Marine::Backend::Model2ShadowObservation)
        true
      end

      job.perform(1, 3, 5, 9)
    end

    it 'records the Model 2 aggregate at most once for a duplicate delivery (independent job_id marker)' do
      stub_model2(returns: model2_result(:accepted, :deliverable_wording))
      store = fake_marker_store
      expect(Marine::Backend::Model2ShadowMetricsStore).to receive(:record).once.and_return(true)

      job.perform(1, 3, 5, 9)
      job.perform(1, 3, 5, 9) # same instance => same job_id => model 2 redelivery is skipped

      expect(store.keys).to include("#{described_class::MODEL2_COMPLETION_KEY_PREFIX}:#{job.job_id}")
    end

    it 'claims the Decision and Model 2 aggregates under INDEPENDENT job_id markers (distinct prefixes)' do
      stub_model2(returns: model2_result(:accepted, :deliverable_wording))
      store = fake_marker_store
      allow(Marine::Backend::Model2ShadowMetricsStore).to receive(:record).and_return(true)

      job.perform(1, 3, 5, 9)

      expect(store.keys).to contain_exactly(
        "#{described_class::COMPLETION_KEY_PREFIX}:#{job.job_id}",
        "#{described_class::MODEL2_COMPLETION_KEY_PREFIX}:#{job.job_id}"
      )
    end

    it 'records nothing for a non-Result (fails closed, no raise) and leaves the Decision metric intact' do
      stub_model2(returns: double('not_a_result'))
      fake_marker_store
      expect(Marine::Backend::Model2ShadowMetricsStore).not_to receive(:record)

      expect { expect(job.perform(1, 3, 5, 9)).to be_nil }.not_to raise_error
      expect(Marine::Decision::ShadowMetricsStore).to have_received(:record) # decision path still ran
    end

    it 'swallows a Model 2 metrics-store failure without re-raising or disturbing the Decision metric' do
      stub_model2(returns: model2_result(:accepted, :deliverable_wording))
      fake_marker_store
      allow(Marine::Backend::Model2ShadowMetricsStore).to receive(:record).and_raise(StandardError, 'redis down')
      expect(ChatwootExceptionTracker).not_to receive(:new)

      expect { expect(job.perform(1, 3, 5, 9)).to be_nil }.not_to raise_error
    end

    it 'records no Model 2 aggregate when the authority hook returned nil (no fake comparison)' do
      allow(Marine::Backend::AuthorityShadowExecution).to receive(:new)
        .and_return(instance_double(Marine::Backend::AuthorityShadowExecution, call: nil))
      expect(Marine::Backend::Model2ShadowExecution).not_to receive(:new)
      expect(Marine::Backend::Model2ShadowMetricsStore).not_to receive(:record)

      job.perform(1, 3, 5, 9)
    end
  end
end
