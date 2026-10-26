# frozen_string_literal: true

# Fail-open seams invoked by native Chatwoot hot paths via
# Wijaya::Batteries::Core::Hooks.dispatch. Each returns the caller-supplied native
# default on any error so a missing/broken battery never changes native behaviour.
module Wijaya
  module Batteries
    module WecomChannel
      module Hooks
        module_function

        # Dispatched from SendReplyJob#perform. Returns true when the message belongs
        # to a native Channel::Wecom inbox and we handled delivery (native dispatch
        # then stops); false for every other channel so they send as usual.
        def send_reply(message:)
          return false unless message.conversation.inbox.channel.is_a?(Channel::Wecom)

          SendOnWecomService.new(message: message).perform
          true
        end

        # Dispatched from Channel::Wecom#discover_open_kfid after the Secret is first
        # saved. Enqueues the async kf/account/list Open KF ID discovery.
        def secret_configured(channel:)
          AutofillKfAccountJob.perform_later(channel_id: channel.id)
          true
        end
      end
    end
  end
end
