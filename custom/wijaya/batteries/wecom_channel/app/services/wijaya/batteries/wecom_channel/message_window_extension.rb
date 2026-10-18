# frozen_string_literal: true

# Gives a native Channel::Wecom inbox the WeCom 微信客服 reply window so the reply-box
# warning fires like TikTok/Instagram. WeCom allows agent replies for 48 hours after
# the customer's last message (and at most 5 replies); we model the time window here
# (the authoritative 5-reply cap is enforced provider-side, surfaced as a failed
# message if exceeded). Prepended onto Conversations::MessageWindowService from a
# single removal-safe marker so the OSS `messaging_window` case stays pristine.
module Wijaya
  module Batteries
    module WecomChannel
      module MessageWindowExtension
        WECOM_MESSAGING_WINDOW = 48.hours

        private

        def messaging_window
          return WECOM_MESSAGING_WINDOW if @conversation.inbox.channel_type == 'Channel::Wecom'

          super
        end
      end
    end
  end
end
