# Step 17 — deterministic product_listing Evidence renderer.
#
# When a Model 2 listing candidate fails the SEMANTIC verifier (rejection / exception / missing /
# unavailable) but has already passed the deterministic fact + persona gates, the presenter DISCARDS
# that candidate and renders a reply from the frozen marine_evidence_v2 Evidence Packet ALONE through
# this renderer, so the customer still receives a truthful bounded listing without invoking the legacy
# RAG path. It is scoped to EXACTLY the single response goal answer_product_listing and the single fact
# key product_listing; a product_information packet (or any other goal/fact) is out of scope and yields
# nil so the presenter keeps that path's existing closed fallback.
#
# It reads ONLY controlled Evidence values — each listed product's code and optional display name, the
# returned_count / total_count, the complete flag, and the packet customer_language — and renders them
# through backend-owned localized templates. It never reads the raw customer request/history, calls a
# provider / RAG / repository, adds a product description, stock/status/quantity, price/discount,
# warehouse/location, delivery/lead time, or any qualitative claim, and never presents catalog
# membership as stock availability. The product set and counts are direct Evidence values.
#
# It FAILS CLOSED (returns nil, never repairs) on a non-listing, malformed, or unsupported-language
# packet, and never raises.
class Marine::Backend::ProductListingEvidenceRenderer
  EVIDENCE_VERSION = 'marine_evidence_v2'.freeze
  LISTING_GOAL = 'answer_product_listing'.freeze
  # The currently contract-supported customer languages (mirrors the PriceDisplayFormatter locale
  # contract). An unsupported language is an explicit safe failure — never an invented template.
  SUPPORTED_LANGUAGES = %w[id en].freeze
  # The listing page bound (mirrors EvidencePacketBuilder::MAX_LISTING_PRODUCTS).
  MAX_PRODUCTS = 20

  # packet: a frozen marine_evidence_v2 answer_product_listing Evidence Packet.
  # Returns the deterministic reply String, or nil on any non-listing/malformed/unsupported outcome.
  def call(packet:)
    return nil unless renderable_packet?(packet)

    listing = packet[:facts][:product_listing]
    return nil unless valid_listing?(listing)
    return nil unless SUPPORTED_LANGUAGES.include?(packet[:customer_language])

    render(listing, packet[:customer_language])
  rescue StandardError
    nil
  end

  private

  # In scope ONLY for a v2 packet whose sole response goal is answer_product_listing and whose facts
  # carry the product_listing key. product_information and every other goal/fact is out of scope.
  def renderable_packet?(packet)
    packet.is_a?(Hash) &&
      packet[:evidence_version] == EVIDENCE_VERSION &&
      packet[:response_goals] == [LISTING_GOAL] &&
      packet[:facts].is_a?(Hash) &&
      packet[:facts].key?(:product_listing)
  end

  # A well-formed listing fact: a bounded, non-empty page of { code, name? } products, a returned_count
  # that equals the page size, a boolean complete, and a total_count consistent with completeness
  # (equal to returned when complete; an Integer strictly greater, or omitted, when not).
  def valid_listing?(listing) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- a flat sequence of independent fail-closed listing guards
    return false unless listing.is_a?(Hash)

    products = listing[:products]
    return false unless products.is_a?(Array) && !products.empty? && products.length <= MAX_PRODUCTS
    return false unless products.all? { |product| valid_product?(product) }
    return false unless listing[:returned_count] == products.length
    return false unless [true, false].include?(listing[:complete])

    valid_total?(listing[:total_count], products.length, listing[:complete])
  end

  def valid_product?(product)
    product.is_a?(Hash) && present_string?(product[:code]) &&
      (product[:name].nil? || present_string?(product[:name]))
  end

  def valid_total?(total, returned, complete)
    return total == returned if complete
    return true if total.nil?

    total.is_a?(Integer) && total > returned
  end

  def present_string?(value)
    value.is_a?(String) && !value.strip.empty?
  end

  def render(listing, language)
    items = listing[:products].map { |product| product_label(product) }.join(', ')
    "#{lead_sentence(listing, language)} #{items}."
  end

  # Exact code + optional display name, both literal — never a description or any other claim.
  def product_label(product)
    product[:name] ? "#{product[:code]} (#{product[:name]})" : product[:code]
  end

  def lead_sentence(listing, language)
    case language
    when 'id' then indonesian_lead(listing[:complete], listing[:returned_count], listing[:total_count])
    when 'en' then english_lead(listing[:complete], listing[:returned_count], listing[:total_count])
    end
  end

  # Catalog-MEMBERSHIP framing only ("produk dalam katalog kami" = products in our catalogue), never
  # stock availability. An incomplete page is stated as bounded and never as the whole catalogue.
  def indonesian_lead(complete, returned, total)
    return 'Berikut produk dalam katalog kami:' if complete
    return "Berikut #{returned} dari #{total} produk dalam katalog kami:" if total

    "Berikut sebagian produk dalam katalog kami (#{returned} produk):"
  end

  def english_lead(complete, returned, total)
    return 'Here are the products in our catalog:' if complete
    return "Here are #{returned} of #{total} products in our catalog:" if total

    "Here are some of the products in our catalog (#{returned} products):"
  end
end
