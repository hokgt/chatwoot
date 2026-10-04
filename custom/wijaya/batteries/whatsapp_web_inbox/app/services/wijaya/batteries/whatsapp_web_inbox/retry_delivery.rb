# frozen_string_literal: true

# Battery-owned resend of a FAILED outgoing WhatsApp Web message.
#
# The native retry (Api::V1::Accounts::Conversations::MessagesController#retry) only
# flips the record to `sent` and then fires a `message.updated` webhook. The connector
# delivers to WhatsApp on `message.created`, NOT on `message.updated`, so the native
# retry marks the message sent while nothing is ever re-sent to the recipient (the next
# brand-new message is the first thing the connector actually delivers). This service
# re-emits the SAME message as a `message.created` api_inbox webhook through the native
# signed Webhooks::Trigger, so the trusted-internal connector delivery and its
# fail-closed status handling are reused verbatim. It NEVER acts on a non whatsapp_web
# inbox, so every other API inbox keeps the native retry behaviour.
#
# rubocop:disable Style/ClassAndModuleChildren -- nested style preserves sibling constant resolution
module Wijaya::Batteries::WhatsappWebInbox
  class RetryDelivery
    LOCK_PREFIX = 'wijaya:wa_web:retry:'
    # Coalesce duplicate retry requests / duplicate jobs for the same message inside a
    # short window so a double click (or a re-enqueued job) can never produce two
    # provider sends. Comfortably longer than the synchronous webhook timeout.
    LOCK_TTL = 15
    # Shown when a resend is impossible because the inbox has no connector endpoint
    # configured. Replaces the opaque stored error so the agent sees an understandable
    # reason instead of a message that falsely claims it was sent.
    NO_CONNECTOR_ERROR = 'WhatsApp Web is not connected for this inbox. Reconnect it and try again.'

    def self.perform(message:)
      new(message).perform
    end

    def initialize(message)
      @message = message
    end

    # Returns true when this battery fully handled the retry (so the native path is
    # skipped); false to let the native retry run unchanged (non whatsapp_web inbox or
    # non-outgoing message).
    def perform
      return false unless whatsapp_web_outgoing?

      # Strict failed-status gate: only a genuinely FAILED send is ever re-delivered. A
      # repeated/direct retry POST on a message that is already sent/delivered/read must
      # never re-emit message.created — doing so would deliver a second copy to the
      # recipient (and with a blank source_id, bypass the provider-id guard below). Treat
      # it as handled (native retry stays skipped for this inbox) but do nothing.
      return true unless @message.failed?

      return true unless claim_retry_slot?

      # Idempotency / no duplicate send: a message that already carries a provider
      # message id was accepted by the provider once, so re-emitting message.created
      # would deliver it to the recipient twice. Leave it exactly as it is — never
      # fake `sent` on top of a real provider outcome.
      return true if @message.source_id.present?

      # Fail closed: validate the one delivery prerequisite BEFORE touching the status, so
      # a misconfigured inbox is never optimistically flipped to `sent` with nothing sent.
      return true unless connector_endpoint_present?

      reset_to_retry_state
      redeliver_as_created
      true
    end

    private

    def whatsapp_web_outgoing?
      @message.outgoing? && Hooks.whatsapp_web_channel?(@message.inbox&.channel)
    end

    # A resend can only reach the recipient if the inbox carries a connector webhook URL.
    # When it is missing, leave the message FAILED (never mark it sent) and replace the
    # opaque error with an understandable reason instead of a misleading sent state.
    def connector_endpoint_present?
      return true if @message.inbox.channel.webhook_url.present?

      Messages::StatusUpdateService.new(@message, 'failed', NO_CONNECTOR_ERROR).perform
      false
    end

    # SET NX EX — the first caller in the window wins; later duplicates fall through as an
    # idempotent no-op success. Fails closed (treat as already claimed) if Redis is
    # unavailable, so a flaky Redis can never open the door to a duplicate send.
    def claim_retry_slot?
      ::Redis::Alfred.set("#{LOCK_PREFIX}#{@message.id}", '1', nx: true, ex: LOCK_TTL)
    rescue StandardError
      false
    end

    # Put the message into a proper retry state: clear the failure and mark it
    # optimistically `sent` — exactly how a brand-new outgoing API message starts. The
    # real delivery below fail-closes it back to `failed` if the connector rejects it.
    def reset_to_retry_state
      Messages::StatusUpdateService.new(@message, 'sent').perform
    end

    # Re-emit the SAME message as a message.created api_inbox webhook, synchronously,
    # through the native signed trigger (trusted-internal delivery + fail-closed status).
    # On success the message stays `sent` and the connector's provider status callback
    # later advances it to delivered/read; on a transport/5xx failure the trigger marks
    # it `failed` with the error, so a connector failure is never shown as sent.
    def redeliver_as_created
      channel = @message.inbox.channel
      payload = @message.webhook_data.merge(event: 'message_created')
      Webhooks::Trigger.execute(channel.webhook_url, payload, :api_inbox_webhook,
                                secret: channel.secret, delivery_id: SecureRandom.uuid)
      @message.reload
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
