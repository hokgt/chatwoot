# frozen_string_literal: true

require 'rails_helper'

# Trigger contract for the deferred auto-assignment battery: real availability and presence
# transitions enqueue per-inbox processing (coalesced) for exactly the agent's marked inboxes;
# irrelevant transitions and repeated heartbeats do not.
RSpec.describe 'Deferred auto-assignment triggers', type: :model do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:user) { create(:user, account: account) }

  describe Wijaya::Batteries::DeferredAutoAssignment::Hooks do
    before { allow(Wijaya::Batteries::DeferredAutoAssignment::TriggerService).to receive(:enqueue_for_agent) }

    it 'enqueues on an offline -> online transition' do
      described_class.on_agent_available(account_id: account.id, user_id: user.id,
                                         previous_availability: 'offline', current_availability: 'online')

      expect(Wijaya::Batteries::DeferredAutoAssignment::TriggerService)
        .to have_received(:enqueue_for_agent).with(account_id: account.id, user_id: user.id)
    end

    it 'enqueues on a busy -> online transition' do
      described_class.on_agent_available(account_id: account.id, user_id: user.id,
                                         previous_availability: 'busy', current_availability: 'online')

      expect(Wijaya::Batteries::DeferredAutoAssignment::TriggerService).to have_received(:enqueue_for_agent)
    end

    it 'does not enqueue for a transition that does not end online' do
      described_class.on_agent_available(account_id: account.id, user_id: user.id,
                                         previous_availability: 'online', current_availability: 'busy')

      expect(Wijaya::Batteries::DeferredAutoAssignment::TriggerService).not_to have_received(:enqueue_for_agent)
    end

    it 'does not enqueue when the previous state was already online' do
      described_class.on_agent_available(account_id: account.id, user_id: user.id,
                                         previous_availability: 'online', current_availability: 'online')

      expect(Wijaya::Batteries::DeferredAutoAssignment::TriggerService).not_to have_received(:enqueue_for_agent)
    end
  end

  describe 'AccountUser availability callback' do
    it 'fires on a real offline -> online commit with the account/user' do
      # The :user factory already creates this account_user (default online); transition it.
      account_user = user.account_users.find_by!(account_id: account.id)
      account_user.update!(availability: :offline)
      allow(Wijaya::Batteries::DeferredAutoAssignment::TriggerService).to receive(:enqueue_for_agent)

      account_user.update!(availability: :online)

      expect(Wijaya::Batteries::DeferredAutoAssignment::TriggerService)
        .to have_received(:enqueue_for_agent).with(account_id: account.id, user_id: user.id)
    end
  end

  describe Wijaya::Batteries::DeferredAutoAssignment::TriggerService do
    it 'enqueues only for the agent inboxes that currently hold a marker' do
      allow(Wijaya::Batteries::DeferredAutoAssignment::ProcessInboxJob).to receive(:enqueue_for_inbox)
      marked_inbox = create(:inbox, account: account)
      member_no_marker = create(:inbox, account: account)
      create(:inbox_member, inbox: marked_inbox, user: user)
      create(:inbox_member, inbox: member_no_marker, user: user)
      conversation = create(:conversation, account: account, inbox: marked_inbox)
      Wijaya::Batteries::DeferredAutoAssignment::Marker.where(conversation_id: conversation.id)
                                                       .first_or_create!(account: account, inbox: marked_inbox)

      described_class.enqueue_for_agent(account_id: account.id, user_id: user.id)

      expect(Wijaya::Batteries::DeferredAutoAssignment::ProcessInboxJob).to have_received(:enqueue_for_inbox).with(marked_inbox.id)
      expect(Wijaya::Batteries::DeferredAutoAssignment::ProcessInboxJob).not_to have_received(:enqueue_for_inbox).with(member_no_marker.id)
    end
  end

  describe Wijaya::Batteries::DeferredAutoAssignment::ProcessInboxJob do
    include ActiveJob::TestHelper

    it 'coalesces: a second enqueue while one is in-flight is skipped' do
      key = format(described_class::IN_FLIGHT_KEY, inbox_id: inbox.id)
      Redis::Alfred.delete(key)

      expect(described_class.enqueue_for_inbox(inbox.id)).to be(true)
      expect(described_class.enqueue_for_inbox(inbox.id)).to be(false)
    ensure
      Redis::Alfred.delete(key)
    end
  end
end
