# Translates a deterministic English product reply into the customer's own language
# just before delivery, so every customer-facing Product Catalog text (attachment
# caption, family/variant clarification, duplicate-catalog and no-catalog fallback,
# and the other deterministic product replies) follows the latest customer turn.
#
# It is generic and data-driven: language comes from the shared LanguageDetector and
# the actual rewrite from the shared TranslateResponseService — no per-language
# branches, phrase maps, or hardcoded translations live here. The trigger incoming
# message is the primary language signal; a bounded slice of prior customer turns is
# consulted ONLY when the trigger alone is too short/unknown to classify.
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

      def initialize(text:, trigger_text:, context: [], account: nil)
        @text = text.to_s
        @trigger_text = trigger_text.to_s
        @context = Array(context)
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

      # Primary signal: the trigger message. Only when it classifies as unknown (e.g. a
      # very short "iya" reply) do we fall back to bounded recent customer context.
      def target_language
        language = classify(@trigger_text)
        language = classify(context_text) if language == UNKNOWN
        language
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
