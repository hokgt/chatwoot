# frozen_string_literal: true

# Discovers the Open KF ID for a Channel::Wecom once its Secret has been saved.
#
# Staged setup step 2d: after callback verification WeCom reveals the 微信客服 Secret;
# the agent saves it. We then ask kf/account/list and auto-fill Open KF ID ONLY when
# the corp has exactly one KF account. When the corp exposes several accounts we
# deliberately do NOT choose one — ambiguous auto-selection would silently bind the
# inbox to the wrong KF account. In that case the Open KF ID is left blank for the
# agent to pick/paste in the inbox configuration panel (safe, deterministic).
module Wijaya
  module Batteries
    module WecomChannel
      class KfAccountDiscovery
        pattr_initialize [:channel!]

        def perform
          return if channel.secret.blank? || channel.open_kfid.present?

          accounts = fetch_accounts
          return unless accounts.size == 1

          # Guard against a concurrent save that already set open_kfid.
          channel.with_lock do
            channel.update!(open_kfid: accounts.first['open_kfid']) if channel.open_kfid.blank?
          end
        rescue ApiClient::Error => e
          Rails.logger.error("[Wijaya] wecom kf account discovery failed: #{e.class}")
        end

        private

        def fetch_accounts
          response = ApiClient.new(channel).kf_account_list
          Array(response['account_list']).select { |account| account['open_kfid'].present? }
        end
      end
    end
  end
end
