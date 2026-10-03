# frozen_string_literal: true

# Battery hooks invoked from native Chatwoot hot-path marker blocks through the
# fail-open Wijaya::Batteries::Core::Hooks dispatcher. All business logic lives
# here; the core marker is a single guarded dispatch call that returns the native
# default when this battery is missing/disabled/erroring.
#
# These hooks NEVER act on a non-whatsapp_web inbox, so no other API inbox is
# affected and no arbitrary mass assignment is introduced for them.
# rubocop:disable Style/ClassAndModuleChildren -- nested style preserves sibling constant resolution
module Wijaya::Batteries::WhatsappWebInbox
  module Hooks
    # Provider message ids (WhatsApp wamid / stanza ids) are opaque ASCII tokens.
    # Validate shape so a whatsapp_web inbox can never persist arbitrary input as
    # a source_id / reply id.
    PROVIDER_ID_RE = /\A[A-Za-z0-9._:=@-]{1,255}\z/

    module_function

    # Public API-Inbox inbound message creation seam. Only for a whatsapp_web
    # Channel::Api inbox: set the message source_id from the connector-supplied,
    # validated provider echo/message id, and permit ONLY a validated
    # in_reply_to_external_id (resolved to in_reply_to by the Message model's
    # ensure_in_reply_to callback through the normal save). Returns nil; the
    # caller saves the message exactly as upstream.
    def apply_public_inbound_message_attributes(message:, channel:, params:)
      return unless whatsapp_web_channel?(channel)

      provider_id = validated_provider_id(params[:source_id])
      message.source_id = provider_id if provider_id.present?

      reply_id = validated_provider_id(params[:in_reply_to_external_id])
      if reply_id.present?
        message.content_attributes ||= {}
        message.content_attributes[:in_reply_to_external_id] = reply_id
      end
      nil
    end

    def whatsapp_web_channel?(channel)
      return false unless channel.respond_to?(:additional_attributes)

      attrs = channel.additional_attributes
      attrs.is_a?(Hash) && attrs[Record::ADDITIONAL_ATTRIBUTES_KEY] == Record::PROVIDER
    end

    def validated_provider_id(value)
      return nil unless value.is_a?(String)

      stripped = value.strip
      return nil if stripped.empty?

      PROVIDER_ID_RE.match?(stripped) ? stripped : nil
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
