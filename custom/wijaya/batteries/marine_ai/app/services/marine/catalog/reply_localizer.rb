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
# It never raises and never blocks delivery. An English (source-language) or unknown
# target, an unconfigured or failing translator, or blank text all return the original
# English text unchanged. Only the reply text is rewritten — product/family names it
# carries come from repository/document data and are preserved by the translation
# prompt; no catalog/document selection or attachment behavior is affected.
module Marine
  module Catalog
    class ReplyLocalizer
      SOURCE_LANGUAGE = 'en'.freeze
      UNKNOWN = 'unknown'.freeze

      # Bounded, allowlisted customer-language format (a FORMAT allowlist, not a language
      # list): a 2–3 letter primary subtag with an optional single subtag.
      LANGUAGE_PATTERN = /\A[a-z]{2,3}(?:-[a-z0-9]{2,8})?\z/

      def initialize(text:, trigger_text:, context: [], provider_language: nil, account: nil)
        @text = text.to_s
        @trigger_text = trigger_text.to_s
        @context = Array(context)
        @provider_language = normalize_language(provider_language)
        @account = account
      end

      def call
        return @text if @text.strip.blank?

        target = target_language
        return @text if target == UNKNOWN || target == SOURCE_LANGUAGE

        translate(target)
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
    end
  end
end
