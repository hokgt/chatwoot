# frozen_string_literal: true

# Builds a Chatwoot message from a single WeCom kf/sync_msg entry.
#
# - Only customer-origin messages (origin == 3) are ingested; agent/system echoes
#   are skipped so we never duplicate outbound replies.
# - Dedupe is keyed on the WeCom msgid stored as message.source_id, so re-pulling a
#   cursor batch after a crash/retry never creates duplicates.
# - Contact source/identifier is the external_userid; display name + avatar are
#   enriched from kf/customer/batchget.
# - Media (image/voice/video/file) is downloaded via media/get and attached;
#   location/link are rendered as readable text; unknown types get the exact
#   placeholder "Unsupported WeCom message type: <type>".
module Wijaya
  module Batteries
    module WecomChannel
      class InboundMessageService
        CUSTOMER_ORIGIN = 3
        ATTACHMENT_TYPES = {
          'image' => :image,
          'voice' => :audio,
          'video' => :video,
          'file' => :file
        }.freeze

        pattr_initialize [:channel!, :payload!]

        def perform
          return unless customer_message?
          return if msgid.blank? || duplicate?
          return if blank_text?

          build_message
        end

        private

        def customer_message?
          payload['origin'].to_i == CUSTOMER_ORIGIN
        end

        # A text message with no content would fail Message validation and, because the
        # cursor only advances after a page fully succeeds, permanently stall the sync on
        # that one malformed payload. Skip it deterministically — there is nothing to lose
        # (media types carry an attachment, not text, so they are never skipped here).
        def blank_text?
          msgtype == 'text' && payload.dig('text', 'content').to_s.strip.empty?
        end

        def duplicate?
          Message.exists?(inbox_id: inbox.id, source_id: msgid)
        end

        def build_message
          message = conversation.messages.build(
            content: message_content,
            account_id: inbox.account_id,
            inbox_id: inbox.id,
            message_type: :incoming,
            sender: contact_inbox.contact,
            source_id: msgid,
            created_at: message_time
          )
          attach_media(message)
          message.save!
          message
        end

        def inbox
          channel.inbox
        end

        def contact_inbox
          @contact_inbox ||= ::ContactInboxWithContactBuilder.new(
            source_id: external_userid,
            inbox: inbox,
            contact_attributes: contact_attributes
          ).perform
        end

        def conversation
          @conversation ||= if inbox.lock_to_single_conversation
                              contact_inbox.conversations.order(created_at: :desc).first
                            else
                              contact_inbox.conversations.where.not(status: :resolved).order(created_at: :desc).first
                            end
          @conversation ||= ::Conversation.create!(
            account_id: inbox.account_id,
            inbox_id: inbox.id,
            contact_id: contact_inbox.contact_id,
            contact_inbox_id: contact_inbox.id
          )
        end

        def contact_attributes
          customer = fetch_customer
          {
            name: customer[:name].presence || external_userid,
            identifier: external_userid,
            avatar_url: customer[:avatar_url]
          }.compact
        end

        def fetch_customer
          response = ApiClient.new(channel).batch_customer([external_userid])
          record = Array(response['customer_list']).first || {}
          { name: record['nickname'], avatar_url: record['avatar'] }
        rescue ApiClient::Error
          {}
        end

        def message_content
          case msgtype
          when 'text' then payload.dig('text', 'content')
          when 'location' then location_text
          when 'link' then link_text
          when *ATTACHMENT_TYPES.keys then nil
          else "Unsupported WeCom message type: #{msgtype}"
          end
        end

        def location_text
          loc = payload['location'] || {}
          ["📍 #{loc['name']}".strip, loc['address'], coordinates(loc)].reject(&:blank?).join("\n")
        end

        def coordinates(loc)
          return if loc['latitude'].blank? || loc['longitude'].blank?

          "(#{loc['latitude']}, #{loc['longitude']})"
        end

        def link_text
          link = payload['link'] || {}
          [link['title'], link['desc'], link['url']].reject(&:blank?).join("\n")
        end

        def attach_media(message)
          file_type = ATTACHMENT_TYPES[msgtype]
          return unless file_type

          media_id = payload.dig(msgtype, 'media_id')
          return if media_id.blank?

          file = ApiClient.new(channel).download_media(media_id)
          message.attachments.new(
            account_id: inbox.account_id,
            file_type: file_type,
            file: { io: file, filename: file.original_filename.presence || "#{msgtype}_#{media_id}", content_type: file.content_type }
          )
        end

        def msgtype
          payload['msgtype'].to_s
        end

        def msgid
          payload['msgid']
        end

        def external_userid
          payload['external_userid']
        end

        def message_time
          time = payload['send_time']
          time.present? ? Time.zone.at(time.to_i) : Time.current
        end
      end
    end
  end
end
