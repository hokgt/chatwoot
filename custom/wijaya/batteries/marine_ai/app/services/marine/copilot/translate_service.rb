# Translates the agent's current/selected draft text into a target language using
# the Marine multilingual foundation from Commit 3 (Marine::Llm::TranslateResponseService).
# It never raises and degrades safely: blank/missing input yields a validation
# error, and an unconfigured Marine LLM falls back to the original text.
class Marine::Copilot::TranslateService < Marine::Copilot::BaseService
  def initialize(account:, content:, target_language:, source_language: nil, conversation: nil)
    super(account: account, conversation: conversation)
    @content = content.to_s
    @target_language = target_language.to_s
    @source_language = source_language
  end

  def perform
    return validation_error('blank_content') if @content.strip.blank?
    return validation_error('missing_target_language') if @target_language.strip.blank?

    result = Marine::Llm::TranslateResponseService.new(
      text: @content,
      target_language: @target_language,
      source_language: @source_language,
      account: account
    ).call

    return failure_result(result[:error]) unless result[:ok]

    build_result(result)
  end

  private

  def build_result(result)
    {
      message: result[:text],
      error: nil,
      follow_up_context: {
        event_name: 'translate',
        original_context: @content,
        last_response: result[:text],
        source_language: result[:source_language],
        target_language: result[:target_language],
        conversation_history: []
      }
    }
  end
end
