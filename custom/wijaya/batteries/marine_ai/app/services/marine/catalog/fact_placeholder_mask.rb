# D7 — generic opaque placeholder masking of a product reply's IMMUTABLE fact values, so a
# deterministic English reply can be localized (translated) into the assistant's configured
# language WITHOUT trusting the LLM to leave codes/amounts/currency/UOM untouched, and WITHOUT
# treating a human-facing display label as immutable prose.
#
# The proven D7 defect: the cross-language delivery path required the canonical family DISPLAY
# NAME to survive a translation byte-for-byte, so any faithful translation that naturally rendered
# that name in the target language was rejected and the reply fell back to English — violating
# configured-language consistency. This mask separates the two concerns generically:
#   * IMMUTABLE fact fields (identifier / amount / unit / currency: family_code, variant_code,
#     currency, uom, price_list_rate, plus a clarify-candidate :code and each composite :part's
#     immutable values) are replaced with unique opaque placeholders BEFORE the LLM sees the text
#     and restored byte-for-byte AFTER, so they can never be translated, reworded, or drifted; while
#   * DISPLAY-LABEL fields (family_name, a candidate :name, attribute_names) are DELIBERATELY absent
#     from the immutable set — they are human-facing wording that MAY be translated, their meaning
#     guarded only by the caller's separate semantic validator, never by a literal match here.
# The decision is by descriptor FIELD ROLE (a generic scalar-field allowlist), not by phrase,
# content, or language. When name-or-code renders the CODE (a blank name), that code is an
# identifier and is masked/preserved; when it renders the NAME, nothing immutable is in the text and
# the whole label translates freely.
#
# #restore fails CLOSED (returns nil) on any placeholder inventory violation — a dropped, duplicated,
# unknown, or malformed placeholder, or any stray sentinel residue — so a translator that mangles the
# markers can never smuggle a changed or missing fact past the caller. The caller then delivers its
# exact deterministic fallback. The mask is pure and side-effect-free: no database, provider, I18n,
# or state, and it never raises.
module Marine
  module Catalog
    class FactPlaceholderMask
      # Private-use-area sentinels delimit every placeholder. A translator has no linguistic reason
      # to alter PUA characters, so it leaves them verbatim; anything that DOES alter them trips the
      # fail-closed inventory/residue checks in #restore.
      OPEN = "\u{E000}".freeze
      CLOSE = "\u{E001}".freeze

      # A well-formed placeholder: an uppercase-letter id (A, B, ... Z, AA, ...) between the
      # sentinels. The id carries NO digits, so a target-language digit reshaping can never corrupt
      # it. TOKEN matches whole placeholders; SENTINEL detects any stray, unmatched sentinel char.
      TOKEN = /\u{E000}[A-Z]+\u{E001}/
      SENTINEL = /[\u{E000}\u{E001}]/

      # Generic field-role allowlist: descriptor fields whose VALUE is an immutable fact. Display
      # labels (family_name, a candidate :name, attribute_names) are intentionally NOT listed — they
      # are translatable wording. :candidates and :parts are handled structurally (a candidate's
      # :code is immutable; a composite recurses into each part).
      IMMUTABLE_SCALAR_FIELDS = %i[family_code variant_code currency uom price_list_rate].freeze

      def initialize(descriptor: nil)
        @descriptor = descriptor
      end

      # Replace every immutable fact value that occurs (as a standalone, alphanumeric-boundary token)
      # in `text` with a unique opaque placeholder, returning the masked text. Returns nil when
      # `text` is not a String or already carries a sentinel char (it cannot be masked safely).
      # Records each placeholder's exact value and occurrence count for #restore. Values are masked
      # longest-first so a shorter value that is a token of a longer one (e.g. "IMP" within "IMP-3")
      # can never corrupt it. A value that does not occur in the text is skipped (no placeholder).
      def mask(text)
        @map = {}
        return nil unless text.is_a?(String)
        return nil if text.match?(SENTINEL)

        masked = text.dup
        immutable_values.each_with_index do |value, index|
          pattern = boundary_pattern(value)
          count = masked.scan(pattern).size
          next if count.zero?

          token = placeholder(index)
          masked = masked.gsub(pattern, token)
          @map[token] = { value: value, count: count }
        end
        masked
      end

      # Validate that `translated` carries EXACTLY the same placeholder multiset #mask produced (same
      # ids, same counts, no unknown ids, no stray sentinel residue), then restore each placeholder to
      # its exact original value. Returns the restored string, or nil on ANY violation so the caller
      # fails closed. #mask MUST have run first.
      def restore(translated)
        return nil unless @map && translated.is_a?(String)

        return nil unless inventory_matches?(translated.scan(TOKEN))
        return nil if translated.gsub(TOKEN, '').match?(SENTINEL)

        translated.gsub(TOKEN) { |token| @map.fetch(token)[:value] }
      rescue KeyError
        nil
      end

      private

      # The multiset of placeholders found must equal the multiset #mask recorded: a missing,
      # duplicated, or unknown (never-recorded) placeholder all make the tallies differ.
      def inventory_matches?(found)
        found.tally == @map.transform_values { |entry| entry[:count] }
      end

      # Distinct, non-blank immutable fact values from the descriptor, longest first.
      def immutable_values
        collect(@descriptor).filter_map { |value| stringify(value) }.uniq.sort_by { |value| -value.length }
      end

      # Walk the descriptor with the generic field-role allowlist: immutable scalar fields yield their
      # value, a candidate list yields each :code, a composite recurses into each part. Everything
      # else (display labels, kind, unknown keys) yields nothing.
      def collect(descriptor)
        return [] unless descriptor.is_a?(Hash)

        descriptor.flat_map { |key, value| values_for(key, value) }
      end

      def values_for(key, value)
        return [value] if IMMUTABLE_SCALAR_FIELDS.include?(key)
        return candidate_codes(value) if key == :candidates
        return part_values(value) if key == :parts

        []
      end

      # Each candidate's immutable :code (its :name is a translatable display label).
      def candidate_codes(value)
        return [] unless value.is_a?(Array)

        value.filter_map { |candidate| candidate[:code] if candidate.is_a?(Hash) }
      end

      # The union of each composite part's own immutable values.
      def part_values(value)
        return [] unless value.is_a?(Array)

        value.flat_map { |part| collect(part) }
      end

      def stringify(value)
        return nil if value.nil? || value.is_a?(Hash) || value.is_a?(Array)

        stripped = value.to_s.strip
        stripped.empty? ? nil : stripped
      end

      # Standalone-token match: no alphanumeric character immediately adjacent, so a short value is
      # never masked merely because it is a substring of a larger token. POSIX [[:alnum:]] is
      # Unicode-aware.
      def boundary_pattern(value)
        /(?<![[:alnum:]])#{Regexp.escape(value)}(?![[:alnum:]])/
      end

      # Uppercase-letter, base-26 placeholder id (0 -> A, 25 -> Z, 26 -> AA, ...), sentinel-delimited.
      def placeholder(index)
        id = +''
        remaining = index
        loop do
          id.prepend(('A'.ord + (remaining % 26)).chr)
          remaining = (remaining / 26) - 1
          break if remaining.negative?
        end
        OPEN + id + CLOSE
      end
    end
  end
end
