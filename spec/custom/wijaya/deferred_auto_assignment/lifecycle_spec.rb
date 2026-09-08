# frozen_string_literal: true

require 'rails_helper'

# Marker lifecycle contract for the deferred auto-assignment battery, owned by the
# ConversationExtensions concern (not core). A marked, waiting conversation drops its marker
# the moment it stops being a deferred-assignment candidate — a human assignee is set, an
# agent bot takes ownership, or it leaves the open status — and the marker is cleaned up
# synchronously when the conversation is destroyed (no FK violation via destroy_async). A
# later manual unassignment never re-registers a marker.
RSpec.describe 'Deferred auto-assignment marker lifecycle', type: :model do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }

  before do
    # Nobody online, so a fresh conversation is created open+unassigned and marked.
    allow(OnlineStatusTracker).to receive(:get_available_users).and_return({})
    allow(AutoAssignment::AssignmentJob).to receive(:enqueue_for_inbox)
  end

  def make_agent
    user = create(:user, account: account, role: :agent)
    create(:inbox_member, inbox: inbox, user: user)
    user
  end

  def marked_conversation(params = {})
    Conversation.create!({ account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox }.merge(params))
  end

  def marker_for(conversation)
    Wijaya::Batteries::DeferredAutoAssignment::Marker.find_by(conversation_id: conversation.id)
  end

  it 'is created for a fresh open+unassigned conversation (baseline)' do
    conversation = marked_conversation
    expect(marker_for(conversation)).to be_present
  end

  it 'removes the marker immediately when a human agent is manually assigned' do
    agent = make_agent
    conversation = marked_conversation
    expect(marker_for(conversation)).to be_present

    conversation.update!(assignee: agent)

    expect(marker_for(conversation)).to be_nil
  end

  it 'removes the marker immediately when an agent bot takes ownership' do
    agent_bot = create(:agent_bot, account: account)
    conversation = marked_conversation
    expect(marker_for(conversation)).to be_present

    conversation.update!(assignee_agent_bot_id: agent_bot.id)

    expect(marker_for(conversation)).to be_nil
  end

  it 'removes the marker immediately when the conversation is resolved' do
    conversation = marked_conversation
    conversation.update!(status: :resolved)
    expect(marker_for(conversation)).to be_nil
  end

  it 'removes the marker immediately when the conversation is set to pending' do
    conversation = marked_conversation
    conversation.update!(status: :pending)
    expect(marker_for(conversation)).to be_nil
  end

  it 'removes the marker immediately when the conversation is snoozed' do
    conversation = marked_conversation
    conversation.update!(status: :snoozed, snoozed_until: 1.day.from_now)
    expect(marker_for(conversation)).to be_nil
  end

  it 'leaves the marker intact on an unrelated update (narrow gate)' do
    conversation = marked_conversation
    conversation.update!(priority: :high)
    expect(marker_for(conversation)).to be_present
  end

  it 'does not re-register a marker after a manual assign then unassign' do
    agent = make_agent
    conversation = marked_conversation

    conversation.update!(assignee: agent)   # marker removed here
    expect(marker_for(conversation)).to be_nil

    conversation.update!(assignee_id: nil)  # manual unassign must NOT re-register
    expect(marker_for(conversation)).to be_nil
  end

  it 'destroys the marker synchronously when the conversation is destroyed (no FK violation)' do
    conversation = marked_conversation
    marker = marker_for(conversation)
    expect(marker).to be_present

    expect { conversation.destroy! }.not_to raise_error
    expect(Wijaya::Batteries::DeferredAutoAssignment::Marker.exists?(marker.id)).to be(false)
  end
end
