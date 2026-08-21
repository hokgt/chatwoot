# Translates a deterministic English product reply into the customer's own language
# just before delivery, so every customer-facing Product Catalog text (attachment
# caption, family/variant clarification, duplicate-catalog and no-catalog fallback,
# and the other deterministic product replies) follows the latest customer turn.
#
# It is generic and data-driven: the actual rewrite comes from the shared
# TranslateResponseService — no per-language branches, phrase maps, or hardcoded
# translations live here. The customer's language is preferred from `provider_language`
# (a bounded code the intent extractor already read from the SAME customer turn, so no
# extra provider call is made). Only when that is missing/malformed does it fall back to
# the shared LanguageDetector over the trigger message, then a bounded slice of prior
# customer turns when the trigger alone is too short/unknown to classify. Preferring the
# provider code avoids trusting CLD3 as the sole authority (CLD3 misclassifies some short
# regional texts), while the language never affects family/catalog/document selection.
#
# FACTUAL SAFETY: the English source is the SOLE factual authority; a translation is an
# UNTRUSTED rewrite. A translated reply is delivered ONLY when it survives, in order:
#   1. a deterministic generic token-inventory check — the translation must carry the SAME
#      multiset of numeric, currency-symbol, identifier-like (letter+digit), and uppercase-code
#      tokens as the English source, so a mistranslation cannot add/remove/change a price,
#      number, currency, unit figure, or product/family/code;
#   2. for a supported product descriptor, the deterministic ProductFactProtectionValidator
#      (action + descriptor), so protected display values stay literal; and
#   3. the SEPARATE semantic Marine::Charge::FactPreservationValidator, proving the translation
#      is fact-equivalent to the English source (no changed stock outcome, delivery
#      availability/cost, warehouse/location, or other unsupported assertion the token check
#      cannot see).
# Any failure/uncertainty at any gate fails CLOSED to the exact English source. English,
# unknown-target, unconfigured-translator, and unchanged-translation paths are unchanged: they
# return the original English WITHOUT invoking any validator or extra provider call. Only the
# reply text is rewritten; no catalog/document selection or attachment behavior is affected.
module Marine
  module Catalog
    class ReplyLocalizer
      SOURCE_LANGUAGE = 'en'.freeze
      UNKNOWN = 'unknown'.freeze

      # Bounded, allowlisted customer-language format (a FORMAT allowlist, not a language
      # list): a 2–3 letter primary subtag with an optional single subtag.
      LANGUAGE_PATTERN = /\A[a-z]{2,3}(?:-[a-z0-9]{2,8})?\z/

      # Generic fact-bearing token classes for the deterministic inventory check. Each is
      # compared as a sorted multiset between the English source and the translation; any
      # mismatch fails closed. Mirrors the product fact-protection gate's classes so a price,
      # number, currency symbol, unit figure, or letter+digit code cannot drift in translation.
      NUMERIC = /\d+(?:[.,]\d+)*/
      CURRENCY_SYMBOL = /\p{Sc}/
      ALNUM_RUN = /[[:alnum:]]+/
      UPPERCASE_CODE = /[A-Z]{2,}/

      # action/descriptor are OPTIONAL: when a supported product descriptor + its action are
      # supplied, the deterministic ProductFactProtectionValidator additionally keeps its
      # protected display values literal in the translation. They never influence selection.
      # rubocop:disable Metrics/ParameterLists -- these are an explicit keyword API at the
      # battery's delivery boundary: the text plus its independent language signals
      # (trigger_text/context/provider_language), the account, and the optional protected
      # action/descriptor are separate caller-supplied inputs. Bundling them into a value object
      # would only relocate the list and hide the by-name contract each call site relies on.
      def initialize(text:, trigger_text:, context: [], provider_language: nil, account: nil, action: nil, descriptor: nil)
        # rubocop:enable Metrics/ParameterLists
        @text = text.to_s
        @trigger_text = trigger_text.to_s
        @context = Array(context)
        @provider_language = normalize_language(provider_language)
        @account = account
        @action = action
        @descriptor = descriptor
      end

      def call
        return @text if @text.strip.blank?

        target = target_language
        return @text if target == UNKNOWN || target == SOURCE_LANGUAGE

        translated = translate(target)
        # A degraded/unchanged translation is the English source verbatim — nothing to validate,
        # so no validator or extra provider call runs.
        return @text if translated == @text

        fact_preserved?(translated) ? translated : @text
      end

      private

      # TranslateResponseService already degrades safely (skip on same/unknown/unconfigured,
      # original text on failure) and always returns a JSON-safe hash carrying a usable
      # :text, so a blank/missing result can only fall back to the original English.
      def translate(target)
        Marine::Llm::TranslateResponseService.new(
          text: @text, target_language: target, source_language: SOURCE_LANGUAGE, account: @account
        ).call[:text].presence || @text
      end

      # Fail-closed factual gate over an untrusted translation: deterministic token inventory,
      # then (for a supported descriptor) the deterministic protected-value validator, then the
      # separate semantic validator. Any error/uncertainty rejects (deliver English).
      def fact_preserved?(translated)
        return false unless token_inventory_match?(@text, translated)
        return false unless descriptor_values_preserved?(translated)

        fact_validator.valid?(approved_answer: @text, candidate: translated)
      rescue StandardError
        false
      end

      # For a supported product descriptor, the protected display values (family/variant code or
      # name, exact price fields) must stay literal in the translation. A non-descriptor text
      # (handoff acknowledgement, static template) or an ineligible descriptor skips this gate and
      # relies on the token-inventory + semantic checks.
      def descriptor_values_preserved?(translated)
        return true if @descriptor.nil?
        return true unless fact_protection.eligible?(action: @action, descriptor: @descriptor)

        fact_protection.accepts?(action: @action, descriptor: @descriptor, fallback: @text, candidate: translated)
      end

      # Identical (order-independent, count-sensitive) inventories of every generic token class,
      # so any added/removed/altered numeric, currency, unit, or code token rejects.
      def token_inventory_match?(source, translated)
        numeric_tokens(source) == numeric_tokens(translated) &&
          currency_tokens(source) == currency_tokens(translated) &&
          identifier_tokens(source) == identifier_tokens(translated) &&
          uppercase_tokens(source) == uppercase_tokens(translated)
      end

      def numeric_tokens(text) = text.scan(NUMERIC).sort
      def currency_tokens(text) = text.scan(CURRENCY_SYMBOL).sort
      def uppercase_tokens(text) = text.scan(UPPERCASE_CODE).sort

      # Alphanumeric runs carrying BOTH a letter and a digit — identifier/code-like tokens such
      # as a variant code, which must never change in translation.
      def identifier_tokens(text)
        text.scan(ALNUM_RUN).select { |token| token.match?(/[[:alpha:]]/) && token.match?(/\d/) }.sort
      end

      # Preferred signal: the provider language read from the same customer turn. Only when
      # it is absent/malformed do we classify the trigger message locally, then fall back to
      # bounded recent customer context when the trigger alone is unknown.
      def target_language
        return @provider_language if @provider_language

        language = classify(@trigger_text)
        language = classify(context_text) if language == UNKNOWN
        language
      end

      # Bounded, allowlisted customer-language code, or nil for a missing/malformed value.
      def normalize_language(value)
        return nil unless value.is_a?(String)

        code = value.strip.downcase
        return nil if code.blank? || code == UNKNOWN

        code if code.match?(LANGUAGE_PATTERN)
      end

      def classify(text)
        Marine::Llm::LanguageDetector.new(text).detect[:language].to_s.strip.downcase.presence || UNKNOWN
      end

      def context_text
        @context.join("\n")
      end

      def fact_protection = @fact_protection ||= Marine::Catalog::ProductFactProtectionValidator.new

      def fact_validator = @fact_validator ||= Marine::Charge::FactPreservationValidator.new(account: @account)
    end
  end
end
