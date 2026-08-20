# Phase 6 — deterministic protected-fact/value checker for naturalized product wording.
#
# The deterministic localized product reply is the authoritative delivery fallback; a
# generated natural-wording candidate is UNTRUSTED. This checker is the FIRST, generic,
# fail-closed gate an untrusted candidate must pass before the separate semantic
# FactPreservationValidator is ever consulted. It contains NO product names, family/variant
# codes, prices, stock values, language wordlists, customer phrases, filenames, IDs,
# warehouses, or conversation special cases — only a structural action+kind allowlist and
# generic token classes.
#
# It proves, by construction and deterministically, that a candidate may replace the
# fallback's WORDING without altering any protected fact:
#   * eligibility is an explicit action + descriptor-kind allowlist (CONTRACTS): a kind can
#     never become eligible under the wrong product action, and the descriptor must carry
#     EXACTLY the keys the deterministic template reads (no extra/missing keys, right shape);
#   * every protected DISPLAY value (family display name-or-code, variant code, the clarify
#     candidates/attribute names AS RENDERED, and for price the exact rate/currency/UOM) must
#     appear unchanged in BOTH the deterministic fallback and the candidate — if the baseline
#     itself lacks one (e.g. translation reshaped it) the candidate is rejected so wording is
#     skipped and the exact fallback is delivered;
#   * the candidate and fallback must carry IDENTICAL inventories (multisets) of generic
#     numeric tokens, Unicode currency symbols, alphanumeric identifier-like tokens, and
#     uppercase code/currency-like tokens, so any added/removed/altered numeric, currency, or
#     code information is rejected — this also protects the stock/price OUTCOME (no quantity or
#     price can be injected) while the binary meaning itself is left to semantic validation;
#   * malformed input fails closed: a non-String/blank/invalid-encoding/control-bearing text,
#     an unsupported/duplicate/blank protected value, a nonfinite price, or the wrong descriptor
#     shape all return false (deliver the fallback) rather than raising or repairing.
module Marine
  module Catalog
    class ProductFactProtectionValidator
      # NUL and other unsafe C0/DEL control characters, excluding tab (\t), newline (\n),
      # and carriage return (\r) which are legitimate in prose.
      UNSAFE_CONTROL_CHARS = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/

      # Explicit action + descriptor-kind allowlist. A kind is eligible ONLY under its single
      # supported action; :keys is the EXACT set of descriptor keys (besides the always-present
      # :kind) the deterministic template reads for that kind. Excluded kinds — handoff,
      # unsupported, catalog, catalog_unavailable, price_conflict, stock_unavailable,
      # price_unavailable — are ABSENT by design and can never be naturalized.
      CONTRACTS = {
        parent_info: { action: :reply, keys: %i[family_code family_name] },
        variant_info: { action: :reply, keys: %i[family_code variant_code] },
        stock_available: { action: :reply, keys: [] },
        stock_empty: { action: :reply, keys: [] },
        price_available: { action: :reply, keys: %i[price_list_rate currency uom] },
        clarify_family: { action: :clarify_family, keys: %i[candidates] },
        clarify_variant: { action: :clarify_variant, keys: %i[attribute_names] }
      }.freeze

      # A distinct in-band sentinel (never a value): "this descriptor is malformed/ambiguous,
      # reject". Kept private so it can never be confused with a legitimate empty value list.
      REJECT = Object.new.freeze
      private_constant :REJECT

      # Generic token classes for the inventory equality check. Each is compared as a sorted
      # multiset between fallback and candidate; a mismatch rejects the candidate.
      NUMERIC = /\d+(?:[.,]\d+)*/
      CURRENCY_SYMBOL = /\p{Sc}/
      ALNUM_RUN = /[[:alnum:]]+/
      UPPERCASE_CODE = /[A-Z]{2,}/

      # eligible? — action+kind allowlist plus descriptor shape ONLY (no fallback/candidate).
      # Lets the wording service skip generation/translation entirely for an unsupported or
      # malformed descriptor, so an ineligible reply never invokes an LLM.
      def eligible?(action:, descriptor:)
        return false unless contract_for(action, descriptor)

        protected_values(descriptor) != REJECT
      rescue StandardError
        false
      end

      # accepts? — the full deterministic gate. Returns true ONLY when the descriptor is
      # eligible/well-shaped, every protected display value is present unchanged in BOTH texts,
      # and the four token inventories are identical. False on any failure or uncertainty.
      def accepts?(action:, descriptor:, fallback:, candidate:)
        return false unless valid_texts?(fallback, candidate)
        return false unless contract_for(action, descriptor)
        return false unless protected_values_present?(descriptor, fallback, candidate)

        token_inventories_match?(fallback, candidate)
      rescue StandardError
        false
      end

      private

      def valid_texts?(fallback, candidate)
        valid_text?(fallback) && valid_text?(candidate)
      end

      # Every protected display value derived from the descriptor must appear unchanged in BOTH
      # the deterministic fallback and the candidate; a malformed/ambiguous descriptor rejects.
      def protected_values_present?(descriptor, fallback, candidate)
        values = protected_values(descriptor)
        return false if values == REJECT

        values.all? { |value| present_as_literal?(fallback, value) && present_as_literal?(candidate, value) }
      end

      # Unicode-aware literal presence with alphanumeric boundaries: the escaped value must occur
      # with no alphanumeric character immediately adjacent on either side, so a short code/value
      # is not treated as preserved merely because it appears inside a larger alphanumeric token
      # (e.g. "IMP" inside "IMPORTANT"). Multi-word/punctuation-bearing values are still matched
      # exactly and generically as an escaped literal. POSIX [[:alnum:]] is Unicode-aware here.
      def present_as_literal?(text, value)
        text.match?(/(?<![[:alnum:]])#{Regexp.escape(value)}(?![[:alnum:]])/)
      end

      # The contract for a descriptor, or nil when the kind is unsupported, the action does not
      # match the kind's single allowed action, or the descriptor carries the wrong key set.
      def contract_for(action, descriptor)
        return nil unless descriptor.is_a?(Hash)

        contract = CONTRACTS[descriptor[:kind]]
        return nil unless contract
        return nil unless action == contract[:action]
        return nil unless exact_keys?(descriptor, contract[:keys])

        contract
      end

      def exact_keys?(descriptor, keys)
        descriptor.keys.sort == ([:kind] + keys).sort
      end

      # Protected display values derived ONLY from allowlisted descriptor fields, matching what
      # the deterministic template renders. Returns an Array of strings (possibly empty), or the
      # REJECT sentinel when a required value is missing/blank/ambiguous/nonfinite.
      def protected_values(descriptor)
        case descriptor[:kind]
        when :parent_info then single(family_display(descriptor))
        when :variant_info then single(presence_string(descriptor[:variant_code]))
        when :price_available then price_values(descriptor)
        when :clarify_family then clarify_family_values(descriptor[:candidates])
        when :clarify_variant then value_list(descriptor[:attribute_names])
        when :stock_available, :stock_empty then []
        else REJECT
        end
      end

      # Family display is name-or-code exactly as the parent-info template renders it.
      def family_display(descriptor)
        presence_string(descriptor[:family_name]) || presence_string(descriptor[:family_code])
      end

      def single(value)
        value ? [value] : REJECT
      end

      # Exact rate/currency/UOM. The rate is rendered by the template through #to_s (a join), so
      # the protected value mirrors that; a nonfinite or non-numeric rate, or a blank currency,
      # rejects. UOM is protected only when present (the template appends it only when present).
      def price_values(descriptor)
        currency = presence_string(descriptor[:currency])
        rate = descriptor[:price_list_rate]
        return REJECT unless currency && finite_number?(rate)

        values = [currency, rate.to_s]
        uom = presence_string(descriptor[:uom])
        values << uom if uom
        values
      end

      # Clarify-family candidates render name-or-code per candidate; a non-Array, a malformed
      # candidate, or a blank/duplicate rendered value is ambiguous and rejects. Empty is allowed
      # (the deterministic template renders a generic prompt with no interpolated value).
      def clarify_family_values(candidates)
        return REJECT unless candidates.is_a?(Array)

        value_list(candidates.map { |candidate| candidate_display(candidate) })
      end

      # A candidate must be the EXACT shape ReplyRenderer emits: a Hash carrying exactly the
      # symbol keys :code and :name, a nonblank String code, and a name that is nil or a nonblank
      # String. The rendered protected value is name-or-code, mirroring the deterministic template.
      # Any other shape (string-keyed, missing/extra keys, blank code, malformed name) yields nil,
      # which value_list turns into a REJECT.
      def candidate_display(candidate)
        return nil unless candidate.is_a?(Hash)
        return nil unless exact_candidate_keys?(candidate)

        code = presence_string(candidate[:code])
        return nil unless code && optional_name?(candidate[:name])

        presence_string(candidate[:name]) || code
      end

      # Exactly the two symbol keys ReplyRenderer emits — :code and :name — and nothing else.
      def exact_candidate_keys?(candidate)
        candidate.keys.length == 2 && candidate.key?(:code) && candidate.key?(:name)
      end

      # The candidate name is optional: it must be either absent (nil) or a nonblank String.
      # A blank String or any non-String value is malformed.
      def optional_name?(name)
        name.nil? || !presence_string(name).nil?
      end

      # A rendered list of protected values: an empty list is allowed (the template renders a
      # generic prompt with no interpolated value); any blank/non-string element or a duplicate
      # (ambiguous) value rejects.
      def value_list(values)
        return REJECT unless values.is_a?(Array)

        strings = values.map { |value| presence_string_or_reject(value) }
        return REJECT if strings.include?(REJECT)
        return REJECT if strings.uniq.length != strings.length

        strings
      end

      def presence_string_or_reject(value)
        presence_string(value) || REJECT
      end

      def presence_string(value)
        return nil unless value.is_a?(String)

        stripped = value.strip
        stripped.empty? ? nil : stripped
      end

      def finite_number?(value)
        return value.match?(/\A-?\d+(?:[.,]\d+)*\z/) if value.is_a?(String)
        return false unless value.is_a?(Numeric)

        value.respond_to?(:finite?) ? value.finite? : true
      end

      # A candidate/fallback text is usable only when it is a nonblank, valid-encoding String
      # free of NUL/unsafe control characters.
      def valid_text?(text)
        return false unless text.is_a?(String) && text.valid_encoding?
        return false if text.strip.empty?

        !text.match?(UNSAFE_CONTROL_CHARS)
      end

      # Identical inventories (order-independent, count-sensitive) of every generic token class
      # in both texts, so added/removed/altered numeric/currency/code information is rejected.
      def token_inventories_match?(fallback, candidate)
        numeric_tokens(fallback) == numeric_tokens(candidate) &&
          currency_tokens(fallback) == currency_tokens(candidate) &&
          identifier_tokens(fallback) == identifier_tokens(candidate) &&
          uppercase_tokens(fallback) == uppercase_tokens(candidate)
      end

      def numeric_tokens(text)
        text.scan(NUMERIC).sort
      end

      def currency_tokens(text)
        text.scan(CURRENCY_SYMBOL).sort
      end

      # Alphanumeric runs carrying BOTH a letter and a digit — identifier/code-like tokens such
      # as a variant code, which must never change.
      def identifier_tokens(text)
        text.scan(ALNUM_RUN).select { |token| token.match?(/[[:alpha:]]/) && token.match?(/\d/) }.sort
      end

      def uppercase_tokens(text)
        text.scan(UPPERCASE_CODE).sort
      end
    end
  end
end
