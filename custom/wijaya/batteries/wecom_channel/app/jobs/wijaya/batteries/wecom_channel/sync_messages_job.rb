# frozen_string_literal: true

# Pulls WeCom KF messages after a kf_msg_or_event callback. Serialized per channel
# with a Redis mutex so concurrent callbacks never race on the cursor. The cursor is
# advanced only after a page's messages are processed, so a crash mid-page reprocesses
# that page on the next run — dedupe on msgid (InboundMessageService) makes that safe.
module Wijaya
  module Batteries
    module WecomChannel
      class SyncMessagesJob < MutexApplicationJob
        queue_as :default
        retry_on LockAcquisitionError, wait: 2.seconds, attempts: 5

        MAX_PAGES = 100
        SYNC_LIMIT = 1000
        # A single drain pages at most MAX_PAGES times; each page is one HTTP call bounded
        # by the client's open+read timeout (per-message customer/media fetches add more,
        # but the cursor only advances after a page fully succeeds and dedupe makes a lapsed
        # lock safe). Size the mutex to cover that paging budget with headroom so a second
        # callback cannot race the cursor mid-drain.
        LOCK_TTL = (MAX_PAGES * (ApiClient::OPEN_TIMEOUT + ApiClient::READ_TIMEOUT)).seconds

        def perform(channel_id:, token:, open_kfid:)
          @channel = Channel::Wecom.find_by(id: channel_id)
          return if @channel.nil?

          with_lock("WIJAYA_WECOM_SYNC::#{@channel.id}", LOCK_TTL) { sync!(token, open_kfid) }
        end

        private

        def sync!(token, open_kfid)
          client = ApiClient.new(@channel)
          MAX_PAGES.times do
            response = client.sync_msg(cursor: @channel.sync_cursor, token: token, open_kfid: open_kfid, limit: SYNC_LIMIT)
            # A per-message failure propagates so the cursor is NOT advanced below and the
            # job retries from the same cursor; messages persisted earlier in the page are
            # deduped on msgid on retry. Losing a page to a transient error beats losing its
            # messages forever by advancing past them.
            Array(response['msg_list']).each { |msg| process_message(msg) }

            next_cursor = response['next_cursor']
            @channel.update!(sync_cursor: next_cursor) if next_cursor.present?
            break unless response['has_more'].to_i == 1
          end
        end

        def process_message(msg)
          InboundMessageService.new(channel: @channel, payload: msg.with_indifferent_access).perform
        rescue StandardError => e
          Rails.logger.error("[Wijaya] wecom inbound message failed: #{e.class}")
          raise
        end
      end
    end
  end
end
