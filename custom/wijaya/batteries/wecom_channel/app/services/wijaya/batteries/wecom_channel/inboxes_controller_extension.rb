# frozen_string_literal: true

# Teaches the native inbox-creation controller about the `wecom` channel type,
# mirroring how the Enterprise overlay bolts on `voice`. Prepended onto
# Api::V1::Accounts::InboxesController from a single removal-safe marker at the end
# of that controller, so the OSS method bodies stay pristine: strip the marker and
# the controller is byte-for-byte upstream. Each override delegates to `super` and
# only adds the WeCom case, composing cleanly with the Enterprise prepend.
module Wijaya
  module Batteries
    module WecomChannel
      module InboxesControllerExtension
        CHANNEL_KEY = 'wecom'

        def allowed_channel_types
          super + [CHANNEL_KEY]
        end

        def channel_type_from_params
          super || ({ CHANNEL_KEY => Channel::Wecom }[permitted_params[:channel][:type]])
        end

        def account_channels_method
          super || ({ CHANNEL_KEY => Current.account.wecom_channels }[permitted_params[:channel][:type]])
        end
      end
    end
  end
end
