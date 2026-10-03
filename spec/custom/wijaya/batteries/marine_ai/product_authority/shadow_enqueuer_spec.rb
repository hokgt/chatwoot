# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2 — the DEFAULT-OFF, fail-safe PRODUCT-authority ShadowEnqueuer. These examples drive it
# with record doubles + a stubbed assistant-scoped flag and pin: not-enabled-for-assistant does NO
# Redis and NO enqueue; enabled uses an NX+TTL PRODUCT-prefixed marker (a namespace distinct from the
# decision shadow), passes SCALAR IDs only, suppresses a duplicate, and releases only its own token
# (compare-and-delete) when the enqueue fails; and every config/Redis/job failure returns false and
# never raises. All strings are SYNTHETIC.
RSpec.describe Marine::ProductAuthority::ShadowEnqueuer do
  let(:assistant) { double('assistant', id: 3) }
  let(:inbox) { double('inbox', marine_assistant: assistant) }
  let(:account) { double('account', id: 1) }
  let(:conversation) { double('conversation', id: 5, account: account, inbox: inbox) }
  let(:message) { double('message', id: 9) }

  def enqueue
    described_class.enqueue(conversation: conversation, message: message)
  end

  it 'uses the PRODUCT namespace key prefix, distinct from the decision shadow' do
    expect(described_class::KEY_PREFIX).to eq('marine:product_authority:shadow:v1')
    expect(described_class::KEY_PREFIX).not_to eq(Marine::Decision::ShadowEnqueuer::KEY_PREFIX)
  end

  context 'when the shadow is not enabled for this assistant' do
    before { allow(Marine::ProductAuthority::ShadowConfig).to receive(:shadow_enabled_for?).with(3).and_return(false) }

    it 'touches no Redis and enqueues no job, returning false' do
      expect(Redis::Alfred).not_to receive(:set)
      expect(Marine::ProductAuthority::ShadowJob).not_to receive(:perform_later)
      expect(enqueue).to be(false)
    end
  end

  context 'when the shadow is on' do
    before { allow(Marine::ProductAuthority::ShadowConfig).to receive(:shadow_enabled_for?).with(3).and_return(true) }

    it 'sets an NX+TTL product-prefixed marker and enqueues the job with scalar IDs, retaining the token' do
      expect(Redis::Alfred).to receive(:set)
        .with("#{described_class::KEY_PREFIX}:1:9", kind_of(String), nx: true, ex: described_class::DEDUPE_TTL_SECONDS)
        .and_return(true)
      expect(Marine::ProductAuthority::ShadowJob).to receive(:perform_later)
        .with(1, 3, 5, 9).and_return(double('job', successfully_enqueued?: true))
      expect(Redis::Alfred).not_to receive(:delete_if_equals)

      expect(enqueue).to be(true)
    end

    it 'counts a legacy/test truthy job (neither enqueue API) as success and keeps the token' do
      allow(Redis::Alfred).to receive(:set).and_return(true)
      allow(Marine::ProductAuthority::ShadowJob).to receive(:perform_later).and_return(Object.new)
      expect(Redis::Alfred).not_to receive(:delete_if_equals)

      expect(enqueue).to be(true)
    end

    it 'suppresses a duplicate (NX marker already held) without enqueuing, returning false' do
      allow(Redis::Alfred).to receive(:set).and_return(false)
      expect(Marine::ProductAuthority::ShadowJob).not_to receive(:perform_later)
      expect(Redis::Alfred).not_to receive(:delete_if_equals)

      expect(enqueue).to be(false)
    end

    it 'releases only its own token and returns false when perform_later returns false' do
      allow(Redis::Alfred).to receive(:set).and_return(true)
      allow(Marine::ProductAuthority::ShadowJob).to receive(:perform_later).and_return(false)
      expect(Redis::Alfred).to receive(:delete_if_equals).with("#{described_class::KEY_PREFIX}:1:9", kind_of(String))

      expect(enqueue).to be(false)
    end

    it 'releases only its own token and returns false when the job is not successfully_enqueued?' do
      allow(Redis::Alfred).to receive(:set).and_return(true)
      allow(Marine::ProductAuthority::ShadowJob).to receive(:perform_later).and_return(double('job', successfully_enqueued?: false))
      expect(Redis::Alfred).to receive(:delete_if_equals).with("#{described_class::KEY_PREFIX}:1:9", kind_of(String))

      expect(enqueue).to be(false)
    end

    it 'releases only its own token and returns false when the job carries a non-nil enqueue_error' do
      allow(Redis::Alfred).to receive(:set).and_return(true)
      job = double('job', enqueue_error: 'adapter down')
      allow(Marine::ProductAuthority::ShadowJob).to receive(:perform_later).and_return(job)
      expect(Redis::Alfred).to receive(:delete_if_equals).with("#{described_class::KEY_PREFIX}:1:9", kind_of(String))

      expect(enqueue).to be(false)
    end

    it 'releases only its own token and returns false when the enqueue raises' do
      allow(Redis::Alfred).to receive(:set).and_return(true)
      allow(Marine::ProductAuthority::ShadowJob).to receive(:perform_later).and_raise(StandardError, 'queue down')
      expect(Redis::Alfred).to receive(:delete_if_equals).with("#{described_class::KEY_PREFIX}:1:9", kind_of(String))

      expect(enqueue).to be(false)
    end

    it 'returns false (never raises) when Redis.set itself fails' do
      allow(Redis::Alfred).to receive(:set).and_raise(StandardError, 'redis down')
      expect(Marine::ProductAuthority::ShadowJob).not_to receive(:perform_later)

      expect { expect(enqueue).to be(false) }.not_to raise_error
    end

    it 'returns false when the inbox exposes no marine assistant (never checks the flag)' do
      allow(inbox).to receive(:marine_assistant).and_return(nil)
      expect(Marine::ProductAuthority::ShadowConfig).not_to receive(:shadow_enabled_for?)
      expect(Redis::Alfred).not_to receive(:set)

      expect(enqueue).to be(false)
    end
  end

  it 'returns false (never raises) when the config check itself fails' do
    allow(Marine::ProductAuthority::ShadowConfig).to receive(:shadow_enabled_for?).and_raise(StandardError, 'boom')
    expect { expect(enqueue).to be(false) }.not_to raise_error
  end
end
