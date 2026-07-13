# Detects the language of a piece of text using CLD3 when the gem is available.
# It never raises and never adds a new dependency: if CLD3 is missing or errors,
# it degrades to an "unknown" result so callers can branch safely.
#
# Returns: { language:, reliable:, confidence: }
class Marine::Llm::LanguageDetector
  UNKNOWN = { language: 'unknown', reliable: false, confidence: 0.0 }.freeze

  # CLD3 is unreliable on very short texts — a single 4-letter word like
  # "halo" is misidentified as Japanese (ja, 0.90 confidence).  For texts
  # with fewer than MIN_TOKENS alphanumeric tokens (3+ chars each), we skip
  # detection entirely and return "unknown" so the translation pipeline
  # degrades to a no-op instead of mistranslating.
  MIN_TOKENS = 2
  TOKEN_PATTERN = /[[:alnum:]]{3,}/.freeze

  def initialize(text)
    @text = text.to_s
  end

  def detect
    return UNKNOWN if @text.strip.blank?
    return UNKNOWN if insufficient_tokens?
    return UNKNOWN unless cld3_available?

    result = identifier.find_language(@text)
    normalize(result)
  rescue StandardError => e
    Rails.logger.warn("Marine::Llm::LanguageDetector failed: #{e.message}")
    UNKNOWN
  end

  private

  # Returns true when the text has fewer than MIN_TOKENS alphanumeric tokens
  # of 3+ characters — the zone where CLD3 is unreliable.
  def insufficient_tokens?
    tokens = @text.downcase.scan(TOKEN_PATTERN).uniq
    tokens.length < MIN_TOKENS
  end

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
