# frozen_string_literal: true

# Resolves which Channel::Wecom inbox an inbound corp-scoped callback belongs to.
#
# The callback URL is corp-scoped (/webhooks/wecom/:corp_id). A single verified
# Corp ID callback can front several KF-account inboxes that share the same Corp
# ID, Token and EncodingAESKey. The decrypted event carries the authoritative
# OpenKfId of the KF account that actually received the message; we route it to the
# inbox whose open_kfid matches, but ONLY among channels sharing the callback's
# Corp ID — never across corp/account boundaries. Verification (GET echostr) runs
# before any Secret or Open KF ID exists, so it uses only the corp's Token +
# EncodingAESKey; `siblings` returns every channel configured for that corp so the
# controller can validate the signature against each until one matches.
module Wijaya
  module Batteries
    module WecomChannel
      module ChannelResolver
        module_function

        # All channels configured for a Corp ID (crypto material is corp-level, so any
        # of them can verify the corp-scoped callback). Ordered deterministically.
        def siblings(corp_id)
          return Channel::Wecom.none if corp_id.blank?

          Channel::Wecom.where(corp_id: corp_id).order(:id)
        end

        # The inbox a decrypted event belongs to: the one in this corp whose
        # open_kfid matches the event's OpenKfId. nil (skip) when the KF account is
        # unknown or not yet linked to an inbox.
        def route_event(corp_id, event_open_kfid)
          return if corp_id.blank? || event_open_kfid.blank?

          Channel::Wecom.find_by(corp_id: corp_id, open_kfid: event_open_kfid)
        end
      end
    end
  end
end
