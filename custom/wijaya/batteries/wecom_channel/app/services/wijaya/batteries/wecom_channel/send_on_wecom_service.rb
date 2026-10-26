# frozen_string_literal: true

# Outbound delivery for a native Channel::Wecom inbox. Reuses the native
# Base::SendOnChannelService contract (private-note/echo/voice-call filtering,
# source_id loop guard) so WeCom behaves like any first-class channel.
#
# Sends text first (if present), then each attachment after a media/upload. On
# success the WeCom msgid is written to message.source_id (delivered); on any API
# error the Chatwoot message is marked failed with the provider error text.
module Wijaya
  module Batteries
    module WecomChannel
      class SendOnWecomService < Base::SendOnChannelService
        private

        ATTACHMENT_TYPE_MAP = {
          'image' => 'image',
          'audio' => 'voice',
          'video' => 'video'
        }.freeze

        def channel_class
          Channel::Wecom
        end

        def perform_reply
          msgid = dispatch_message
          message.update!(source_id: msgid) if msgid.present?
          Messages::StatusUpdateService.new(message, 'delivered').perform
        rescue StandardError => e
          Messages::StatusUpdateService.new(message, 'failed', provider_error(e)).perform
        end

        def dispatch_message
          return send_text if message.attachments.blank?

          send_with_attachments
        end

        def send_text
          client.send_text(touser: touser, open_kfid: channel.open_kfid, content: message.outgoing_content)['msgid']
        end

        def send_with_attachments
          last_msgid = nil
          last_msgid = send_text if message.outgoing_content.present?

          message.attachments.each do |attachment|
            media_id = upload(attachment)
            last_msgid = client.send_media(touser: touser, open_kfid: channel.open_kfid,
                                           msgtype: wecom_type(attachment), media_id: media_id)['msgid']
          end
          last_msgid
        end

        def upload(attachment)
          blob = attachment.file.blob
          blob.open do |tempfile|
            tempfile.rewind
            client.upload_media(io: tempfile, filename: blob.filename.to_s,
                                content_type: blob.content_type, type: wecom_type(attachment))
          end
        end

        def wecom_type(attachment)
          ATTACHMENT_TYPE_MAP[attachment.file_type.to_s] || 'file'
        end

        def touser
          contact_inbox.source_id
        end

        def client
          @client ||= ApiClient.new(channel)
        end

        def provider_error(error)
          error.is_a?(ApiClient::Error) ? error.message : 'Failed to deliver WeCom message'
        end
      end
    end
  end
end
