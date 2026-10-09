# Deterministic company-offerings Evidence renderer.
#
# A broad company overview is backed by authoritative Item Group names, never product rows or RAG.
# This renderer consumes only a deeply frozen marine_evidence_v2 packet whose sole goal/fact is the
# closed company_offerings contract. It returns nil for every malformed, mutable, unsupported-language,
# wrong-goal, wrong-provenance, or inconsistent packet and never repairs input or calls a provider.
class Marine::Backend::CompanyOfferingsEvidenceRenderer
  EVIDENCE_VERSION = 'marine_evidence_v2'.freeze
  OFFERINGS_GOAL = 'answer_product_overview'.freeze
  OFFERINGS_INTENT = 'product_overview'.freeze
  OFFERINGS_SOURCE = 'catalog_item_group_repository'.freeze
  FACT_KEYS = %i[item_groups returned_count total_count complete source checked_at].freeze
  SUPPORTED_LANGUAGES = %w[id en].freeze
  MAX_ITEM_GROUPS = 20
  UTC_ISO8601 = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/

  def call(packet:)
    return nil unless renderable_packet?(packet)

    render(packet[:facts][:company_offerings], packet[:customer_language])
  rescue StandardError
    nil
  end

  private

  def renderable_packet?(packet) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- flat fail-closed gates
    packet.is_a?(Hash) && deeply_frozen?(packet) &&
      packet[:evidence_version] == EVIDENCE_VERSION &&
      packet[:response_goals] == [OFFERINGS_GOAL] &&
      packet.dig(:scenario, :intents) == [OFFERINGS_INTENT] &&
      packet[:validated_slots] == {} &&
      SUPPORTED_LANGUAGES.include?(packet[:customer_language]) &&
      packet[:facts].is_a?(Hash) && packet[:facts].keys == %i[company_offerings] &&
      valid_fact?(packet[:facts][:company_offerings])
  end

  def valid_fact?(fact) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity -- flat fail-closed gates
    return false unless fact.is_a?(Hash) && fact.keys.sort == FACT_KEYS.sort

    groups = fact[:item_groups]
    return false unless groups.is_a?(Array) && groups.any? && groups.length <= MAX_ITEM_GROUPS
    return false unless groups.all? { |group| safe_string?(group) }
    return false unless groups.uniq.length == groups.length
    return false unless fact[:returned_count] == groups.length
    return false unless [true, false].include?(fact[:complete])
    return false unless valid_total?(fact[:total_count], groups.length, fact[:complete])

    fact[:source] == OFFERINGS_SOURCE && fact[:checked_at].is_a?(String) && fact[:checked_at].match?(UTC_ISO8601)
  end

  def valid_total?(total, returned, complete)
    return total == returned if complete
    return true if total.nil?

    total.is_a?(Integer) && total > returned
  end

  def safe_string?(value)
    value.is_a?(String) && !value.strip.empty? && !value.match?(/[[:cntrl:]]/)
  end

  def deeply_frozen?(value)
    return false unless value.frozen?

    case value
    when Hash then value.all? { |key, child| key.frozen? && deeply_frozen?(child) }
    when Array then value.all? { |child| deeply_frozen?(child) }
    else true
    end
  end

  def render(fact, language)
    groups = fact[:item_groups].join(', ')
    "#{lead_sentence(fact, language)} #{groups}."
  end

  def lead_sentence(fact, language)
    return complete_lead(language) if fact[:complete]
    return bounded_lead(language, fact[:returned_count], fact[:total_count]) if fact[:total_count]

    partial_lead(language, fact[:returned_count])
  end

  def complete_lead(language)
    language == 'id' ? 'Kategori produk yang kami tawarkan:' : 'Product categories we offer:'
  end

  def bounded_lead(language, returned, total)
    return "Berikut #{returned} dari #{total} kategori produk yang kami tawarkan:" if language == 'id'

    "Here are #{returned} of #{total} product categories we offer:"
  end

  def partial_lead(language, returned)
    return "Berikut sebagian kategori produk yang kami tawarkan (#{returned} kategori):" if language == 'id'

    "Here are some of the product categories we offer (#{returned} categories):"
  end
end
