# frozen_string_literal: true

require 'rails_helper'

# Presence trigger for the deferred auto-assignment battery. This is a channel test (the
# channel is inferred from the described class), so it lives in its own file. An actual
# absent -> present User transition fires on_agent_present exactly once; a repeated heartbeat
# while already present does not re-fire.
RSpec.describe RoomChannel, type: :channel do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  around do |example|
    example.run
  ensure
    Redis::Alfred.delete(OnlineStatusTracker.presence_key(account.id, 'User'))
  end

  it 'triggers deferred processing once on absent -> present and not again on a repeated heartbeat' do
    Redis::Alfred.delete(OnlineStatusTracker.presence_key(account.id, 'User'))
    allow(Wijaya::Batteries::DeferredAutoAssignment::TriggerService).to receive(:enqueue_for_agent)
    stub_connection

    subscribe(user_id: user.id, pubsub_token: user.pubsub_token, account_id: account.id)
    expect(Wijaya::Batteries::DeferredAutoAssignment::TriggerService)
      .to have_received(:enqueue_for_agent).with(account_id: account.id, user_id: user.id).once

    # Repeated heartbeat while already present must not re-trigger.
    perform(:update_presence)
    expect(Wijaya::Batteries::DeferredAutoAssignment::TriggerService).to have_received(:enqueue_for_agent).once
  end
end
