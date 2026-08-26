# Translates a deterministic English product reply into the customer's own language
# just before delivery, so every customer-facing Product Catalog text (attachment
# caption, family/variant clarification, duplicate-catalog and no-catalog fallback,
# and the other deterministic product replies) follows the latest customer turn.
#
# It is generic and data-driven: the actual rewrite comes from the shared
# TranslateResponseService — no per-language branches, phrase maps, or hardcoded
# translations live here. The customer's language is preferred from `provider_language`
# (a bounded code the intent extractor already read from the SAME customer turn, so no
# extra provider call is made). When that is missing/malformed, it prefers the assistant's
# configured operating language (`fallback_language`, the account's own KB/reply language)
# before falling back to the shared LanguageDetector over the trigger message, then a bounded
# slice of prior customer turns. This ordering matters: CLD3 confidently MISCLASSIFIES some
# short regional turns (e.g. a brief Indonesian message detected as Hindi-Latn/Polish/Malay),
# which would otherwise drive a wrong-language rewrite or a robotic English fall-back; anchoring
# to the known operating language when there is no authoritative per-turn signal keeps the reply
# in the assistant's own language instead of trusting a misclassification. CLD3 stays only as the
# last resort for an assistant with no configured language. The language never affects
# family/catalog/document selection.
#
# FACTUAL SAFETY: the English source is the SOLE factual authority; a translation is an
# UNTRUSTED rewrite. Before the untrusted step runs, the deterministic Marine::Catalog::
# FactPlaceholderMask replaces every IMMUTABLE fact value in the English source (family/variant
# code, currency, UOM, price amount, composite-part facts) with an opaque placeholder, so the
# translator only ever rephrases prose and the human-facing DISPLAY LABEL (family/candidate name,
# attribute names) — never an identifier or amount. A translated reply is delivered ONLY when it
# survives, in order:
#   1. strict placeholder inventory/restoration — the translation must carry the EXACT same
#      placeholder multiset (no dropped/duplicated/unknown/malformed marker), and each is restored
#      to its byte-exact original value, so a mistranslation can never change a code, price,
#      currency, or unit;
#   2. a deterministic generic token-inventory check over the restored text — it must carry the SAME
#      multiset of numeric, currency-symbol, identifier-like (letter+digit), and uppercase-code
#      tokens as the English source, so nothing new (an injected number/currency/code) survives in
#      the translated prose or label; and
#   3. the SEPARATE semantic Marine::Charge::FactPreservationValidator, proving the translation
#      is fact-equivalent to the English source (a translated display label is accepted here ONLY
#      when semantically equivalent; no changed stock outcome, delivery availability/cost,
#      warehouse/location, or other unsupported assertion the token check cannot see).
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

      # action/descriptor are OPTIONAL: when a supported product descriptor is supplied, the
      # FactPlaceholderMask masks its immutable fact values before translation and restores them
      # after, so those facts stay byte-exact while the display label may translate. `action` is
      # retained as part of the stable delivery-boundary keyword API (callers thread it uniformly);
      # the descriptor alone drives masking. They never influence selection.
      # rubocop:disable Metrics/ParameterLists -- these are an explicit keyword API at the
      # battery's delivery boundary: the text plus its independent language signals
      # (trigger_text/context/provider_language), the account, and the optional protected
      # action/descriptor are separate caller-supplied inputs. Bundling them into a value object
      # would only relocate the list and hide the by-name contract each call site relies on.
      def initialize(text:, trigger_text:, context: [], provider_language: nil, fallback_language: nil, account: nil, action: nil, descriptor: nil)
        # rubocop:enable Metrics/ParameterLists
        @text = text.to_s
        @trigger_text = trigger_text.to_s
        @context = Array(context)
        @provider_language = normalize_language(provider_language)
        @fallback_language = normalize_language(fallback_language)
        @account = account
        @action = action
        @descriptor = descriptor
      end

      def call
        return @text if @text.strip.blank?

        target = target_language
        return @text if target == UNKNOWN || target == SOURCE_LANGUAGE

        localize_to(target)
      end

      private

      # Mask immutable facts, translate the masked source, restore byte-exact, and validate — failing
      # closed to the exact English source at any step (unmaskable source, degraded/unchanged
      # translation, placeholder inventory violation, or a rejected factual gate).
      def localize_to(target)
        masked = mask.mask(@text)
        return @text if masked.nil?

        translated = translate(masked, target)
        # A degraded/unchanged translation is the masked source verbatim — nothing to validate.
        return @text if translated == masked

        restored = mask.restore(translated)
        # A dropped/duplicated/unknown/malformed placeholder rejects; an identical restoration is the
        # English source, so nothing to validate either way.
        return @text if restored.nil? || restored == @text

        fact_preserved?(restored) ? restored : @text
      end

      # TranslateResponseService already degrades safely (skip on same/unknown/unconfigured,
      # original text on failure) and always returns a JSON-safe hash carrying a usable :text, so a
      # blank/missing result can only fall back to the (masked) source it was given.
      def translate(source, target)
        Marine::Llm::TranslateResponseService.new(
          text: source, target_language: target, source_language: SOURCE_LANGUAGE, account: @account
        ).call[:text].presence || source
      end

      # Fail-closed factual gate over the restored translation: deterministic token inventory (the
      # immutable facts are already byte-exact from placeholder restoration, so this catches an
      # injected number/currency/code in the translated prose or label), then the separate semantic
      # validator. Any error/uncertainty rejects (deliver English).
      def fact_preserved?(restored)
        return false unless token_inventory_match?(@text, restored)

        fact_validator.valid?(approved_answer: @text, candidate: restored)
      rescue StandardError
        false
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

      # Preferred signal: the provider language read from the same customer turn. When it is
      # absent/malformed, prefer the assistant's configured operating language over local CLD3
      # classification — a short customer turn is exactly where CLD3 confidently misclassifies,
      # so the known operating language is the safer anchor than a per-turn guess. Only with no
      # configured language do we classify the trigger locally, then fall back to bounded recent
      # customer context when the trigger alone is unknown.
      def target_language
        return @provider_language if @provider_language
        return @fallback_language if @fallback_language

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

      def mask = @mask ||= Marine::Catalog::FactPlaceholderMask.new(descriptor: @descriptor)

      def fact_validator = @fact_validator ||= Marine::Charge::FactPreservationValidator.new(account: @account)
    end
  end
end
