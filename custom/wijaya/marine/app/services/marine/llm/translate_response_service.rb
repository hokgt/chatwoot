# Translates a Marine answer from the assistant/knowledge base language back into
# the customer's language before it is delivered. The LLM is only invoked when a
# translation is actually needed (target language is known and differs from the
# source) and Marine LLM is configured. It never raises: callers always receive a
# JSON-safe hash. Only the answer text is translated; citations and other
# retrieval metadata are left untouched by the caller.
#
# Returns:
#   { ok:, text:, original_text:, source_language:, target_language:,
#     translated:, error:, skipped_reason? }
class Marine::Llm::TranslateResponseService
  DEFAULT_SOURCE = 'en'.freeze

  def initialize(text:, target_language:, source_language: nil, account: nil)
    @text = text.to_s
    @target_language = normalize(target_language)
    @source_language = normalize(source_language)
    @account = account
  end

  def call
    source = @source_language || detected_source || DEFAULT_SOURCE

    return skip(source, 'blank_input') if @text.strip.blank?
    return skip(source, 'unknown_target_language') if @target_language.blank?
    return skip(source, 'same_language') if source == @target_language
    return skip(source, 'not_configured') unless base_service.configured?

    perform_translation(source)
  end

  private

  def perform_translation(source)
    result = base_service.complete(prompt: @text, system: translation_prompt(source))
    translated = result[:message].to_s.strip
    return failure(source, result[:error]) unless result[:ok] && translated.present?

    {
      ok: true,
      text: translated,
      original_text: @text,
      source_language: source,
      target_language: @target_language,
      translated: true,
      error: nil
    }
  rescue StandardError => e
    failure(source, e.message)
  end

  def skip(source, reason)
    {
      ok: true,
      text: @text,
      original_text: @text,
      source_language: source,
      target_language: @target_language,
      translated: false,
      error: nil,
      skipped_reason: reason
    }
  end

  def failure(source, error)
    {
      ok: false,
      text: @text,
      original_text: @text,
      source_language: source,
      target_language: @target_language,
      translated: false,
      error: error.to_s.presence || 'translation_failed'
    }
  end

  def detected_source
    normalize(Marine::Llm::LanguageDetector.new(@text).detect[:language])
  end

  def translation_prompt(source)
    "You are a professional translator. Translate the message from #{source} to #{@target_language}. " \
      'Preserve meaning, tone, names, numbers, URLs, and formatting. ' \
      'Return only the translated text with no quotes, labels, or explanations.'
  end

  def normalize(language)
    value = language.to_s.strip.downcase
    return nil if value.blank? || value == 'unknown'

    value
  end

  def base_service
    @base_service ||= Marine::Llm::BaseService.new(account: @account)
  end
end
