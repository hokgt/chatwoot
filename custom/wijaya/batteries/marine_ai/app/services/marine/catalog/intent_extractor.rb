# Phase 2 — Contextual Product Intent Understanding. Turns a customer's message,
# a bounded slice of conversation context, and a SAFE state summary into a strict,
# normalized, allowlisted intent hash for the catalog flow to reason over.
#
# Trust boundary: the LLM output is treated as fully untrusted. Every field is
# type-normalized, bounded, and allowlisted before it leaves this service. Family,
# child, and attribute strings are CANDIDATES only — they are never validated,
# selected, or looked up here. This service deliberately does NOT touch the Phase 1
# repositories, does not query any database, generates no SQL, mutates no state, and
# creates no messages/attachments. Any LLM problem (unconfigured, unavailable,
# timeout/error, malformed JSON, hostile/unknown shapes) collapses to a safe
# `unknown` result rather than raising into the caller.
#
# Output contract (exactly these keys, always):
#   product_related, intent, family_mention, explicit_child_code,
#   attribute_candidates, requires_exact_variant, clarification_reply,
#   family_changed, intent_changed, multiple_numeric_candidates, confidence,
#   customer_language, reason
#
# customer_language is a bounded, allowlisted BCP-47-like code for the language of
# the CUSTOMER'S turn, read from the SAME extraction response (no extra provider
# call). It is untrusted delivery metadata only: a later phase may prefer it when
# localizing the outgoing reply, but it NEVER influences family/child/catalog
# selection. A missing or malformed value normalizes to nil so the caller falls back
# to local detection.
module Marine
  module Catalog
    class IntentExtractor # rubocop:disable Metrics/ClassLength
      # Product intents we actively support downstream. Anything else that is still a
      # product query normalizes to `unsupported`; a failed/unavailable/malformed
      # extraction normalizes to `unknown`.
      SUPPORTED_PRODUCT_INTENTS = %w[price stock parent_info variant_info catalog].freeze
      INTENTS = (SUPPORTED_PRODUCT_INTENTS + %w[unsupported unknown]).freeze
      CONFIDENCE_LEVELS = %w[low medium high].freeze

      # Internal, allowlisted reason codes — never raw exceptions or LLM prose.
      REASONS = %w[extracted not_product llm_unconfigured llm_unavailable llm_error malformed_response].freeze

      # Conservative bounds so hostile/oversized input or output can never blow up
      # the prompt or the stored result.
      MAX_INPUT_TEXT = 4000
      MAX_CONTEXT_MESSAGES = 10
      MAX_CONTEXT_MESSAGE_CHARS = 500
      MAX_CODE_LENGTH = 120
      MAX_CLARIFICATION_LENGTH = 400
      MAX_ATTRIBUTES = 16
      MAX_ATTRIBUTE_LENGTH = 80

      # Bounded, allowlisted shape for the untrusted customer-language code: a 2–3 letter
      # primary subtag with an optional single subtag (e.g. "id", "en", "zh-hans", "pt-br").
      # Anything else normalizes to nil. This is a FORMAT allowlist, not a language list —
      # no specific languages or phrases are enumerated.
      LANGUAGE_PATTERN = /\A[a-z]{2,3}(?:-[a-z0-9]{2,8})?\z/

      def initialize(account: nil, base_service: nil)
        @account = account
        @base_service = base_service
      end

      # text:    the customer's latest message (String).
      # context: bounded conversation context — an Array of message-ish entries
      #          (Strings, or Hashes with role/content). Anything else is ignored.
      # state:   a SAFE state summary. Only these keys are read; all others are
      #          dropped: :awaiting_code, :current_family, :current_intent.
      def extract(text:, context: nil, state: nil)
        return unknown_result('llm_unconfigured') unless base_service.configured?

        result = base_service.complete(prompt: user_prompt(text, context, state), system: SYSTEM_PROMPT)
        return unknown_result('llm_unavailable') unless result[:ok]

        parsed = parser.parse(result[:message])
        return unknown_result('malformed_response') unless parsed.is_a?(Hash)

        normalize(parsed, text, state)
      rescue StandardError => e
        capture(e)
        unknown_result('llm_error')
      end

      private

      attr_reader :account

      def base_service
        @base_service ||= Marine::Llm::BaseService.new(account: account)
      end

      def parser
        # default: nil so a non-JSON / prose-only response is reported as malformed
        # rather than silently coerced into an empty product classification.
        @parser ||= Marine::Llm::JsonResponseParser.new(default: nil)
      end

      # Fold an untrusted parsed hash into the strict contract. No field here is
      # trusted enough to become a validated selection — only normalized candidates.
      def normalize(parsed, text, state)
        product_related = truthy(parsed['product_related'])
        intent = normalize_intent(parsed['intent'])
        multiple_numeric = multiple_numeric?(text, parsed)

        build_result(parsed, state, product_related, intent, multiple_numeric)
      end

      def build_result(parsed, state, product_related, intent, multiple_numeric)
        family_mention = bounded_string(parsed['family_mention'], MAX_CODE_LENGTH)
        {
          product_related: product_related,
          intent: intent,
          family_mention: family_mention,
          explicit_child_code: resolve_child_code(parsed, state, multiple_numeric),
          attribute_candidates: bounded_array(parsed['attribute_candidates']),
          requires_exact_variant: truthy(parsed['requires_exact_variant']),
          clarification_reply: bounded_string(parsed['clarification_reply'], MAX_CLARIFICATION_LENGTH),
          family_changed: family_changed?(family_mention, state),
          intent_changed: intent_changed?(intent, state),
          multiple_numeric_candidates: multiple_numeric,
          confidence: normalize_confidence(parsed['confidence']),
          customer_language: normalize_language(parsed['customer_language']),
          reason: product_related ? 'extracted' : 'not_product'
        }
      end

      # Untrusted customer-language code, folded to a bounded, allowlisted format or nil.
      def normalize_language(value)
        return nil unless value.is_a?(String)

        code = value.strip.downcase
        code if code.match?(LANGUAGE_PATTERN)
      end

      # A number is never automatically a code. Only a candidate containing at least one
      # letter is treated as a genuine alphanumeric code candidate (still never validated).
      # Everything else is numeric-like — integers, signed numbers, decimals, and common
      # thousands formatting all count — and survives only when the LLM flags it as
      # contextually provided AND the safe state says the system is explicitly awaiting a
      # code AND there is no numeric ambiguity.
      def resolve_child_code(parsed, state, multiple_numeric)
        code = bounded_string(parsed['explicit_child_code'], MAX_CODE_LENGTH)
        return nil if code.nil?
        return code if code.match?(/[[:alpha:]]/)
        return nil if multiple_numeric

        contextual = truthy(parsed['explicit_child_code_from_context'])
        awaiting = truthy(state_value(state, :awaiting_code))
        contextual && awaiting ? code : nil
      end

      # Ambiguity marker: two or more distinct numbers in the customer text, or an
      # explicit marker from the LLM. Either way no number is promoted to a code.
      def multiple_numeric?(text, parsed)
        bounded_input(text).scan(/\d+(?:[.,]\d+)?/).uniq.length >= 2 || truthy(parsed['multiple_numeric_candidates'])
      end

      def normalize_intent(value)
        intent = value.to_s.strip.downcase
        return intent if SUPPORTED_PRODUCT_INTENTS.include?(intent)
        return 'unknown' if intent == 'unknown'

        # Any other recognized-but-unsupported product intent, or an unknown string.
        intent.empty? ? 'unknown' : 'unsupported'
      end

      def normalize_confidence(value)
        case value
        when Numeric
          return 'high' if value >= 0.75
          return 'medium' if value >= 0.4

          'low'
        else
          level = value.to_s.strip.downcase
          CONFIDENCE_LEVELS.include?(level) ? level : 'low'
        end
      end

      def family_changed?(family_mention, state)
        current_family = bounded_string(state_value(state, :current_family), MAX_CODE_LENGTH)
        family_mention.present? && current_family.present? && family_mention != current_family
      end

      def intent_changed?(intent, state)
        current_intent = normalize_intent(state_value(state, :current_intent))
        current_intent != 'unknown' && intent != current_intent
      end

      # Coerce a scalar candidate into a bounded, control-char-free String, or nil.
      # Arrays/Hashes and other non-scalars collapse to nil (type confusion is dropped).
      def bounded_string(value, limit)
        return nil unless value.is_a?(String) || value.is_a?(Numeric)

        cleaned = value.to_s.gsub(/[[:cntrl:]]/, ' ').strip
        cleaned.empty? ? nil : cleaned[0, limit]
      end

      def bounded_array(value)
        return [] unless value.is_a?(Array)

        value.filter_map { |item| bounded_string(item, MAX_ATTRIBUTE_LENGTH) }
             .uniq
             .first(MAX_ATTRIBUTES)
      end

      # Normalize assorted truthy encodings LLMs emit; everything else is false.
      def truthy(value)
        case value
        when true then true
        when String then %w[true yes 1].include?(value.strip.downcase)
        when Numeric then value == 1
        else false
        end
      end

      # Read only the allowlisted state keys, tolerating symbol or string keys.
      def state_value(state, key)
        return nil unless state.is_a?(Hash)

        state[key].nil? ? state[key.to_s] : state[key]
      end

      def bounded_input(text)
        text.to_s[0, MAX_INPUT_TEXT].to_s
      end

      # Compact, safe context block. No credentials, DB metadata, raw stock, or prices
      # are ever placed in the prompt — only the customer's own words and coarse,
      # non-sensitive state hints.
      def user_prompt(text, context, state)
        <<~PROMPT.strip
          Conversation state:
          #{state_hints(state)}

          Recent context:
          #{context_block(context)}

          Customer message:
          #{bounded_input(text)}
        PROMPT
      end

      def state_hints(state)
        awaiting = truthy(state_value(state, :awaiting_code))
        family = bounded_string(state_value(state, :current_family), MAX_CODE_LENGTH) || 'none'
        intent = normalize_intent(state_value(state, :current_intent))
        "awaiting_code: #{awaiting}\ncurrent_family_in_focus: #{family}\ncurrent_intent: #{intent}"
      end

      def context_block(context)
        entries = Array(context).first(MAX_CONTEXT_MESSAGES).filter_map { |entry| context_line(entry) }
        entries.empty? ? '(none)' : entries.join("\n")
      end

      def context_line(entry)
        content = entry.is_a?(Hash) ? "#{entry[:role] || entry['role']}: #{entry[:content] || entry['content']}" : entry
        bounded_string(content.to_s.gsub(/[[:cntrl:]]/, ' '), MAX_CONTEXT_MESSAGE_CHARS)
      end

      def unknown_result(reason)
        {
          product_related: false,
          intent: 'unknown',
          family_mention: nil,
          explicit_child_code: nil,
          attribute_candidates: [],
          requires_exact_variant: false,
          clarification_reply: nil,
          family_changed: false,
          intent_changed: false,
          multiple_numeric_candidates: false,
          confidence: 'low',
          customer_language: nil,
          reason: REASONS.include?(reason) ? reason : 'llm_error'
        }
      end

      def capture(exception)
        return if account.blank?

        ChatwootExceptionTracker.new(exception, account: account).capture_exception
      end

      SYSTEM_PROMPT = <<~PROMPT.strip
        You classify a customer's product intent for a marine parts catalog assistant. You only UNDERSTAND intent;
        you never look anything up, price, or confirm it. Respond with a single JSON object and nothing else, with these keys:
        product_related (boolean); intent (one of "price", "stock", "parent_info", "variant_info", "catalog", "unsupported");
        family_mention (string|null, a candidate name only); explicit_child_code (string|null, a candidate code only);
        explicit_child_code_from_context (boolean, true only when the customer is clearly giving a code the assistant just asked for);
        attribute_candidates (array of short strings); requires_exact_variant (boolean); clarification_reply (string|null, ask when ambiguous);
        multiple_numeric_candidates (boolean); confidence ("low"/"medium"/"high");
        customer_language (string|null, the language of the CUSTOMER's message as a short BCP-47 code such as "en", "id", "zh-hans"; null if unsure).
        Numbers are NOT automatically codes —
        a bare number may be a quantity, price, or size; never invent codes, families, or attributes.
        Use "catalog" ONLY when the customer explicitly asks to see or receive the product catalog document itself for a
        product family, rather than a specific price, stock level, or single-variant detail.
      PROMPT
    end
  end
end
