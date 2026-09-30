# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 4 — the DEFAULT-OFF, fail-safe ShadowEnqueuer. These examples drive it with
# record doubles + a stubbed flag and pin: default-off does NO Redis and NO enqueue; enabled
# uses an NX+TTL feature-prefixed marker, passes SCALAR IDs only, suppresses a duplicate, and
# releases only its own token (compare-and-delete) when the enqueue fails; and every
# config/Redis/job failure returns false and never raises.
RSpec.describe Marine::Decision::ShadowEnqueuer do
  let(:assistant) { double('assistant', id: 3) }
  let(:inbox) { double('inbox', marine_assistant: assistant) }
  let(:account) { double('account', id: 1) }
  let(:conversation) { double('conversation', id: 5, account: account, inbox: inbox) }
  let(:message) { double('message', id: 9) }

  def enqueue
    described_class.enqueue(conversation: conversation, message: message)
  end

  context 'when the shadow is off (default)' do
    before { allow(Marine::Decision::ShadowConfig).to receive(:enabled?).and_return(false) }

    it 'touches no Redis and enqueues no job, returning false' do
      expect(Redis::Alfred).not_to receive(:set)
      expect(Marine::Decision::ShadowJob).not_to receive(:perform_later)
      expect(enqueue).to be(false)
    end
  end

  context 'when the shadow is on' do
    before { allow(Marine::Decision::ShadowConfig).to receive(:enabled?).and_return(true) }

    it 'sets an NX+TTL feature-prefixed marker and enqueues the job with scalar IDs, retaining the token' do
      expect(Redis::Alfred).to receive(:set)
        .with("#{described_class::KEY_PREFIX}:1:9", kind_of(String), nx: true, ex: described_class::DEDUPE_TTL_SECONDS)
        .and_return(true)
      expect(Marine::Decision::ShadowJob).to receive(:perform_later)
        .with(1, 3, 5, 9).and_return(double('job', successfully_enqueued?: true))
      expect(Redis::Alfred).not_to receive(:delete_if_equals)

      expect(enqueue).to be(true)
    end

    it 'counts a legacy/test truthy job (neither enqueue API) as success and keeps the token' do
      allow(Redis::Alfred).to receive(:set).and_return(true)
      allow(Marine::Decision::ShadowJob).to receive(:perform_later).and_return(Object.new)
      expect(Redis::Alfred).not_to receive(:delete_if_equals)

      expect(enqueue).to be(true)
    end

    it 'suppresses a duplicate (NX marker already held) without enqueuing' do
      allow(Redis::Alfred).to receive(:set).and_return(false)
      expect(Marine::Decision::ShadowJob).not_to receive(:perform_later)
      expect(enqueue).to be(false)
    end

    # perform_later returns false (a before_enqueue callback halted the chain): release the
    # exact key+token and fail closed.
    it 'releases only its own token and returns false when perform_later returns false' do
      allow(Redis::Alfred).to receive(:set).and_return(true)
      allow(Marine::Decision::ShadowJob).to receive(:perform_later).and_return(false)
      expect(Redis::Alfred).to receive(:delete_if_equals).with("#{described_class::KEY_PREFIX}:1:9", kind_of(String))

      expect(enqueue).to be(false)
    end

    it 'releases only its own token and returns false when the job is not successfully_enqueued?' do
      allow(Redis::Alfred).to receive(:set).and_return(true)
      allow(Marine::Decision::ShadowJob).to receive(:perform_later).and_return(double('job', successfully_enqueued?: false))
      expect(Redis::Alfred).to receive(:delete_if_equals).with("#{described_class::KEY_PREFIX}:1:9", kind_of(String))

      expect(enqueue).to be(false)
    end

    it 'releases only its own token and returns false when the job carries a non-nil enqueue_error' do
      allow(Redis::Alfred).to receive(:set).and_return(true)
      job = double('job', enqueue_error: 'adapter down')
      allow(Marine::Decision::ShadowJob).to receive(:perform_later).and_return(job)
      expect(Redis::Alfred).to receive(:delete_if_equals).with("#{described_class::KEY_PREFIX}:1:9", kind_of(String))

      expect(enqueue).to be(false)
    end

    it 'releases only its own token and returns false when the enqueue raises' do
      allow(Redis::Alfred).to receive(:set).and_return(true)
      allow(Marine::Decision::ShadowJob).to receive(:perform_later).and_raise(StandardError, 'queue down')
      expect(Redis::Alfred).to receive(:delete_if_equals).with("#{described_class::KEY_PREFIX}:1:9", kind_of(String))

      expect(enqueue).to be(false)
    end

    it 'swallows a delete failure while releasing an unsuccessful enqueue and still returns false' do
      allow(Redis::Alfred).to receive(:set).and_return(true)
      allow(Marine::Decision::ShadowJob).to receive(:perform_later).and_return(nil)
      allow(Redis::Alfred).to receive(:delete_if_equals).and_raise(StandardError, 'redis down')

      expect { expect(enqueue).to be(false) }.not_to raise_error
    end

    it 'returns false (never raises) when Redis itself fails' do
      allow(Redis::Alfred).to receive(:set).and_raise(StandardError, 'redis down')
      expect { expect(enqueue).to be(false) }.not_to raise_error
    end

    it 'returns false when the inbox exposes no marine assistant' do
      allow(inbox).to receive(:marine_assistant).and_return(nil)
      expect(Redis::Alfred).not_to receive(:set)
      expect(enqueue).to be(false)
    end
  end

  it 'returns false (never raises) when the config check itself fails' do
    allow(Marine::Decision::ShadowConfig).to receive(:enabled?).and_raise(StandardError, 'boom')
    expect { expect(enqueue).to be(false) }.not_to raise_error
  end
end
