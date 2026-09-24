# Shared, Marine-owned Conversation Language Resolver for the DETERMINISTIC product flow.
#
# The deterministic catalog reply must be delivered in the customer's own language. The per-turn
# provider (IntentExtractor#customer_language) reads that language from the SAME extraction, but it
# guesses a language even for a turn that carries NO linguistic evidence — a bare product code /
# slot answer / entity-only continuation (classifying a code as English inside an Indonesian
# conversation). Copying that guess straight to plan[:language] then delivers a wrong-language reply.
#
# This resolver decides the product-flow delivery language deterministically and purely over its
# supplied inputs (no DB read, no provider call, no state mutation), reusing the bounded
# role-labelled context the caller already built, the IntentExtractor output, and the local
# Marine::Llm::LanguageDetector. Precedence:
#
#   1. Current turn WITH meaningful linguistic evidence is authoritative (permits intentional
#      switching): the provider language read from that same turn wins, else a reliable local
#      detection of it. "Meaningful evidence" is generic — enough word tokens to be language-bearing
#      AFTER the turn's own extracted entity/code/attribute candidates are removed — never a
#      language/phrase/product list.
#   2. An entity/code/slot-only turn (no meaningful evidence once its candidates are removed) trusts
#      NEITHER the provider guess NOR a local detection of the bare entity, and instead inherits the
#      nearest reliable prior CUSTOMER-role turn from the bounded context (assistant/history turns
#      never determine customer language).
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

      # Only a CUSTOMER-role bounded context turn may determine customer language.
      CUSTOMER_ROLE = 'user'.freeze

      # Bounded provenance for the resolved code; carries no customer content.
      Result = Struct.new(:language, :reason, keyword_init: true)

      def self.resolve(**)
        new(**).resolve
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
      def initialize(text:, provider_language: nil, context: [], configured_language: nil, entity_candidates: [])
        @text = text.to_s
        @provider_language = normalize(provider_language)
        @context = Array(context)
        @configured_language = normalize(configured_language)
        @entity_candidates = Array(entity_candidates)
      end

      def resolve
        current = current_turn_language
        return Result.new(language: current, reason: :current_turn) if current

        prior = prior_customer_language
        return Result.new(language: prior, reason: :prior_customer) if prior

        return Result.new(language: @configured_language, reason: :configured) if @configured_language

        Result.new(language: nil, reason: :unresolved)
      end

      private

      # The authoritative current-turn language, or nil when the turn carries no meaningful linguistic
      # evidence (an entity/code/slot-only continuation). For such a turn NEITHER the provider guess
      # NOR a local detection of the bare entity is trusted — both are unreliable for a code — so the
      # caller inherits the nearest prior customer turn. A turn with real wording (even alongside an
      # entity candidate) keeps its provider language, else a locally reliable reading of it, so an
      # intentional language switch is honored.
      def current_turn_language
        return nil if entity_only?

        @provider_language || detected_reliable(@text)
      end

      # An entity/code/slot-only turn: once the turn's own extracted entity candidates are removed,
      # too few word tokens remain to be language-bearing. This is the condition — a scope label alone
      # never erases the authority of a genuinely meaningful current sentence.
      def entity_only?
        (text_tokens - candidate_tokens).length < MIN_MEANINGFUL_TOKENS
      end

      # Distinct 3+ char alphanumeric tokens in the current turn.
      def text_tokens
        token_set(@text)
      end

      # The union of 3+ char alphanumeric tokens across the bounded extracted candidates.
      def candidate_tokens
        @entity_candidates.each_with_object(Set.new) { |candidate, set| set.merge(token_set(candidate)) }
      end

      def token_set(value)
        value.to_s.downcase.scan(MEANINGFUL_TOKEN).to_set
      end

      # The nearest reliable prior CUSTOMER-role turn's language (newest first). Assistant/history and
      # role-less turns are never consulted, so the assistant's own language can never masquerade as
      # the customer's.
      def prior_customer_language
        customer_turns_newest_first.each do |content|
          language = detected_reliable(content)
          return language if language
        end
        nil
      end

      def customer_turns_newest_first
        @context.reverse.filter_map do |turn|
          next unless turn.is_a?(Hash)
          next unless (turn[:role] || turn['role']).to_s == CUSTOMER_ROLE

          (turn[:content] || turn['content']).to_s.presence
        end
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
        return nil unless value.is_a?(String)

        code = value.strip.downcase
        return nil if code.empty? || code == Marine::Llm::LanguageDetector::UNKNOWN[:language]
        return nil unless code.match?(LANGUAGE_PATTERN)

        canonicalize(code)
      end

      # Canonicalize the PRIMARY subtag through the deprecated-alias map, preserving any region subtag.
      def canonicalize(code)
        primary, *rest = code.split('-')
        [ALIASES.fetch(primary, primary), *rest].join('-')
      end
    end
  end
end
