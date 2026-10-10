# price-display-v1 — shared deterministic caption boundary for a family price RANGE that grounds a
# catalog-assisted variant clarification. Consumed IDENTICALLY by the trigger-bound conversation
# (Marine::Conversation::ResponseBuilderJob) and the source-less Marine::Catalog::PlaygroundPreview,
# so both surfaces render the same locale-safe, outcome-truthful range caption.
#
# It reuses the EXACT display policy of the single-variant price path: BOTH range endpoints are
# formatted through Marine::Catalog::PriceDisplayFormatter for the SAME reply-language selection exact
# pricing uses (provider language -> configured language -> detected trigger -> detected context), so a
# range renders as `Rp 12.500` / `IDR 12,500`, never a raw `IDR 12500`. The canonical min/max decimals
# stay repository-derived; this boundary only FORMATS them — no LLM ever calculates or formats an
# amount. The formatted display facts (currency, min, max, UOM) are kept byte-exact through the
# FactPlaceholderMask while the deterministic caption is localized.
#
# It is OUTCOME-TRUTHFUL: `catalog_attached` decides whether the caption may point the customer at the
# code "shown in the catalog" (only when a native catalog attachment is actually delivered this turn)
# or must simply ask for the exact code without claiming a catalog was shown.
#
# Fail-closed: an unresolved/unsupported reply language, a malformed range, or a formatter rejection
# returns a :fallback decision so the caller renders the existing safe catalog-free variant
# clarification instead of a raw or wrong-language range. Equal endpoints render a single amount.
module Marine
  module Catalog
    class PriceRangeReplyComposer
      # The reply languages whose display policy PriceDisplayFormatter supports; a resolved language
      # outside this set fails closed (mirrors the exact-price boundary's supported set).
      SUPPORTED_LANGUAGES = %w[id en].freeze

      # Bounded, allowlisted language FORMAT (a format allowlist, not a language list). Mirrors the
      # exact-price / localizer pattern.
      LANGUAGE_PATTERN = /\A[a-z]{2,3}(?:-[a-z0-9]{2,8})?\z/

      # :deliver carries the finished caption text; :fallback tells the caller to render the existing
      # safe catalog-free variant clarification (never a raw or wrong-language range).
      Decision = Struct.new(:outcome, :text, keyword_init: true) do
        def deliver? = outcome == :deliver
        def fallback? = outcome == :fallback
      end

      def initialize(account:)
        @account = account
      end

      # Resolve a family price RANGE to an immutable Decision.
      #   descriptor          - the frozen :price_range descriptor (raw canonical facts from ReplyRenderer)
      #   reply_language      - the authoritative per-turn provider language (plan[:language])
      #   customer_request    - the latest canonical customer turn (language resolution + localization)
      #   catalog_attached    - whether a native catalog attachment is actually delivered this turn
      #   configured_language - the assistant's configured operating language (fallback resolution)
      #   message_history     - bounded prior canonical turns (language resolution + localization context)
      def compose(descriptor:, reply_language:, customer_request:, catalog_attached:, configured_language: nil, message_history: []) # rubocop:disable Metrics/ParameterLists -- a flat set of surface-supplied inputs, mirroring the exact-price boundary
        return fallback unless range_descriptor?(descriptor)

        target = resolve_target(reply_language, configured_language, customer_request, message_history)
        return fallback if target.nil?

        display = display_facts(descriptor, target)
        return fallback if display.nil?

        display_descriptor = display_descriptor(descriptor, display)
        english = presenter.price_range_text(display_descriptor, catalog_attached: catalog_attached)
        Decision.new(outcome: :deliver, text: localize(english, target, display_descriptor, customer_request, message_history)).freeze
      rescue StandardError => e
        capture(e)
        fallback
      end

      # The display facts (formatted currency, min, max, UOM) for `locale`, or nil fail-closed when a
      # required fact is missing or the formatter rejects an endpoint. Public so the range display
      # policy is unit-testable per locale. Both endpoints must format to the SAME currency and UOM.
      def display_facts(descriptor, locale)
        min = formatted_endpoint(descriptor, descriptor[:price_min], locale)
        max = formatted_endpoint(descriptor, descriptor[:price_max], locale)
        return nil if min.nil? || max.nil?
        return nil unless min[:currency] == max[:currency] && min[:uom] == max[:uom]

        { currency: min[:currency], uom: min[:uom], min: min[:amount], max: max[:amount] }
      end

      private

      def range_descriptor?(descriptor)
        descriptor.is_a?(Hash) && descriptor[:kind] == :price_range
      end

      # One endpoint formatted through the shared PriceDisplayFormatter by presenting the raw amount as
      # a synthetic single-variant price_available descriptor (the family code stands in for the
      # required variant code; it is never shown). nil on any formatter rejection.
      def formatted_endpoint(descriptor, raw_amount, locale)
        synthetic = { kind: :price_available, variant_code: descriptor[:family_code].to_s,
                      currency: descriptor[:currency], price_list_rate: raw_amount, uom: descriptor[:uom] }
        result = formatter.format(descriptor: synthetic, locale: locale)
        return nil unless result.ok?

        display = result.envelope[:display]
        { currency: display[:currency], amount: display[:amount], uom: display[:uom] }
      end

      # The display :price_range descriptor carrying the FORMATTED facts (so the caption renders display
      # values and the mask protects them), plus the translatable family labels from the raw descriptor.
      def display_descriptor(descriptor, display)
        { kind: :price_range, family_code: descriptor[:family_code], family_name: descriptor[:family_name],
          price_min: display[:min], price_max: display[:max], currency: display[:currency], uom: display[:uom] }.freeze
      end

      # Localize the deterministic caption to the resolved target, keeping the formatted display facts
      # byte-exact via the descriptor-masking ReplyLocalizer. The target is passed as provider_language
      # so the localizer delivers exactly the language the endpoints were formatted for (English is
      # returned unchanged). Any translation failure degrades to the English caption internally.
      def localize(english, target, display_descriptor, customer_request, message_history)
        Marine::Catalog::ReplyLocalizer.new(
          text: english, trigger_text: customer_request.to_s,
          context: context_contents(message_history), provider_language: target,
          fallback_language: nil, account: @account, action: :send_catalog, descriptor: display_descriptor
        ).call
      end

      # --- Target-language resolution (mirrors the exact-price precedence, restricted to id/en) -----

      # The supported target subtag (id/en), or nil when no valid signal resolves or the first valid
      # signal is unsupported — both fail closed (the caller renders the safe clarification).
      def resolve_target(reply_language, configured_language, customer_request, message_history)
        signal = normalize_language(reply_language) ||
                 normalize_language(configured_language) ||
                 detected_signal(customer_request) ||
                 detected_signal(context_text(message_history))
        return nil if signal.nil?

        primary = signal.split('-').first
        SUPPORTED_LANGUAGES.include?(primary) ? primary : nil
      end

      def normalize_language(value)
        return nil unless value.is_a?(String)

        code = value.strip.downcase
        return nil if code.empty? || code == Marine::Llm::LanguageDetector::UNKNOWN[:language]

        code if code.match?(LANGUAGE_PATTERN)
      end

      def detected_signal(text)
        return nil if text.to_s.strip.empty?

        result = Marine::Llm::LanguageDetector.new(text.to_s).detect
        return nil unless result[:reliable]

        normalize_language(result[:language].to_s)
      end

      def context_text(message_history)
        context_contents(message_history).join("\n")
      end

      def context_contents(message_history)
        Array(message_history).reverse.filter_map { |turn| (turn[:content] || turn['content']).presence }
      end

      def formatter = @formatter ||= Marine::Catalog::PriceDisplayFormatter.new
      def presenter = @presenter ||= Marine::Catalog::ReplyPresenter.new

      def fallback = Decision.new(outcome: :fallback, text: nil).freeze

      def capture(error)
        return if @account.nil?

        ChatwootExceptionTracker.new(error, account: @account).capture_exception
      end
    end
  end
end
