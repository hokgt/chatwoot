# frozen_string_literal: true

# Async Open KF ID discovery, enqueued when a Channel::Wecom Secret is first saved
# (see Channel::Wecom#discover_open_kfid via the wecom_channel hook). Kept off the
# request path so the credential save stays fast and a WeCom API hiccup never fails
# the update. Idempotent: KfAccountDiscovery no-ops if the Open KF ID is already set.
module Wijaya
  module Batteries
    module WecomChannel
      class AutofillKfAccountJob < ApplicationJob
        queue_as :default

        def perform(channel_id:)
          channel = Channel::Wecom.find_by(id: channel_id)
          return if channel.nil?

          KfAccountDiscovery.new(channel: channel).perform
        end
      end
    end
  end
end
