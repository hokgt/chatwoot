# Shared plumbing for Marine composer Copilot tasks (reply suggestion, rewrite,
# translate, follow-up). It mirrors the shape of Chatwoot's Captain task services
# but stays fully Marine-owned: it uses only Marine::Llm::BaseService (Marine
# credentials/config from Commit 1) and never touches external premium gates,
# hub services, pricing plans, or feature flags.
#
# Every subclass entry point returns a JSON-safe hash and never raises when the
# Marine LLM is unconfigured:
#
#   { message:, error:, follow_up_context? }
class Marine::Copilot::BaseService
  def initialize(account:, conversation: nil, user: nil)
    @account = account
    @conversation = conversation
    @user = user
  end

  private

  attr_reader :account, :conversation, :user

  def base_service
    @base_service ||= Marine::Llm::BaseService.new(account: account)
  end

  def run_completion(system:, prompt:, event_name:, temperature: nil)
    return not_configured_result unless base_service.configured?

    result = base_service.complete(prompt: prompt, system: system, temperature: temperature)
    return failure_result(result[:error]) unless result[:ok] && result[:message].to_s.strip.present?

    success_result(result[:message].strip, event_name, prompt)
  end

  def success_result(message, event_name, original_context)
    {
      message: message,
      error: nil,
      follow_up_context: build_follow_up_context(event_name, original_context, message)
    }
  end

  def build_follow_up_context(event_name, original_context, message)
    {
      event_name: event_name,
      original_context: original_context,
      last_response: message,
      conversation_history: []
    }
  end

  def failure_result(error)
    { message: nil, error: error.to_s.presence || 'marine_task_failed' }
  end

  def not_configured_result
    { message: nil, error: 'Marine LLM is not configured' }
  end

  def validation_error(message)
    { message: nil, error: message }
  end

  def marine_assistant
    conversation&.inbox&.marine_assistant
  end

  def assistant_instructions
    instructions = marine_assistant&.config.to_h['instructions'] if marine_assistant.respond_to?(:config)
    instructions.to_s.strip.presence
  end

  def product_name
    name = marine_assistant&.config.to_h['product_name'] if marine_assistant.respond_to?(:config)
    name.to_s.strip.presence
  end
end
