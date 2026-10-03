# price-display-v1 — pure, deterministic DISPLAY formatter for an eligibility-checked
# price_available product descriptor.
#
# It turns the raw, repository-derived price facts a ReplyRenderer :price_available descriptor
# carries (variant_code, price_list_rate, currency, uom) into a deeply immutable ENVELOPE that
# keeps the canonical raw values intact AND carries the approved customer-visible DISPLAY facts
# for one supported target locale, plus a raw-to-display provenance map. It never queries a
# database, calls an LLM, or builds a sentence — it is the fact source the PriceReplyComposer
# grounds its locale-safe deterministic fallback and its dynamic generation on.
#
# DISPLAY POLICY (price-display-v1):
#   * id -> currency "Rp", integer grouped with dot thousands (12500 -> 12.500), comma decimal;
#   * en -> currency "IDR", integer grouped with comma thousands (12500 -> 12,500), dot decimal;
#   * uom is lowercased (Yard -> yard); the variant code is a display fact verbatim.
#
# Exactness is a hard guarantee: the amount is processed as an EXACT decimal string (or an
# Integer / finite BigDecimal), NEVER a Float, and NEVER rounded. Only the integer part is
# regrouped; the fractional part is reattached byte-for-byte, so the decimal scale is preserved
# intentionally (12500.00 -> "12.500,00" for id). Large values group in threes with no ceiling.
#
# It fails CLOSED with a Result carrying ok? == false (never raises) on an unsupported locale, a
# malformed/missing/blank field, a negative or nonfinite or non-exactly-representable amount, an
# unsupported currency, or an unsupported unit of measure — so the composer hands off / falls back
# rather than inventing a price. Supported locales for this version are EXACTLY id and en.
module Marine
  module Catalog
    class PriceDisplayFormatter
      POLICY_VERSION = 'price-display-v1'.freeze

      SUPPORTED_LOCALES = %w[id en].freeze

      # The single supported canonical (raw) currency and its per-locale display symbol. Any other
      # raw currency is unsupported and fails closed — the display policy defines only this one.
      CURRENCY_DISPLAY = { 'IDR' => { 'id' => 'Rp', 'en' => 'IDR' } }.freeze

      # Per-locale integer-grouping and decimal separators (the consistent locale convention).
      SEPARATORS = {
        'id' => { group: '.', decimal: ',' },
        'en' => { group: ',', decimal: '.' }
      }.freeze

      # A non-negative decimal STRING with no sign, exponent, or embedded grouping — the exact,
      # losslessly representable form. Integer / finite BigDecimal are normalized to this shape.
      AMOUNT_STRING = /\A\d+(?:\.\d+)?\z/

      # A supported unit of measure: one or more Unicode letters and spaces, starting with a letter
      # (no digits or symbols, which would pollute the display and the fact-token inventory).
      UOM_PATTERN = /\A\p{L}[\p{L} ]*\z/

      # A fail-closed result. `ok?` gates the envelope; `reason` names the rejection (bounded).
      Result = Struct.new(:ok, :envelope, :reason, keyword_init: true) do
        def ok? = ok == true
      end

      # Produce the immutable display envelope for `descriptor` in `locale`, or a failed Result.
      def format(descriptor:, locale:) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- a flat sequence of independent fail-closed field validations
        loc = locale.to_s
        return failure(:unsupported_locale) unless SUPPORTED_LOCALES.include?(loc)
        return failure(:malformed_descriptor) unless price_descriptor?(descriptor)

        product = presence(descriptor[:variant_code])
        currency_raw = presence(descriptor[:currency])
        uom_raw = presence(descriptor[:uom])
        return failure(:missing_field) if product.nil? || currency_raw.nil? || uom_raw.nil?

        amount_raw = canonical_amount(descriptor[:price_list_rate])
        return failure(:invalid_amount) if amount_raw.nil?

        display_currency = CURRENCY_DISPLAY.dig(currency_raw.upcase, loc)
        return failure(:unsupported_currency) if display_currency.nil?

        display_uom = display_uom(uom_raw)
        return failure(:unsupported_uom) if display_uom.nil?

        display_amount = grouped_amount(amount_raw, loc)
        success(envelope(loc, descriptor, product, currency_raw, amount_raw, uom_raw,
                         display_currency, display_amount, display_uom))
      end

      private

      def price_descriptor?(descriptor)
        descriptor.is_a?(Hash) &&
          descriptor[:kind] == :price_available &&
          descriptor.keys.sort == %i[currency kind price_list_rate uom variant_code]
      end

      # The exact canonical decimal string for a rate, or nil when it cannot be represented exactly
      # and non-negatively without a Float. A String must be an exact non-negative decimal; an
      # Integer is stringified; a finite BigDecimal is rendered in plain (non-scientific) form; a
      # Float is refused outright (it cannot promise exactness). Leading integer zeros are trimmed.
      def canonical_amount(rate) # rubocop:disable Metrics/CyclomaticComplexity -- a flat per-type exact-representation guard
        string =
          case rate
          when Integer then rate.to_s
          when BigDecimal then rate.finite? && !rate.negative? ? rate.to_s('F') : nil
          when String then rate.strip
          end
        return nil if string.nil? || !string.match?(AMOUNT_STRING)

        normalize_zeros(string)
      end

      # Trim redundant leading zeros in the integer part while keeping at least one digit and the
      # fractional part byte-exact (no rounding). "012500" -> "12500", "0.50" -> "0.50".
      def normalize_zeros(string)
        integer, fraction = string.split('.', 2)
        integer = integer.sub(/\A0+(?=\d)/, '')
        fraction ? "#{integer}.#{fraction}" : integer
      end

      # Group the integer part in threes using the locale separator and reattach the fractional part
      # verbatim with the locale decimal separator — exact, never rounded.
      def grouped_amount(amount, locale)
        sep = SEPARATORS.fetch(locale)
        integer, fraction = amount.split('.', 2)
        grouped = integer.reverse.scan(/\d{1,3}/).join(sep[:group]).reverse
        fraction ? "#{grouped}#{sep[:decimal]}#{fraction}" : grouped
      end

      def display_uom(uom)
        return nil unless uom.match?(UOM_PATTERN)

        uom.downcase
      end

      # A deeply immutable envelope: the raw canonical facts, the approved display facts, and the
      # raw-to-display provenance for each fact. The variant code has no display transform.
      def envelope(locale, descriptor, product, currency_raw, amount_raw, uom_raw, display_currency, display_amount, display_uom) # rubocop:disable Metrics/ParameterLists -- a flat envelope assembly
        deep_freeze(
          policy_version: POLICY_VERSION,
          locale: locale,
          canonical: {
            variant_code: product, currency: currency_raw,
            price_list_rate: descriptor[:price_list_rate], uom: uom_raw
          },
          display: {
            product: product, currency: display_currency,
            amount: display_amount, uom: display_uom
          },
          provenance: {
            product: { raw: product, display: product },
            currency: { raw: currency_raw, display: display_currency },
            amount: { raw: amount_raw, display: display_amount },
            uom: { raw: uom_raw, display: display_uom }
          }
        )
      end

      def presence(value)
        return nil unless value.is_a?(String)

        stripped = value.strip
        stripped.empty? ? nil : stripped
      end

      def success(envelope) = Result.new(ok: true, envelope: envelope, reason: nil).freeze
      def failure(reason) = Result.new(ok: false, envelope: nil, reason: reason).freeze

      def deep_freeze(value)
        case value
        when Hash then value.each_value { |v| deep_freeze(v) }.freeze
        when Array then value.each { |v| deep_freeze(v) }.freeze
        else value.freeze
        end
      end
    end
  end
end
