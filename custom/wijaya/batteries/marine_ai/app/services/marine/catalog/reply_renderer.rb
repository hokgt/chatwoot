# Phase 4 — Deterministic reply content for the product-decision orchestrator.
#
# This renderer is a PURE, side-effect-free domain helper: it never touches a
# database, a provider, I18n, a Message, or an Attachment. It turns already-decided,
# repository-derived facts into a strict, frozen "reply descriptor" — a small hash
# carrying an allowlisted :kind and ONLY allowlisted scalar fields. It deliberately
# does NOT produce customer-facing natural language: the exact localized text is a
# later runtime phase's job. Keeping Phase 4 output as structured descriptors (rather
# than free-form strings) guarantees no arbitrary LLM prose ever reaches a final
# price/stock reply, and keeps the object graph free of raw facts.
#
# Hard guarantees enforced here:
#   * stock descriptors carry only a binary :available / :empty / :unavailable kind —
#     never a numeric quantity, warehouse detail, SQL, or raw error;
#   * price descriptors carry only the three approved customer fields
#     (price_list_rate, currency, uom) plus the validated variant_code the price is
#     FOR (so a natural reply can name the product it prices) — nothing else from the row;
#   * every returned descriptor (and its nested arrays/hashes) is deeply frozen.
module Marine
  module Catalog
    class ReplyRenderer
      # Every descriptor :kind this renderer may emit. The orchestrator/spec assert
      # against this allowlist so an unexpected shape can never slip through.
      KINDS = %i[
        parent_info variant_info
        price_available price_unavailable price_conflict
        stock_available stock_empty stock_unavailable
        clarify_family clarify_variant
        catalog catalog_unavailable unsupported
      ].freeze

      # Defensive display ceilings — the upstream repositories already bound their
      # results, so these only guard against a misconfigured caller.
      MAX_CANDIDATES = 10
      MAX_ATTRIBUTE_NAMES = 16

      # Per-scalar length ceilings at this trust boundary. Row-derived codes/names and
      # attribute names are bounded and control-char-cleaned before they enter a frozen
      # descriptor; a blank/non-scalar value is dropped rather than emitted.
      MAX_CODE_NAME_LENGTH = 120
      MAX_ATTRIBUTE_NAME_LENGTH = 80

      # Parent-level answer for a validated family template ({ code:, name: }).
      def parent_info(family)
        descriptor(:parent_info, family_code: family[:code], family_name: family[:name])
      end

      # Direct Product Catalog request for a validated family ({ code:, name: }). Marks the
      # send_catalog plan as a DIRECT catalog request (distinct from a catalog-assisted variant
      # clarification, whose reply is nil), so the runtime renders a catalog caption / no-catalog
      # fallback instead of asking for a variant.
      def catalog(family)
        descriptor(:catalog, family_code: family[:code], family_name: family[:name])
      end

      # Supported info for a validated, row-derived child within a validated family.
      def variant_info(family, variant_code)
        descriptor(:variant_info, family_code: family[:code], variant_code: variant_code)
      end

      # Exactly the three approved price fields from PriceRepository#price_for, plus the
      # validated variant code the price is FOR so a natural reply can name the product it
      # prices; nothing else from the tuple is copied through.
      def price_available(price, variant_code)
        descriptor(:price_available,
                   variant_code: safe_scalar(variant_code, MAX_CODE_NAME_LENGTH),
                   price_list_rate: price[:price_list_rate],
                   currency: price[:currency],
                   uom: price[:uom])
      end

      def price_unavailable = descriptor(:price_unavailable)
      def price_conflict = descriptor(:price_conflict)

      # Stock is a binary availability status ONLY — never a quantity.
      def stock_available = descriptor(:stock_available)
      def stock_empty = descriptor(:stock_empty)
      def stock_unavailable = descriptor(:stock_unavailable)

      def catalog_unavailable = descriptor(:catalog_unavailable)
      def unsupported = descriptor(:unsupported)

      # Safe family clarification carrying bounded repository candidates ({ code:, name: }).
      # A candidate with a blank/malformed (non-scalar) code is dropped entirely.
      def clarify_family(candidates)
        safe = Array(candidates).filter_map do |candidate|
          next unless candidate.is_a?(Hash)

          code = safe_scalar(candidate[:code], MAX_CODE_NAME_LENGTH)
          next if code.nil?

          { code: code, name: safe_scalar(candidate[:name], MAX_CODE_NAME_LENGTH) }
        end.first(MAX_CANDIDATES)
        descriptor(:clarify_family, candidates: safe)
      end

      # Safe variant clarification carrying the family's bounded attribute names.
      def clarify_variant(attribute_names)
        safe = Array(attribute_names).filter_map { |name| safe_scalar(name, MAX_ATTRIBUTE_NAME_LENGTH) }
                                     .first(MAX_ATTRIBUTE_NAMES)
        descriptor(:clarify_variant, attribute_names: safe)
      end

      private

      # Bound and control-char-clean a single scalar at the trust boundary. Non-scalar
      # (Array/Hash/nil) or blank-after-cleaning values return nil so the caller can drop them.
      def safe_scalar(value, limit)
        return nil if value.nil? || value.is_a?(Hash) || value.is_a?(Array)

        cleaned = value.to_s.gsub(/[[:cntrl:]]/, ' ').strip
        cleaned.empty? ? nil : cleaned[0, limit]
      end

      def descriptor(kind, fields = {})
        deep_freeze({ kind: kind }.merge(fields))
      end

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
