# Phase 4 — Deterministic variant (child) resolution WITHIN an already-validated
# family. This is the only component that turns untrusted Phase 2 candidates
# (an explicit child-code candidate and/or scalar attribute-value candidates) into a
# single, repository-confirmed child code — or refuses to.
#
# Trust boundary and rules (mirrors the blueprint state machine):
#   * The family_code MUST already be a row-derived, validated family. This resolver
#     never validates the family and never invents or concatenates a child code.
#   * A child code is accepted ONLY when it comes back from a repository row
#     (VariantRepository#resolve_child) or from an exact attribute/value match
#     (VariantRepository#resolve_by_attribute) — never from the raw LLM candidate.
#   * Attribute candidates are SCALAR values, not name/value pairs. Every bounded
#     (attribute_name, candidate_value) combination is tested; the repository's own
#     attribute_names(family) supplies the names (never hardcoded).
#   * The result is unique ONLY when exactly one distinct row-derived child code is
#     produced across every path. Zero → missing; two or more → ambiguous. The first
#     row is NEVER chosen; on any ambiguity the resolver fails closed to :unresolved.
#
# A CatalogUnavailableError from the repository propagates to the orchestrator, which
# fails closed — this resolver never fabricates a code on a DB failure.
module Marine
  module Catalog
    class VariantResolver
      def initialize(variant_repository: nil)
        @variant_repository = variant_repository || VariantRepository.new
      end

      # Returns one of:
      #   { status: :resolved, code: <row-derived child code> }
      #   { status: :unresolved, reason: :missing }    — no candidate matched a row
      #   { status: :unresolved, reason: :ambiguous }  — 2+ distinct rows matched
      def resolve(family_code:, explicit_child_code: nil, attribute_candidates: [])
        family = family_code.to_s.strip
        return unresolved(:missing) if family.empty?

        codes = collect_codes(family, explicit_child_code, attribute_candidates)
        case codes.size
        when 1 then { status: :resolved, code: codes.first }
        when 0 then unresolved(:missing)
        else unresolved(:ambiguous)
        end
      end

      private

      attr_reader :variant_repository

      # Gather every distinct row-derived child code the candidates can confirm. The
      # explicit-code and attribute paths are unioned; the attribute path bails out
      # (per attribute name) as soon as a second distinct code appears, since the
      # outcome is already ambiguous and there is no need to keep probing.
      def collect_codes(family, explicit_child_code, attribute_candidates)
        codes = child_codes(family, explicit_child_code)
        codes |= attribute_codes(family, attribute_candidates)
        codes
      end

      def child_codes(family, explicit_child_code)
        child = explicit_child_code.to_s.strip
        return [] if child.empty?

        row = variant_repository.resolve_child(family, child)
        row ? [row[:code]] : []
      end

      def attribute_codes(family, attribute_candidates)
        values = normalized_values(attribute_candidates)
        return [] if values.empty?

        codes = []
        variant_repository.attribute_names(family).each do |name|
          codes |= codes_for_attribute(family, name, values)
          break if codes.size > 1
        end
        codes
      end

      def codes_for_attribute(family, name, values)
        values.filter_map do |value|
          row = variant_repository.resolve_by_attribute(family, name, value)
          row && row[:code]
        end
      end

      def normalized_values(attribute_candidates)
        Array(attribute_candidates).map { |value| value.to_s.strip }.reject(&:empty?).uniq
      end

      def unresolved(reason)
        { status: :unresolved, reason: reason }
      end
    end
  end
end
