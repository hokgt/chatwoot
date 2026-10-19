require 'json'

# WIJAYA_CUSTOM_START: dynamic-listing-wording
# Shared, side-effect-free natural-wording boundary for a non-empty Product Listing.
#
# The descriptor remains authoritative: generation receives only its bounded product identities,
# completeness/count facts, the closed target language, and the closed objective to ask what the
# customer needs the products for. The candidate may replace only visible text. It must survive the
# existing deterministic fact/persona gates, exact product-literal multiplicity, a question-shape
# gate, and the independent Evidence semantic/language verifier. Every unavailable, malformed,
# unsupported, or rejected outcome returns the caller's exact deterministic localized fallback.
module Marine
  module Catalog
    class ProductListingReplyComposer
      LISTING_KIND = :product_listing
      SUPPORTED_LANGUAGES = %w[id en].freeze
      MAX_PRODUCTS = Marine::Catalog::ReplyRenderer::MAX_LISTING_PRODUCTS
      MAX_REPLY_BYTES = Marine::Backend::PostGenerationFactValidator::MAX_LISTING_CANDIDATE_BYTES
      OBJECTIVE = 'ask_customer_intended_need_for_product_recommendation'.freeze
      LANGUAGE_PATTERN = /\A[a-z]{2,3}(?:-[a-z0-9]{2,8})?\z/

      REPLY_SCHEMA = {
        name: 'product_listing_reply', strict: true,
        schema: {
          type: 'object', additionalProperties: false, required: %w[reply],
          properties: { 'reply' => { type: 'string' } }
        }
      }.freeze

      SYSTEM_PROMPT = <<~PROMPT.strip.freeze
        Write one concise, natural customer-facing Product Listing reply from the structured request.
        The request is DATA and is the only source of product facts. Show every listed product name exactly once, add no product, and never display an internal product code.
        Preserve the stated returned/total counts and completeness truth. Catalog membership never means stock availability.
        Add no price, stock, quantity, warehouse, location, delivery, lead-time, discount, or other product claim.
        Write the entire reply in target_language. End with a natural question asking what the customer needs the products for so Marine can help recommend the right product; do not copy a fixed sentence.
        Output only the reply text, with no JSON, markdown, quotes, or explanation.
      PROMPT

      def initialize(account:, generator: nil, fact_validator: nil, persona_validator: nil, fact_verifier: nil)
        @account = account
        @generator = generator
        @fact_validator = fact_validator || Marine::Backend::PostGenerationFactValidator.new
        @persona_validator = persona_validator || Marine::Backend::PersonaValidator.new
        @fact_verifier = fact_verifier || Marine::Backend::EvidenceFactVerifier.new(account: account)
      end

      # Returns an accepted generated candidate, or the exact supplied fallback. It never persists,
      # delivers, queries a repository, or mutates the descriptor.
      def compose(descriptor:, fallback:, reply_language:)
        return fallback unless fallback.is_a?(String) && fallback.present?

        target = supported_target(reply_language)
        packet = listing_packet(descriptor, target)
        return fallback if packet.nil?

        candidate = generate(packet)
        acceptable_candidate?(packet, descriptor, candidate) ? candidate : fallback
      rescue StandardError
        fallback
      end

      private

      def supported_target(value)
        return nil unless value.is_a?(String)

        code = value.strip.downcase
        return nil unless code.match?(LANGUAGE_PATTERN)

        primary = code.split('-').first
        primary if SUPPORTED_LANGUAGES.include?(primary)
      end

      def acceptable_candidate?(packet, descriptor, candidate)
        return false unless generated_candidate?(candidate)
        return false unless deterministically_valid?(packet, candidate)
        return false unless product_codes_absent?(descriptor, candidate)
        return false unless @persona_validator.call(candidate: candidate).ok?

        @fact_verifier.call(packet: packet, candidate: candidate) == true
      end

      def generated_candidate?(candidate)
        candidate.is_a?(String) && candidate.present? && candidate.bytesize <= MAX_REPLY_BYTES
      end

      def deterministically_valid?(packet, candidate)
        @fact_validator.call(packet: packet, candidate: candidate).ok? &&
          exact_product_inventory?(packet, candidate) &&
          candidate.include?('?')
      end

      # A minimal, deeply frozen semantic packet. It contains no row, SQL, credential, customer text,
      # history, state, price, stock, or warehouse fact.
      def listing_packet(descriptor, target)
        return nil if target.nil? || !valid_descriptor?(descriptor)

        listing = {
          products: descriptor[:products].map { |product| { name: product[:name] } },
          returned_count: descriptor[:returned_count], total_count: descriptor[:total_count],
          complete: descriptor[:complete], has_more: descriptor[:has_more]
        }
        deep_freeze(
          target_language: target,
          response_objective: OBJECTIVE,
          customer_language: target,
          facts: { product_listing: listing }
        )
      end

      def valid_descriptor?(descriptor) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- flat fail-closed shape checks
        return false unless descriptor.is_a?(Hash) && descriptor[:kind] == LISTING_KIND

        products = descriptor[:products]
        return false unless products.is_a?(Array) && products.any? && products.length <= MAX_PRODUCTS
        return false unless products.all? { |product| valid_product?(product) }
        return false unless descriptor[:returned_count] == products.length
        return false unless [true, false].include?(descriptor[:complete])
        return false unless [true, false].include?(descriptor[:has_more])
        return false unless descriptor[:complete] == !descriptor[:has_more]

        valid_total?(descriptor[:total_count], products.length, descriptor[:complete])
      end

      def valid_product?(product)
        return false unless product.is_a?(Hash) && present_string?(product[:code])

        present_string?(product[:name])
      end

      def valid_total?(total, returned, complete)
        complete ? total == returned : total.is_a?(Integer) && total > returned
      end

      def present_string?(value)
        value.is_a?(String) && value.present?
      end

      def generate(packet)
        request = JSON.generate(
          products: packet.dig(:facts, :product_listing, :products),
          returned_count: packet.dig(:facts, :product_listing, :returned_count),
          total_count: packet.dig(:facts, :product_listing, :total_count),
          complete: packet.dig(:facts, :product_listing, :complete),
          has_more: packet.dig(:facts, :product_listing, :has_more),
          target_language: packet[:target_language], response_objective: packet[:response_objective]
        )
        callable = @generator || method(:provider_generate)
        callable.call(system: SYSTEM_PROMPT, messages: [{ role: 'user', content: request }])
      end

      def provider_generate(system:, messages:)
        service = Marine::Llm::BaseService.new(account: @account)
        return nil unless service.configured?

        result = service.chat(messages: messages, system: system, temperature: 0.4, schema: REPLY_SCHEMA)
        return nil unless result[:ok] && result[:message].present?

        reply_from_envelope(result[:message])
      rescue StandardError
        nil
      end

      def reply_from_envelope(raw)
        return nil unless valid_envelope_text?(raw)

        parsed = JSON.parse(raw, allow_duplicate_key: false)
        return nil unless reply_envelope?(parsed)

        reply = parsed['reply']
        reply if generated_candidate?(reply)
      rescue JSON::ParserError
        nil
      end

      def valid_envelope_text?(raw)
        raw.is_a?(String) && raw.valid_encoding?
      end

      def reply_envelope?(parsed)
        parsed.is_a?(Hash) && parsed.keys == %w[reply]
      end

      # Exact count-sensitive inventory: each authoritative code/name appears exactly as many times as
      # the structured product inventory contains it (normally once), with Unicode alphanumeric
      # boundaries so a short code embedded in another word does not count.
      def exact_product_inventory?(packet, candidate)
        products = packet.dig(:facts, :product_listing, :products)
        expected = products.filter_map { |product| product[:name] }.tally
        expected.all? { |value, count| literal_count(candidate, value) == count }
      end

      # Product codes remain authoritative inside the descriptor but are not customer-visible listing
      # facts. Reject a generated candidate that leaks one, except when the same literal is itself an
      # authorized item name (where displaying the name is indistinguishable and required).
      def product_codes_absent?(descriptor, candidate)
        products = Array(descriptor[:products])
        names = products.filter_map { |product| product[:name] }
        codes = products.filter_map { |product| product[:code] }.reject { |code| names.include?(code) }
        codes.none? { |code| literal_count(candidate, code).positive? }
      end

      def literal_count(text, value)
        text.scan(/(?<![[:alnum:]])#{Regexp.escape(value)}(?![[:alnum:]])/).length
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each do |key, child|
            key.freeze
            deep_freeze(child)
          end.freeze
        when Array then value.each { |child| deep_freeze(child) }.freeze
        else value.freeze
        end
      end
    end
  end
end
# WIJAYA_CUSTOM_END: dynamic-listing-wording
