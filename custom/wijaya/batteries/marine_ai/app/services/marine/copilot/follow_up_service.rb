# Refines a previously generated Marine composer result based on a free-form
# follow-up instruction from the agent. Marine-owned follow-up service: it consumes the follow_up_context returned by the
# other Marine Copilot tasks and returns an updated context so the composer can
# keep iterating. Never raises; degrades safely when the Marine LLM is
# unconfigured.
class Marine::Copilot::FollowUpService < Marine::Copilot::BaseService
  def initialize(account:, follow_up_context:, user_message:, conversation: nil)
    super(account: account, conversation: conversation)
    @follow_up_context = (follow_up_context || {}).to_h.with_indifferent_access
    @user_message = user_message.to_s
  end

  def perform
    return validation_error('missing_follow_up_context') if @follow_up_context.blank?
    return validation_error('blank_message') if @user_message.strip.blank?
    return not_configured_result unless base_service.configured?

    result = base_service.complete(prompt: @user_message, system: system_prompt)
    return failure_result(result[:error]) unless result[:ok] && result[:message].to_s.strip.present?

    build_result(result[:message].strip)
  end

  private

  def build_result(message)
    {
      message: message,
      error: nil,
      follow_up_context: @follow_up_context.merge(last_response: message).to_h
    }
  end

  def system_prompt
    <<~PROMPT.strip
      You are refining a customer-support agent's message based on the agent's follow-up request.
      Original task: #{@follow_up_context[:event_name].presence || 'rewrite'}.
      Previous version of the message:
      #{@follow_up_context[:last_response]}
      Apply the agent's follow-up request (provided as the user message) to that previous version.
      Keep the same language, and preserve names, numbers, URLs and formatting.
      Return only the updated message, with no labels, prefixes, or quotation marks.
    PROMPT
  end
end
