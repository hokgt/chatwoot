# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 4 — the DEFAULT-OFF, fire-and-forget ShadowJob. These examples drive
# perform with scalar IDs + stubbed finders/execution and pin: it re-checks the shadow flag,
# loads records account-scoped, ignores a missing/private/outgoing/cross-account turn,
# discards the execution result, and swallows any failure without re-raising.
RSpec.describe Marine::Decision::ShadowJob do
  subject(:job) { described_class.new }

  let(:account) { double('account', id: 1, conversations: conversations) }
  let(:assistant) { double('assistant', id: 3) }
  let(:conversation) { double('conversation', id: 5, messages: messages) }
  let(:message) { double('message', id: 9, incoming?: true, private?: false) }
  let(:conversations) { double('conversations') }
  let(:messages) { double('messages') }

  before { allow(Marine::Decision::ShadowConfig).to receive(:enabled?).and_return(true) }

  # Account-scoped finders: account -> assistant (scoped by account_id) -> conversation
  # (via account.conversations) -> message (via conversation.messages).
  def stub_loads
    allow(Account).to receive(:find_by).and_return(account)
    allow(Marine::Assistant).to receive(:find_by).with(id: 3, account_id: 1).and_return(assistant)
    allow(conversations).to receive(:find_by).and_return(conversation)
    allow(messages).to receive(:find_by).and_return(message)
  end

  it 'does nothing (no load, no execution) when the shadow flag is off' do
    allow(Marine::Decision::ShadowConfig).to receive(:enabled?).and_return(false)
    expect(Account).not_to receive(:find_by)
    expect(Marine::Decision::ShadowExecution).not_to receive(:new)
    job.perform(1, 3, 5, 9)
  end

  it 'runs the execution (result discarded) for a valid, scoped, public incoming turn' do
    stub_loads
    execution = instance_double(Marine::Decision::ShadowExecution, call: { candidate_plan: {} })
    expect(Marine::Decision::ShadowExecution).to receive(:new)
      .with(account: account, assistant: assistant, conversation: conversation, message: message)
      .and_return(execution)

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
end
