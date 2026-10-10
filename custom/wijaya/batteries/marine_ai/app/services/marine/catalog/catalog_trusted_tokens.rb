# Bug 2 — a small, battery-local collaborator that computes the bounded, Catalog-derived TRUSTED
# TOKENS for a single customer turn, and enriches a bounded role-labelled context so the pure
# ConversationLanguageResolver can subtract per-turn trusted tokens from each PRIOR customer turn.
#
# It owns the single bounded algorithm shared by both callers (ProductQueryOrchestrator and
# AuthorityCoordinator), so the two never drift: each distinct meaningful turn token (resolver
# MEANINGFUL_TOKEN rule, capped at MAX_RECOVERY_TOKENS) is searched case-insensitively against the
# active family rows (each search clamped by RECOVERY_FAMILY_LIMIT), the matched families are deduped
# by code, and each matched row's code AND name are tokenized with the SAME MEANINGFUL_TOKEN rule into
# one flat, deduped token list. Catalog unavailability degrades to [] (never raises).
#
# The only product-name knowledge comes from the injected read-only ProductFamilyRepository — there is
# no product/phrase list here. It performs only bounded SELECT-only reads; it holds no state.
module Marine
  module Catalog
    class CatalogTrustedTokens
      # Mirror ProductQueryOrchestrator's current-turn bounds so the per-turn algorithm is identical.
      MAX_RECOVERY_TOKENS = 24
      RECOVERY_FAMILY_LIMIT = 50

      MEANINGFUL_TOKEN = Marine::Catalog::ConversationLanguageResolver::MEANINGFUL_TOKEN
      CUSTOMER_ROLE = Marine::Catalog::ConversationLanguageResolver::CUSTOMER_ROLE

      def initialize(family_repository:)
        @family_repository = family_repository
      end

      # The bounded Catalog-derived trusted tokens for ONE turn's own text. Catalog unavailability
      # degrades to NO trusted tokens — the language path never raises on an outage.
      def for_text(text)
        families = turn_tokens(text).flat_map { |token| @family_repository.active_candidates(query: token, limit: RECOVERY_FAMILY_LIMIT) }
                                    .uniq { |family| family[:code] }
        families.flat_map { |family| family_tokens(family) }.uniq
      rescue Marine::Catalog::Errors::CatalogError
        []
      end

      # Build a FRESH, sanitized context: every entry is rebuilt from its role + content so the
      # caller never mutates ContextBuilder's supplied history. Each CUSTOMER turn is enriched with
      # freshly computed, Catalog-derived trusted tokens for THAT turn — any incoming `trusted_tokens`
      # on the untrusted context is DISCARDED (overwritten), never reused. Assistant / role-less turns
      # are non-authoritative and gain NO trusted metadata.
      def enrich_context(context)
        Array(context).filter_map do |turn|
          next unless turn.is_a?(Hash)

          role = (turn[:role] || turn['role']).to_s
          content = (turn[:content] || turn['content']).to_s
          entry = { role: role, content: content }
          entry[:trusted_tokens] = for_text(content) if role == CUSTOMER_ROLE
          entry
        end
      end

      private

      # Distinct meaningful tokens of the turn, bounded like recovery so at most MAX_RECOVERY_TOKENS
      # repository lookups are issued for the language path.
      def turn_tokens(text)
        text.to_s.downcase.scan(MEANINGFUL_TOKEN).uniq.first(MAX_RECOVERY_TOKENS)
      end

      # A matched family's trusted tokens: its row-derived code AND name, tokenized with the resolver's
      # MEANINGFUL_TOKEN rule so they subtract exactly the tokens the resolver measures.
      def family_tokens(family)
        "#{family[:name]} #{family[:code]}".downcase.scan(MEANINGFUL_TOKEN)
      end
    end
  end
end
