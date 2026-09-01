# Shared, surface-agnostic dynamic response boundary for a pure binary STOCK reply.
#
# The deterministic stock business RESULT is decided upstream and identically by both surfaces:
# Marine::Catalog::ProductQueryOrchestrator turns the deterministic StockRepository status into a
# frozen { kind: :stock_available | :stock_empty, variant_code: ... } descriptor, and
# Marine::Catalog::ReplyPresenter renders its exact deterministic English. What used to live ONLY
# in the trigger-bound Marine::Conversation::ResponseBuilderJob — the fact-protected natural
# rephrase AND the strict fail-closed customer-language decision — is centralized here so the real
# conversation and the source-less Marine::Catalog::PlaygroundPreview reach the SAME business
# conclusion for the same account/assistant/context/catalog state: DELIVER an in-language stock
# line, or HAND OFF. Neither surface may claim availability while the other hands off.
#
# It never selects or invents the stock outcome (that is the deterministic descriptor's, unchanged)
# and asserts no new fact: the LLM only PHRASES the already-approved binary outcome, gated by the
# existing deterministic ProductFactProtectionValidator, the shared language detector, and the
# separate semantic FactPreservationValidator inside GroundedProductWordingService. It is pure over
# its inputs — it reads no Conversation, DB, or flow state and writes nothing; each caller supplies
# the already-localized deterministic fallback (via the shared ReplyLocalizer) and a lazy producer
# for the localized factless handoff acknowledgement, and consumes the returned Decision through its
# own delivery adapter (a real message/handoff for the conversation, a preview payload for the
# Playground).
module Marine
  module Catalog
    class StockReplyComposer
      # The two pure binary-availability reply kinds — the ONLY kinds whose sole fact is a variant
      # code, so the safe fail-closed floor can drop to a factless handoff without losing a
      # price/quantity/other fact. A non-stock descriptor is not this service's concern and is
      # delivered as-is (its own naturalization/localization is the caller's).
      STOCK_KINDS = %i[stock_available stock_empty].freeze

      # The single business outcome for a stock turn, consumed identically by both surfaces.
      #   * deliver? -> ship `text` (an accepted natural candidate, or the in-language / source /
      #     unknown-target deterministic localized fallback).
      #   * handoff? -> follow the safe handoff outcome. `message` is the localized factless
      #     acknowledgement ONLY when it is provably in the customer's language (else nil); `silent`
      #     is true when no acknowledgement can be proven in-language (the conversation transfers
      #     with no visible message). `ack` is the localized acknowledgement that was produced (in or
      #     out of language) so a preview surface can still show a handoff acknowledgement.
      Decision = Struct.new(:text, :handoff, :message, :ack, :silent, keyword_init: true) do
        def handoff? = handoff == true
        def deliver? = !handoff?
      end

      def initialize(account:)
        @account = account
      end

      # Resolve a stock reply to a DELIVER or HANDOFF Decision.
      #   descriptor      - the frozen stock descriptor (kind + validated variant_code)
      #   fallback        - the deterministic stock text ALREADY localized by the caller's adapter
      #   reply_language  - the authoritative per-turn provider language code (plan[:language])
      #   customer_request / message_history / opening - Phase 2 bounded context for the natural
      #                     rephrase and its reused opening/follow-up greeting policy
      #   localized_ack   - a no-arg callable returning the localized factless handoff
      #                     acknowledgement; invoked ONLY on the handoff branch (never on deliver)
      def compose(descriptor:, fallback:, reply_language:, customer_request:, localized_ack:, message_history: [], opening: true) # rubocop:disable Metrics/ParameterLists -- a flat set of surface-supplied inputs
        return deliver(fallback) unless STOCK_KINDS.include?(descriptor[:kind])
        # A codeless/malformed stock descriptor is not naturalization-eligible and carries no coded
        # fact to guarantee in-language: deliver the generic localized fallback, exactly as before.
        return deliver(fallback) unless fact_protection.eligible?(action: :reply, descriptor: descriptor)

        candidate = wording_candidate(descriptor, fallback, customer_request, message_history, opening, reply_language)
        return deliver(candidate) if candidate

        language_safe_decision(fallback, reply_language, localized_ack)
      end

      # The safe outcome when localization itself was UNAVAILABLE before an in-language fallback
      # could be produced: deliver the deterministic English only for an unknown/source target (no
      # in-language guarantee is claimed there); under a known non-source target refuse the
      # wrong-language stock line and hand off SILENTLY (no acknowledgement can be localized).
      def degraded(text:, reply_language:)
        target = target_language(reply_language)
        return deliver(text) if target.nil? || reliably_in_language?(text, target)

        Decision.new(text: nil, handoff: true, message: nil, ack: nil, silent: true)
      end

      private

      # The fail-closed customer-language decision for a stock reply whose natural candidate was NOT
      # accepted. For a known non-source target the VISIBLE stock line must be PROVABLY in that
      # language: the localized fallback is delivered ONLY when the shared detector RELIABLY reads it
      # with the customer's primary subtag. Any other shape (the exact English source, an English
      # paraphrase, another language, mixed, unreadable, or only unreliably detected) FAILS CLOSED to
      # the handoff — which carries the localized acknowledgement only when THAT too is provably
      # in-language, otherwise silent. An unknown/source target keeps the localized fallback.
      def language_safe_decision(fallback, reply_language, localized_ack)
        target = target_language(reply_language)
        return deliver(fallback) if target.nil?
        return deliver(fallback) if reliably_in_language?(fallback, target)

        ack = localized_ack.call
        in_language = reliably_in_language?(ack, target)
        Decision.new(text: nil, handoff: true, ack: ack,
                     message: (in_language ? ack : nil), silent: !in_language)
      end

      # An accepted, greeting-enforced natural rephrase grounded ONLY on the localized fallback plus
      # the bounded canonical context, or nil on any ineligibility/generation/validation failure. The
      # candidate is guaranteed by GroundedProductWordingService's own gate to be in reply_language.
      def wording_candidate(descriptor, fallback, customer_request, message_history, opening, reply_language) # rubocop:disable Metrics/ParameterLists -- mirrors the wording service call
        Marine::Catalog::GroundedProductWordingService.new(account: @account).call(
          action: :reply, descriptor: descriptor, fallback: fallback,
          customer_request: customer_request, message_history: message_history,
          opening: opening, reply_language: reply_language
        )
      rescue StandardError
        nil
      end

      # The bounded non-source primary target subtag for this reply, or nil when the per-turn provider
      # language is absent/unknown/malformed or is the English source (English delivery acceptable).
      # Mirrors ReplyLocalizer's own format allowlist and source language.
      def target_language(reply_language)
        code = reply_language.to_s.strip.downcase
        return nil if code.empty? || code == Marine::Catalog::ReplyLocalizer::UNKNOWN
        return nil unless code.match?(Marine::Catalog::ReplyLocalizer::LANGUAGE_PATTERN)

        primary = code.split('-').first
        primary == Marine::Catalog::ReplyLocalizer::SOURCE_LANGUAGE ? nil : primary
      end

      # True ONLY when `text` is RELIABLY detected in `target` (compared on the primary subtag). A
      # reliably-different, mixed, unreadable, or only-unreliably-read result returns false, so any
      # stock assertion or acknowledgement that cannot be proven in-language fails closed. Reuses the
      # shared Marine::Llm::LanguageDetector — no phrase list.
      def reliably_in_language?(text, target)
        result = Marine::Llm::LanguageDetector.new(text.to_s).detect
        result[:reliable] && result[:language].to_s.strip.downcase.split('-').first == target
      end

      def deliver(text) = Decision.new(text: text, handoff: false, message: nil, ack: nil, silent: false)

      def fact_protection = @fact_protection ||= Marine::Catalog::ProductFactProtectionValidator.new
    end
  end
end
