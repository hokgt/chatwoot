# Detects the language of a piece of text using CLD3 when the gem is available.
# It never raises and never adds a new dependency: if CLD3 is missing or errors,
# it degrades to an "unknown" result so callers can branch safely.
#
# Returns: { language:, reliable:, confidence: }
class Marine::Llm::LanguageDetector
  UNKNOWN = { language: 'unknown', reliable: false, confidence: 0.0 }.freeze

  def initialize(text)
    @text = text.to_s
  end

  def detect
    return UNKNOWN if @text.strip.blank?
    return UNKNOWN unless cld3_available?

    result = identifier.find_language(@text)
    normalize(result)
  rescue StandardError => e
    Rails.logger.warn("Marine::Llm::LanguageDetector failed: #{e.message}")
    UNKNOWN
  end

  private

  def cld3_available?
    defined?(CLD3::NNetLanguageIdentifier)
  end

  def identifier
    CLD3::NNetLanguageIdentifier.new(0, 1000)
  end

  def normalize(result)
    return UNKNOWN if result.nil?

    reliable = result.respond_to?(:reliable?) ? result.reliable? : false
    {
      language: result.language.to_s.presence || 'unknown',
      reliable: reliable,
      confidence: confidence_for(result)
    }
  end

  def confidence_for(result)
    return result.probability.to_f if result.respond_to?(:probability)
    return result.proportion.to_f if result.respond_to?(:proportion)

    0.0
  end
end
