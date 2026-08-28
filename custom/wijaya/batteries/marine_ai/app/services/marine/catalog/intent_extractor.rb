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
#   family_changed, intent_changed, multiple_numeric_candidates, quantity_inquiry,
#   unsupported_request, confidence, customer_language, reason
#
# quantity_inquiry is a bounded, untrusted boolean flag: true ONLY when the customer asks for
# an EXACT on-hand quantity ("how many units do you have"), which the catalog does not expose.
# A plain availability (in-stock yes/no) question keeps intent "stock" with quantity_inquiry
# false. The orchestrator routes a quantity inquiry to a safe handoff instead of a misleading
# boolean stock answer; it never influences family/child/catalog selection.
#
# unsupported_request is a bounded, untrusted, allowlisted CATEGORY (or nil) describing WHAT the
# customer asked for when Marine cannot answer it itself — one of a fixed generic set
# (UNSUPPORTED_REQUEST_CATEGORIES: delivery feasibility, shipping cost, warehouse/location, exact
# quantity, or generic "other"). It is delivery-only metadata for a request-aware handoff
# acknowledgement: it NEVER influences family/child/catalog selection, and any non-allowlisted or
# missing value normalizes to nil so the handoff falls back to the generic factless line.
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

      # Fixed, generic allowlist for the untrusted unsupported-request CATEGORY. These are
      # request-type NAMES only — no product, destination, price, or customer value — used solely
      # to pick a request-aware (but still factless) handoff acknowledgement. Anything else, or a
      # missing value, normalizes to nil (the generic factless fallback). "other" is the explicit
      # generic bucket and is itself treated as fail-closed/generic downstream.
      UNSUPPORTED_REQUEST_CATEGORIES = %w[delivery_feasibility shipping_cost warehouse_location exact_quantity other].freeze

      # Fixed, allowlisted SHAPE of answer a stock question expects, classified by the provider from
      # the customer's own words: "exact_count" when the customer asks HOW MANY units / a specific
      # number on hand (a figure the catalog does not expose), "availability" for a plain in-stock
      # yes/no. This closed count-vs-availability vocabulary — never a language, phrase, or raw-text
      # list — lets the provider make ONE discrete decision instead of inferring the abstract
      # quantity_inquiry boolean alone; an exact_count shape normalizes quantity_inquiry to true.
      # Anything else, or a missing value, contributes no exact-count signal (the legacy boolean still
      # applies), so a plain availability ask stays binary.
      STOCK_ANSWER_SHAPES = %w[exact_count availability].freeze

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

      # A single turn may carry an ordered, bounded SET of supported intents (e.g. price AND stock).
      # requested_intents is that set — normalized, deduped, allowlisted to SUPPORTED_PRODUCT_INTENTS,
      # and rendered in a CANONICAL order (SUPPORTED_PRODUCT_INTENTS order) so it is deterministic and
      # independent of the LLM's ordering. The scalar `intent` stays the primary intent for backwards
      # compatibility; requested_intents is additive. When the model emits no explicit set, it falls
      # back to the single supported scalar intent (or empty for a non-product/unknown turn).
      MAX_REQUESTED_INTENTS = 4

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

        # Classification is deterministic: temperature 0 removes sampling jitter so a borderline
        # answer-shape (e.g. a mixed "how many … available" ask) resolves to the model's single most
        # likely category rather than flipping between runs. It is a control, not the fix — the
        # structured answer-shape contract is what makes that most-likely category correct.
        result = base_service.complete(prompt: user_prompt(text, context, state), system: SYSTEM_PROMPT, temperature: 0)
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

      def build_result(parsed, state, product_related, intent, multiple_numeric) # rubocop:disable Metrics/MethodLength
        family_mention = bounded_string(parsed['family_mention'], MAX_CODE_LENGTH)
        quantity_inquiry = quantity_inquiry?(parsed)
        {
          product_related: product_related,
          intent: intent,
          requested_intents: normalize_requested_intents(parsed['intents'], intent),
          family_mention: family_mention,
          explicit_child_code: resolve_child_code(parsed, state, multiple_numeric),
          attribute_candidates: bounded_array(parsed['attribute_candidates']),
          requires_exact_variant: truthy(parsed['requires_exact_variant']),
          clarification_reply: bounded_string(parsed['clarification_reply'], MAX_CLARIFICATION_LENGTH),
          family_changed: family_changed?(family_mention, state),
          intent_changed: intent_changed?(intent, state),
          multiple_numeric_candidates: multiple_numeric,
          quantity_inquiry: quantity_inquiry,
          unsupported_request: normalize_unsupported_request(parsed['unsupported_request'], quantity_inquiry),
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

      # The customer is asking for an exact on-hand quantity when EITHER the provider tags the stock
      # ANSWER SHAPE as an exact numeric count OR it emits the legacy quantity_inquiry boolean. The two
      # signals are OR-ed: the structured answer-shape lets a provider that recognizes a "how many" ask
      # route it even when it leaves the abstract boolean false, while a legacy true is never overridden
      # by an "availability" shape. Structured provider fields only — never the raw customer text.
      def quantity_inquiry?(parsed)
        truthy(parsed['quantity_inquiry']) || stock_answer_shape(parsed) == 'exact_count'
      end

      # Untrusted stock answer-shape, folded to the fixed allowlist or nil. A non-String, unknown, or
      # blank value contributes no exact-count signal.
      def stock_answer_shape(parsed)
        value = parsed['stock_answer_shape']
        return nil unless value.is_a?(String)

        shape = value.strip.downcase
        STOCK_ANSWER_SHAPES.include?(shape) ? shape : nil
      end

      # Untrusted unsupported-request category, folded to the fixed generic allowlist or nil. An exact
      # on-hand quantity ask IS, by definition, the exact_quantity category, so a turn normalized to a
      # quantity inquiry is tagged exact_quantity even when the provider populated no separate
      # unsupported_request — keeping the later handoff acknowledgement request-aware. Otherwise a
      # non-String, unknown, or blank value normalizes to nil so the handoff stays generic.
      def normalize_unsupported_request(value, quantity_inquiry)
        return 'exact_quantity' if quantity_inquiry
        return nil unless value.is_a?(String)

        category = value.strip.downcase
        UNSUPPORTED_REQUEST_CATEGORIES.include?(category) ? category : nil
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

      # Fold the untrusted per-turn intent SET into a bounded, deduped, allowlisted, canonically
      # ordered list. Only SUPPORTED_PRODUCT_INTENTS survive; a missing/empty set falls back to the
      # supported scalar intent (so single-intent turns keep a consistent one-element set) and to []
      # for a non-product/unknown/unsupported turn. Canonical order = SUPPORTED_PRODUCT_INTENTS order,
      # so price+stock and stock+price fold to the identical set independent of LLM ordering.
      def normalize_requested_intents(value, scalar_intent)
        raw = value.is_a?(Array) ? value.filter_map { |item| supported_requested_entry(item) } : []
        raw = [scalar_intent] if raw.empty? && SUPPORTED_PRODUCT_INTENTS.include?(scalar_intent)
        SUPPORTED_PRODUCT_INTENTS.select { |intent| raw.include?(intent) }.first(MAX_REQUESTED_INTENTS)
      end

      def supported_requested_entry(value)
        return nil unless value.is_a?(String)

        code = value.strip.downcase
        code if SUPPORTED_PRODUCT_INTENTS.include?(code)
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
          requested_intents: [],
          family_mention: nil,
          explicit_child_code: nil,
          attribute_candidates: [],
          requires_exact_variant: false,
          clarification_reply: nil,
          family_changed: false,
          intent_changed: false,
          multiple_numeric_candidates: false,
          quantity_inquiry: false,
          unsupported_request: nil,
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
        intents (array of the supported intents the SAME turn asks for, e.g. ["price","stock"] when the customer asks for both
        the price and whether it is in stock; use a single-element array for a single ask; omit or leave empty when unsure);
        family_mention (string|null, a candidate name only); explicit_child_code (string|null, a candidate code only);
        explicit_child_code_from_context (boolean, true only when the customer is clearly giving a code the assistant just asked for);
        attribute_candidates (array of short strings); requires_exact_variant (boolean); clarification_reply (string|null, ask when ambiguous);
        multiple_numeric_candidates (boolean); quantity_inquiry (boolean);
        stock_answer_shape (string|null, for a stock/availability question ONLY: "exact_count" when the customer asks HOW MANY
        units are on hand or otherwise wants a specific NUMBER of units, "availability" when they only ask whether it is in stock
        (a yes/no answer); null when the turn is not asking about stock at all);
        confidence ("low"/"medium"/"high");
        unsupported_request (string|null, ONLY when the customer asks for something this catalog assistant cannot answer — one of
        "delivery_feasibility" (can you deliver to a place), "shipping_cost" (how much is shipping/delivery), "warehouse_location"
        (where is the warehouse / where are you located), "exact_quantity" (exactly how many units are on hand), or "other" for any
        other unsupported ask; null when the request is a normal price/stock/variant/catalog question);
        customer_language (string|null, the language of the CUSTOMER's message as a short BCP-47 code such as "en", "id", "zh-hans"; null if unsure).
        Numbers are NOT automatically codes —
        a bare number may be a quantity, price, or size; never invent codes, families, or attributes.
        Use "catalog" ONLY when the customer asks to see or receive the product catalog document itself for a product family,
        rather than a specific price, stock level, or single-variant detail. This includes a short follow-up that simply asks to
        receive or see the catalog while a family is already in focus (use current_family_in_focus) — do not treat that as unsupported.
        When the customer only confirms or refers back to the family already in focus without naming a new one, leave
        family_mention null so the conversation continues with that family.
        For any stock question, decide stock_answer_shape from the ANSWER the customer expects: a request for a NUMBER of units
        on hand ("how many", "how much stock") is "exact_count"; a plain in-stock / available yes-or-no is "availability". Judge
        this from the meaning of the customer's own words in whatever language they use, not from surface keywords.
        Set quantity_inquiry true whenever stock_answer_shape is "exact_count" — an exact on-hand count is a number the assistant
        cannot look up; a plain "is it in stock / available?" question stays intent "stock" with quantity_inquiry false.
      PROMPT
    end
  end
end
