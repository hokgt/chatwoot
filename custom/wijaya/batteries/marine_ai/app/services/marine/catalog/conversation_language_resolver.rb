# Shared, Marine-owned Conversation Language Resolver for the DETERMINISTIC product flow.
#
# The deterministic catalog reply must be delivered in the customer's own language, and that language
# is STRICTLY STICKY: it is fixed by the customer's PRIOR chat history and NEVER switches
# mid-conversation. Product decision (final): the bot supports replying in the customer's own language
# (in practice Indonesian or English, but the supported set is data-driven and never hardcoded here),
# yet an Indonesian history keeps replies Indonesian and an English history keeps them English — a
# single current turn, even a full meaningful sentence in the OTHER language, must NOT flip the
# conversation. Intentional mid-conversation switching is therefore DELIBERATELY not honored. The
# current turn only decides the language when there is NO reliable prior customer language to be
# sticky to: a conversation opener, or prior customer turns that are unreadable/unreliable.
#
# This resolver decides the product-flow delivery language deterministically and purely over its
# supplied inputs (no DB read, no provider call, no state mutation), reusing the bounded
# role-labelled context the caller already built, the IntentExtractor output, and the local
# Marine::Llm::LanguageDetector. Precedence:
#
#   1. The nearest reliable prior CUSTOMER-role turn in the bounded context is AUTHORITATIVE whenever
#      one exists — the sticky history language wins over the current turn, so an intentional switch is
#      not honored (assistant/history and role-less turns never determine customer language).
#   2. ONLY when no reliable prior customer language exists (an opener / unreadable history) does the
#      current turn decide: the provider language read from that turn wins once the turn has at least
#      one meaningful residue token, else a reliable local detection of it once at least two remain. A
#      turn with no meaningful linguistic evidence (an entity/code/slot-only continuation) still yields
#      nothing here — so a bare code / product-name opener never fixes the opener language off
#      non-linguistic tokens. "Meaningful evidence" is generic — word tokens that remain AFTER the
#      turn's own extracted entity/code/attribute candidates AND the caller-supplied trusted catalog
#      tokens (row-derived family codes/names) are removed — never a language/phrase/product list. The
#      provider (an upstream reading of the turn) is trusted on a single such token; the local detector
#      keeps the stricter two-token bar. The trusted tokens are injected by the caller, so the resolver
#      still reads no catalog.
#   3. Otherwise the assistant's configured operating language.
#   4. Otherwise nil — the caller preserves its existing fail-closed unresolved/unsupported handling
#      (never a silent force to English or Indonesian).
#
# Standards-based deprecated aliases (e.g. Indonesian `in` -> `id`) are canonicalized at every code
# source, so every downstream product-plan consumer receives one canonical code. It logs nothing.
module Marine
  module Catalog
    class ConversationLanguageResolver
      # Bounded, allowlisted language FORMAT (a format allowlist, not a language list): a 2-3 letter
      # primary subtag with an optional single subtag. Mirrors the other product-flow services.
      LANGUAGE_PATTERN = /\A[a-z]{2,3}(?:-[a-z0-9]{2,8})?\z/

      # Deprecated ISO 639-1 primary-subtag aliases mapped to their current canonical code (the fixed,
      # standards-defined set — `in`->`id`, `iw`->`he`, `ji`->`yi`, `mo`->`ro`). A bounded, generic
      # normalization, NOT a phrase/language list.
      ALIASES = { 'in' => 'id', 'iw' => 'he', 'ji' => 'yi', 'mo' => 'ro' }.freeze

      # Generic linguistic-evidence bound, mirroring Marine::Llm::LanguageDetector's own thresholds
      # (>= MIN_MEANINGFUL_TOKENS distinct alphanumeric tokens of 3+ chars). Measured over the current
      # turn AFTER its own extracted entity candidates are removed, so a bare code — of ANY shape,
      # including multi-segment codes with several 3+ char runs — is never mistaken for real words.
      MEANINGFUL_TOKEN = /[[:alnum:]]{3,}/
      MIN_MEANINGFUL_TOKENS = 2

      # The lower bar for TRUSTING the current turn's provider language: a single meaningful residue
      # token is real linguistic content the upstream provider read, so one is enough to honor the
      # provider guess (the local CLD3 fallback keeps the stricter MIN_MEANINGFUL_TOKENS bar). A
      # ZERO-residue bare entity/code/product-name still clears neither bar.
      MIN_PROVIDER_TOKENS = 1

      # Bug 2 — a defensive bound on the per-turn trusted-token array read off a (untrusted) context
      # entry, so a malformed/oversized metadata value can never create unbounded token work. The
      # caller's legitimate Catalog-derived list is far smaller than this; a forged, over-long array is
      # simply truncated and non-String members are dropped (fail closed to no subtraction).
      MAX_TRUSTED_TOKENS = 256

      # Only a CUSTOMER-role bounded context turn may determine customer language.
      CUSTOMER_ROLE = 'user'.freeze

      # Bounded provenance for the resolved code; carries no customer content.
      Result = Struct.new(:language, :reason, keyword_init: true)

      def self.resolve(**)
        new(**).resolve
      end

      # Shared bounded normalization for delivery-language state. ProductFlowStateStore uses the
      # same contract when persisting a language resolved here, so plan metadata and durable state
      # cannot disagree about aliases or valid code shape.
      def self.normalize_code(value)
        return nil unless value.is_a?(String)

        code = value.strip.downcase
        return nil if code.empty? || code == Marine::Llm::LanguageDetector::UNKNOWN[:language]
        return nil unless code.match?(LANGUAGE_PATTERN)

        primary, *rest = code.split('-')
        [ALIASES.fetch(primary, primary), *rest].join('-')
      end

      # text                - the current customer turn (String).
      # provider_language   - IntentExtractor#customer_language for THIS turn (untrusted guess).
      # context             - bounded role-labelled prior turns (Array of { role:, content: });
      #                       role-less entries are ignored (their role is unknowable, so fail closed).
      # configured_language - the assistant's configured operating language (last-resort fallback).
      # entity_candidates   - the turn's bounded extracted entity/code/attribute candidates
      #                       (IntentExtractor family_mention / explicit_child_code /
      #                       attribute_candidates); their tokens are subtracted from the current turn
      #                       so a message that is EXACTLY such a candidate carries no linguistic
      #                       evidence, while a candidate PLUS real wording still does. Bounded
      #                       extractor fields only — never a product/phrase list.
      # trusted_tokens      - trusted catalog-derived tokens (row-derived family codes/names) supplied
      #                       by the CALLER so a product-name mention is never counted as linguistic
      #                       evidence regardless of how complete the extractor's entity fields were:
      #                       their tokens are subtracted from the current turn alongside
      #                       entity_candidates. The resolver stays pure — it never reads the catalog;
      #                       the caller does the bounded lookup and injects the result. Data-driven
      #                       tokens only — never a product/phrase list. Defaults empty (unchanged).
      # rubocop:disable Metrics/ParameterLists
      # trusted_tokens is caller-injected, data-driven evidence (not behaviour): it keeps the
      # resolver pure (no DB/provider calls) while letting the caller subtract catalog-derived
      # tokens. The keyword API is intentionally flat rather than wrapped in a params object so
      # each piece of evidence stays independently named and documented above; not refactored.
      def initialize(text:, provider_language: nil, context: [], configured_language: nil,
                     entity_candidates: [], trusted_tokens: [], sticky_language: nil, established_history: false)
        @text = text.to_s
        @provider_language = normalize(provider_language)
        @context = Array(context)
        @configured_language = normalize(configured_language)
        @entity_candidates = Array(entity_candidates)
        @trusted_tokens = Array(trusted_tokens)
        # A language already resolved from a prior customer turn and persisted in the active product
        # flow. It preserves the decision made while that turn was current; invalid/absent legacy state
        # simply falls through to authoritative Catalog-filtered history detection below.
        @sticky_language = normalize(sticky_language)
        # Compatibility for an ACTIVE flow created before customer_language persistence: its language
        # was already meant to be sticky, so reconstruct it from the earliest reliable bounded customer
        # evidence rather than letting a newer short turn redefine it. The caller alone establishes the
        # active legacy lifecycle; this pure resolver still receives only bounded in-memory evidence.
        @established_history = established_history == true
      end
      # rubocop:enable Metrics/ParameterLists

      def resolve
        return Result.new(language: @sticky_language, reason: :prior_customer) if @sticky_language

        prior = prior_customer_language
        return Result.new(language: prior, reason: :prior_customer) if prior

        current = current_turn_language
        return Result.new(language: current, reason: :current_turn) if current

        return Result.new(language: @configured_language, reason: :configured) if @configured_language

        Result.new(language: nil, reason: :unresolved)
      end

      private

      # The current-turn language, consulted ONLY when no reliable prior customer language exists (an
      # opener or unreadable history) — mid-conversation the sticky prior history has already won, so the
      # current turn never switches it. Two evidence bars are read over the SAME residue token set (the
      # turn minus its own extracted entity candidates AND the current trusted catalog tokens):
      #   - the PROVIDER language, an upstream reading of the turn's real linguistic content, is honored
      #     once at least MIN_PROVIDER_TOKENS residue token remains — one genuine non-entity word is
      #     enough to give the provider something to read;
      #   - otherwise a local CLD3 detection of that same linguistic RESIDUE, but only once the stricter
      #     MIN_MEANINGFUL_TOKENS distinct residue tokens remain (mirroring the detector's own bound).
      # A ZERO-residue entity/code/slot-only continuation clears NEITHER bar: NEITHER the provider guess
      # NOR a local detection of the bare entity is trusted, so the caller falls through to the configured
      # language rather than fixing the opener language off a bare entity. Subtracting the entity
      # candidates AND trusted catalog tokens keeps a product name out of both the residue count and the
      # detector input, so a product mention never fixes the opener language.
      def current_turn_language
        residue_count = residue_tokens.length
        return @provider_language if @provider_language && residue_count >= MIN_PROVIDER_TOKENS
        return detected_reliable(residue_text(@text, @entity_candidates + @trusted_tokens)) if residue_count >= MIN_MEANINGFUL_TOKENS

        nil
      end

      # The current turn's meaningful residue tokens: its distinct 3+ char alphanumeric tokens once its
      # own extracted entity candidates AND the caller-supplied trusted catalog tokens are removed. The
      # two current-turn evidence bars both measure their count, so a bare code / product name — of ANY
      # shape — is never mistaken for real words and a scope label alone never erases a genuinely
      # meaningful current sentence.
      def residue_tokens
        text_tokens - candidate_tokens - trusted_token_set
      end

      # Distinct 3+ char alphanumeric tokens in the current turn.
      def text_tokens
        token_set(@text)
      end

      # The union of 3+ char alphanumeric tokens across the bounded extracted candidates.
      def candidate_tokens
        token_union(@entity_candidates)
      end

      # The union of 3+ char alphanumeric tokens across the caller-supplied CURRENT-turn trusted catalog
      # tokens (never a prior turn's — those are read per-turn in #prior_entity_only?).
      def trusted_token_set
        token_union(@trusted_tokens)
      end

      # The union of 3+ char alphanumeric tokens across a bounded list of values.
      def token_union(values)
        Array(values).each_with_object(Set.new) { |value, set| set.merge(token_set(value)) }
      end

      # The linguistic RESIDUE of `content` fed to the detector: the content with every 3+ char
      # alphanumeric token that belongs to `removal` (the entity/catalog tokens) stripped out, the rest
      # of the wording, punctuation and short words left intact. This keeps a product name out of CLD3's
      # input while preserving the genuine language signal, so detection reads the residue rather than the
      # unfiltered product-bearing turn. With nothing to remove the content is returned verbatim, so a
      # turn carrying no catalog tokens is detected exactly as before.
      def residue_text(content, removal)
        removal_tokens = token_union(removal)
        text = content.to_s
        return text if removal_tokens.empty?

        text.gsub(MEANINGFUL_TOKEN) { |token| removal_tokens.include?(token.downcase) ? ' ' : token }
            .squeeze(' ').strip
      end

      def token_set(value)
        value.to_s.downcase.scan(MEANINGFUL_TOKEN).to_set
      end

      # The nearest reliable prior CUSTOMER-role turn's language (newest first). Assistant/history and
      # role-less turns are never consulted, so the assistant's own language can never masquerade as
      # the customer's. Bug 2: a prior turn that is only a Catalog product name carries no meaningful
      # linguistic residue once ITS OWN caller-computed trusted catalog tokens are subtracted — it is
      # skipped WITHOUT a CLD3 detection (so it can never poison the sticky language), and the next
      # older customer turn is tried; the first reliable eligible prior still wins. For an active legacy
      # flow whose established language predates persistence, the caller asks for oldest-first selection
      # so a newer short residue cannot redefine that already-sticky conversation. A turn that IS kept
      # is detected from that same linguistic RESIDUE, never its full product-bearing content, so a
      # product name surviving alongside real wording can never poison the sticky reading either.
      def prior_customer_language
        customer_turns_in_priority_order.each do |turn|
          next if prior_entity_only?(turn)

          language = detected_reliable(residue_text(turn[:content], turn[:trusted_tokens]))
          return language if language
        end
        nil
      end

      def customer_turns_in_priority_order
        turns = customer_turns_chronological
        @established_history ? turns : turns.reverse
      end

      def customer_turns_chronological
        @context.filter_map do |turn|
          next unless turn.is_a?(Hash)
          next unless (turn[:role] || turn['role']).to_s == CUSTOMER_ROLE

          content = (turn[:content] || turn['content']).to_s.presence
          next unless content

          { content: content, trusted_tokens: sanitized_trusted_tokens(turn) }
        end
      end

      # A prior customer turn carries no meaningful linguistic evidence once ITS OWN per-turn trusted
      # catalog tokens are removed — a product-name-only turn. The trusted tokens come from THAT context
      # turn (never the current @trusted_tokens), so one turn's product name never erases another's
      # genuine wording.
      def prior_entity_only?(turn)
        (token_set(turn[:content]) - token_union(turn[:trusted_tokens])).length < MIN_MEANINGFUL_TOKENS
      end

      # The per-turn trusted catalog tokens read off a (untrusted) context entry, sanitized to a bounded
      # array of Strings: a malformed/non-array/non-String/oversized value fails closed to NO
      # subtraction and never creates unbounded token work. The caller recomputes these from authoritative
      # Catalog rows, so a forged value never survives into the context the resolver reads anyway.
      def sanitized_trusted_tokens(turn)
        raw = turn[:trusted_tokens] || turn['trusted_tokens']
        return [] unless raw.is_a?(Array)

        raw.first(MAX_TRUSTED_TOKENS).select { |token| token.is_a?(String) }
      end

      # A canonical language code the shared local detector reads RELIABLY from `text`, else nil (an
      # unreliable/unknown reading is no signal). No extra provider call is made.
      def detected_reliable(text)
        result = Marine::Llm::LanguageDetector.new(text.to_s).detect
        return nil unless result[:reliable]

        normalize(result[:language])
      end

      # Bounded, allowlisted, alias-canonicalized code, or nil for a missing/malformed value.
      def normalize(value)
        self.class.normalize_code(value)
      end
    end
  end
end
