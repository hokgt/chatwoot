# Opaque, signed, expiring TRANSPORT for the source-less Assistant Playground's ephemeral
# product-flow state. The Playground has no persisted Conversation, so deterministic multi-turn
# product state (validated family/variant, clarification kind+count, catalog-already-sent) cannot
# live in a ProductFlowStateStore. Instead the server round-trips a normalized, allowlisted flow
# snapshot through this token: the browser holds it in memory and echoes it on the next turn, and
# the server verifies it and produces the next snapshot. It is NOT customer state and is NEVER
# persisted to any DB, Redis, or session — it exists only in the request/response and browser
# memory.
#
# Trust boundary:
#   * The token is produced by ActiveSupport::MessageVerifier (Rails.application.message_verifier),
#     an established Rails primitive with constant-time HMAC verification keyed off secret_key_base.
#   * It is scoped by version + account_id + assistant_id via the signing PURPOSE, so a token minted
#     for one assistant/account fails verification under any other (an assistant switch invalidates
#     it automatically) and a tampered/forged token fails closed to nil.
#   * It carries an EXPIRY (TTL), so a stale token fails closed to nil (a fresh flow) — the preview
#     is ephemeral by construction.
#   * Payload and token sizes are capped, and neither the token nor the state is ever logged.
# The payload is ONLY the ProductFlowStateStore-normalized/allowlisted planning snapshot (bounded
# metadata about the flow — never a raw fact, price, quantity, or secret). The client cannot author
# raw flow: it can only echo a token the server previously signed, and any mutation invalidates it.
module Marine
  module Catalog
    class PlaygroundStateToken
      VERIFIER_NAME = 'marine.playground.product_flow'.freeze
      VERSION = 1
      TTL_SECONDS = 30 * 60 # ephemeral: 30 minutes
      MAX_TOKEN_BYTES = 4096

      def initialize(account:, assistant:)
        @account = account
        @assistant = assistant
      end

      # Sign a normalized snapshot into an opaque token scoped to this account+assistant, expiring
      # after TTL_SECONDS. A blank snapshot (no state to carry) or an oversized token yields nil so
      # the payload simply omits the token. Never raises.
      def encode(snapshot)
        return nil if snapshot.blank? || account_id.nil? || assistant_id.nil?

        token = verifier.generate(snapshot, purpose: scope, expires_in: TTL_SECONDS)
        token if token.bytesize <= MAX_TOKEN_BYTES
      rescue StandardError
        nil
      end

      # Verify + decode a client-supplied token back into its snapshot hash, or nil (fail closed) on
      # a blank/oversized/tampered/expired token or an account/assistant scope mismatch. The caller
      # re-normalizes the result through ProductFlowStateStore before use.
      def decode(token)
        return nil unless decodable?(token)

        value = verifier.verified(token, purpose: scope)
        value if value.is_a?(Hash)
      rescue StandardError
        nil
      end

      private

      attr_reader :account, :assistant

      # A well-formed, size-bounded token on a fully scoped signer — the precondition for verifying.
      def decodable?(token)
        token.is_a?(String) && token.present? && token.bytesize <= MAX_TOKEN_BYTES &&
          !account_id.nil? && !assistant_id.nil?
      end

      def account_id
        account.id if account.respond_to?(:id)
      end

      def assistant_id
        assistant.id if assistant.respond_to?(:id)
      end

      # Version + account + assistant scoping folded into the signing purpose: a token only verifies
      # under the exact same scope it was minted with, so a switch/forge/replay across
      # assistants/accounts fails closed.
      def scope
        "v#{VERSION}/account-#{account_id}/assistant-#{assistant_id}"
      end

      def verifier
        Rails.application.message_verifier(VERIFIER_NAME)
      end
    end
  end
end
