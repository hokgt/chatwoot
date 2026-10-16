# frozen_string_literal: true

# Nested (not compact `module Wijaya::Batteries::CustomRoles::FollowUpProvenance`)
# so this file is standalone-safe when required directly (the same convention as
# custom_roles/hooks.rb): it may be loaded before the Wijaya namespace exists.
#
# Server-issued, tamper-evident provenance for composer follow-up contexts.
#
# A follow_up_context returned by a Marine/Captain composer task is signed with
# Rails' application MessageVerifier (Rails.application.message_verifier — the
# application secret, never a hardcoded one) and bound, via the signing purpose,
# to the issuing account and — for conversation-bound origins — the authorized
# conversation display_id. A context-free origin (Marine rewrite/translate,
# Captain rewrite without a conversation_display_id) is bound to the account
# only and explicitly marked context-free.
#
# The token is COMPACT and OPAQUE: it signs only small provenance metadata
# (scheme version, account id, conversation binding / context-free marker) plus
# a SHA-256 digest of the canonical context. No raw context content — no
# original_context transcript, last_response, or history — ever enters the
# token, so a ~400k-char transcript cannot bloat or ride inside it.
#
# Follow-up requests verify the token BEFORE any FollowUpService instantiation:
# a missing, invalid, or tampered token, a token from another account, or a
# conversation-bound token replayed against a different conversation is rejected
# fail-closed (the caller renders a concise 422). The client-supplied context is
# accepted ONLY when its canonical SHA-256 digest matches the signed digest
# (constant-time comparison), so any changed client field is rejected — never
# silently ignored. Legacy unsigned contexts fail closed the same way.
#
# Called from the Marine tasks battery controller and the native Captain
# tasks_controller custom_roles_rbac touchpoint.
# rubocop:disable Style/ClassAndModuleChildren
module Wijaya
  module Batteries
    module CustomRoles
      module FollowUpProvenance
        VERIFIER_NAME = 'wijaya.composer_follow_up_provenance'
        TOKEN_KEY = 'token'
        REJECTION_ERROR = 'invalid_follow_up_context'

        module_function

        # Returns a response-safe copy of the follow_up_context carrying an opaque,
        # compact, tamper-evident token. conversation_display_id: nil (or blank)
        # issues a context-free, account-bound token.
        def attach_token(follow_up_context, account_id:, conversation_display_id: nil)
          canonical = canonicalize(follow_up_context)
          canonical.merge(TOKEN_KEY => issue_token(canonical, account_id: account_id, conversation_display_id: conversation_display_id))
        end

        # Returns the canonical client follow_up_context when it carries a valid,
        # untampered token bound to the requesting account (and, for a
        # conversation-bound token, the same authorized conversation); nil (fail
        # closed) otherwise. The digest is compared in constant time, so ANY
        # changed client field is rejected, never silently ignored.
        def verify_follow_up_context(raw_client_context, account_id:, conversation_display_id:)
          client_context = coerce_client_context(raw_client_context)
          return nil if client_context.nil?

          token = client_context[TOKEN_KEY]
          return nil if token.blank? || !token.is_a?(String)

          canonical = canonicalize(client_context)
          payload = verifier.verified(token, purpose: purpose(account_id, conversation_display_id))
          payload ||= verifier.verified(token, purpose: purpose(account_id, nil))
          return nil if payload.blank?

          return nil unless ActiveSupport::SecurityUtils.secure_compare(payload['digest'].to_s, context_digest(canonical))

          canonical
        end

        # Raw request input normalization (controllers pass params[:follow_up_context]
        # directly). Accepts ONLY genuine ActionController::Parameters (converted via
        # to_unsafe_h) or Hash; every other object — including impostors exposing
        # to_unsafe_h — fails closed as nil (implicit case fall-through) so a
        # malformed follow_up_context renders a concise 422 instead of crashing.
        # Explicit === type branches; no duck typing.
        def coerce_client_context(raw_client_context)
          return nil if raw_client_context.blank?

          case raw_client_context
          when ActionController::Parameters
            raw_client_context.to_unsafe_h
          when Hash
            raw_client_context
          end
        end

        # Deterministic canonicalization across a JSON round-trip: hash keys are
        # recursively stringified and sorted, array order is preserved, and the
        # result is canonical JSON-encoded before SHA-256. The client-supplied
        # TOKEN_KEY never participates in the digest.
        def canonicalize(follow_up_context)
          context = follow_up_context.to_h
          context = context.except(TOKEN_KEY) if context.respond_to?(:except)

          canonicalize_value(context)
        end

        def context_digest(canonical)
          OpenSSL::Digest::SHA256.hexdigest(JSON.generate(canonical))
        end

        # Account + conversation + version folded into the signing purpose, exactly
        # like Marine's playground_state_token: a token only verifies under the
        # same scope it was minted with, so replay across accounts or conversations
        # fails closed. Context-free tokens use the 'free' scope suffix.
        def purpose(account_id, conversation_display_id)
          "v1/account-#{account_id}/conversation-#{conversation_display_id.presence || 'free'}"
        end

        # Signs ONLY small provenance metadata plus the canonical context digest —
        # never the raw context — keeping the issued token compact.
        def issue_token(canonical, account_id:, conversation_display_id:)
          verifier.generate(
            {
              'v' => 2,
              'account_id' => account_id,
              'conversation_display_id' => conversation_display_id,
              'context_free' => conversation_display_id.blank?,
              'digest' => context_digest(canonical)
            },
            purpose: purpose(account_id, conversation_display_id)
          )
        end

        def canonicalize_value(value)
          case value
          when Hash
            value.transform_keys(&:to_s).sort.to_h.transform_values { |nested| canonicalize_value(nested) }
          when Array
            value.map { |nested| canonicalize_value(nested) }
          else
            value
          end
        end

        def verifier
          Rails.application.message_verifier(VERIFIER_NAME)
        end
      end
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
