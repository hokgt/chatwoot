# Drafts a suggested agent reply from the current conversation context using the
# Marine LLM. Marine-owned reply suggestion service; it
# relies solely on Marine::Llm::BaseService and, when the inbox is linked to a
# Marine assistant, folds that assistant's product/instructions into the prompt.
class Marine::Copilot::ReplySuggestionService < Marine::Copilot::BaseService
  def perform
    return validation_error('conversation_not_found') if conversation.blank?

    transcript = context_builder.transcript
    return validation_error('empty_conversation') if transcript.blank?

    run_completion(system: system_prompt, prompt: transcript, event_name: 'reply_suggestion')
  end

  private

  def context_builder
    @context_builder ||= Marine::Copilot::ConversationContextBuilder.new(conversation)
  end

  def system_prompt
    <<~PROMPT.strip
      You are #{agent_identity}, a customer support agent#{product_clause}.
      Draft a helpful, accurate and concise reply to the customer's most recent message,
      using the conversation transcript provided by the user message.
      #{instruction_clause}
      Reply in the customer's language. Do not invent facts you were not given.
      Return only the reply text, with no labels, prefixes, or quotation marks.
    PROMPT
  end

  def agent_identity
    user&.name.to_s.strip.presence || 'a support agent'
  end

  def product_clause
    product_name ? " for #{product_name}" : ''
  end

  def instruction_clause
    assistant_instructions ? "Follow these assistant guidelines: #{assistant_instructions}" : ''
  end
end
