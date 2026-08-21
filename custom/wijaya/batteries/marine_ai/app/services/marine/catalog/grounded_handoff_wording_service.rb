# Phase 7 — fact-safe natural wording for a product HANDOFF acknowledgement.
#
# When Marine cannot answer a product request itself — an unsupported topic (warehouse
# location, delivery to a customer-supplied destination, shipping cost) or an exact-quantity
# question whose number the catalog does not expose — it hands the conversation to a human.
# The public handoff line must acknowledge the CURRENT request and relevant context naturally,
# in the customer's own language, WITHOUT asserting any answer or inventing a fact.
#
# This mirrors Marine::Catalog::GroundedProductWordingService but for a FACTLESS
# acknowledgement: the deterministic, already-localized acknowledgement fallback is the sole
# authority and carries no product/business fact of its own, so a rephrase may reference the
# customer's request but must never introduce one. The generated candidate is delivered ONLY
# when it passes, in order:
#   1. an output-shape gate (valid-encoding, nonblank, non-JSON prose),
#   2. the reused Phase 4 greeting enforcement,
#   3. a deterministic no-new-fact-token guard — the candidate may carry no numeric, currency,
#      identifier-like, or uppercase-code token the factless fallback does not already contain,
#      so no price, quantity, coverage figure, location code, or amount can be injected, and
#   4. the SEPARATE semantic Marine::Charge::FactPreservationValidator, proving the candidate is
#      fact-equivalent to the acknowledgement (it may acknowledge the request but assert nothing
#      new).
# Any generation/validation failure or uncertainty returns nil (a non-delivery signal) and the
# caller delivers its exact deterministic fallback. It passes ONLY the acknowledgement fallback
# plus the latest canonical request and bounded prior canonical history to the LLM — never the
# plan/state, repository rows, raw stock/price internals, IDs, or unrelated data — and
# logs/persists nothing. No greeting phrases/languages/wordlists and no company branding live here.
module Marine
  module Catalog
    class GroundedHandoffWordingService
      # NUL and other unsafe C0/DEL control characters, excluding tab/newline/carriage return
      # which are legitimate in prose.
      UNSAFE_CONTROL_CHARS = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/

      # Generic fact-bearing token classes (same shape as the product fact-protection gate). A
      # candidate token in any of these classes that is not already in the factless fallback is a
      # potential invented fact (price, quantity, coverage figure, amount, or code) and rejects.
      NUMERIC = /\d+(?:[.,]\d+)*/
      CURRENCY_SYMBOL = /\p{Sc}/
      IDENTIFIER = /[[:alnum:]]+/
      UPPERCASE_CODE = /[A-Z]{2,}/

      # Provider-enforced generation envelope (RubyLLM #with_schema format): a bare object carrying
      # EXACTLY one string field, "reply", so the natural wording arrives as clean structured output
      # instead of a fenced/prose/markdown blob. Request-side control ONLY — it never relaxes
      # acceptance; the extracted reply is still untrusted and still passes every gate below.
      REPLY_SCHEMA = {
        name: 'handoff_reply',
        strict: true,
        schema: {
          type: 'object',
          additionalProperties: false,
          required: %w[reply],
          properties: { 'reply' => { type: 'string' } }
        }
      }.freeze

      GENERATION_INSTRUCTION = <<~PROMPT.strip
        You are handing this conversation to a human colleague because you cannot answer the customer's latest request yourself.
        Rephrase the Acknowledgement below to reply to the customer naturally in the same language and context.
        Briefly acknowledge what they asked for and that a colleague will follow up; you may refer to their request and the context, but state no new information.
        You do NOT know and must NOT state or imply any price, amount, quantity, availability, delivery coverage, shipping cost, location, or other fact. Promise no outcome.
        Do not add, change, or invent any fact, number, or code. Answer concisely.
        Output only your reply text, with no JSON, markdown, quotes, or explanation.
      PROMPT

      def initialize(account: nil)
        @account = account
      end

      # Returns the accepted, greeting-enforced candidate string, or nil on ANY generation failure
      # or validation rejection/uncertainty. `opening` is the Phase 2 opening/follow-up state and
      # drives the reused Phase 4 greeting policy.
      def call(fallback:, customer_request:, message_history: [], opening: true)
        return nil unless valid_text?(fallback)

        candidate = sanitized_candidate(generate(fallback, customer_request, message_history, opening))
        return nil if candidate.nil?

        enforced = greeting_context.enforce(candidate, opening: opening).presence
        return nil if enforced.blank?
        return nil unless no_new_fact_tokens?(fallback, enforced)
        return nil unless validator.valid?(approved_answer: fallback, candidate: enforced)

        enforced
      rescue StandardError
        nil
      end

      private

      def generate(fallback, customer_request, message_history, opening)
        service = Marine::Llm::BaseService.new(account: @account)
        return nil unless service.configured?

        result = service.chat(
          messages: messages_with_query(message_history, customer_request),
          system: generation_prompt(fallback, opening),
          temperature: 0.0,
          schema: REPLY_SCHEMA
        )
        return nil unless result[:ok] && result[:message].present?

        reply_from_envelope(result[:message])
      end

      # Parse the provider's { "reply": <string> } envelope as an EXACT object — no fence
      # stripping, extraction, or repair. Returns the reply body ONLY for a bare Hash whose sole
      # key is "reply" with a String value; anything else fails closed to nil.
      def reply_from_envelope(raw)
        return nil unless raw.is_a?(String) && raw.valid_encoding?

        parsed = JSON.parse(raw, allow_duplicate_key: false)
        return nil unless parsed.is_a?(Hash) && parsed.keys == %w[reply]
        return nil unless parsed['reply'].is_a?(String)

        parsed['reply']
      rescue JSON::ParserError
        nil
      end

      def generation_prompt(fallback, opening)
        [GENERATION_INSTRUCTION, greeting_context.interaction_prompt(opening: opening), "Acknowledgement:\n#{fallback}"].join("\n\n")
      end

      # Smallest generic output-shape gate: a valid-encoding String with nonblank substantive
      # content, free of NUL/unsafe control characters, and not a machine-readable payload.
      def sanitized_candidate(raw)
        return nil unless raw.is_a?(String) && raw.valid_encoding?

        candidate = raw.strip
        return nil if candidate.blank?
        return nil if raw.match?(UNSAFE_CONTROL_CHARS)
        return nil if candidate.start_with?('```')
        return nil if whole_json_structure?(candidate)

        candidate
      end

      def whole_json_structure?(stripped)
        return false unless ['{', '['].include?(stripped[0])

        parsed = JSON.parse(stripped)
        parsed.is_a?(Hash) || parsed.is_a?(Array)
      rescue JSON::ParserError
        false
      end

      # Every fact-bearing token class in the candidate must be a subset (multiset containment) of
      # the factless fallback's — so nothing numeric, currency, code, or uppercase-code the
      # acknowledgement does not already carry can be introduced.
      def no_new_fact_tokens?(fallback, candidate)
        multiset_subset?(numeric_tokens(fallback), numeric_tokens(candidate)) &&
          multiset_subset?(currency_tokens(fallback), currency_tokens(candidate)) &&
          multiset_subset?(identifier_tokens(fallback), identifier_tokens(candidate)) &&
          multiset_subset?(uppercase_tokens(fallback), uppercase_tokens(candidate))
      end

      # True when every token in `candidate_tokens` occurs in `fallback_tokens` at least as many
      # times (order-independent, count-sensitive multiset containment).
      def multiset_subset?(fallback_tokens, candidate_tokens)
        fallback_counts = fallback_tokens.tally
        candidate_tokens.tally.all? { |token, occurrences| occurrences <= fallback_counts.fetch(token, 0) }
      end

      def numeric_tokens(text) = text.scan(NUMERIC)
      def currency_tokens(text) = text.scan(CURRENCY_SYMBOL)
      def uppercase_tokens(text) = text.scan(UPPERCASE_CODE)

      # Identifier-like tokens carry BOTH a letter and a digit (a code such as CHILD-1's run);
      # plain words are ignored so ordinary prose is never rejected.
      def identifier_tokens(text)
        text.scan(IDENTIFIER).select { |token| token.match?(/[[:alpha:]]/) && token.match?(/\d/) }
      end

      def messages_with_query(message_history, customer_request)
        history = Array(message_history)
        last = history.last
        last_content = last && (last[:content] || last['content'])
        return history if last_content.to_s == customer_request.to_s

        history + [{ role: 'user', content: customer_request.to_s }]
      end

      def valid_text?(text)
        return false unless text.is_a?(String) && text.valid_encoding?
        return false if text.strip.empty?

        !text.match?(UNSAFE_CONTROL_CHARS)
      end

      def greeting_context = @greeting_context ||= Marine::Charge::GreetingContext.new(account: @account)

      def validator = @validator ||= Marine::Charge::FactPreservationValidator.new(account: @account)
    end
  end
end
