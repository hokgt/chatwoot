# Summarizes the current conversation for the existing composer AI summarize action.
# This prevents Marine-linked conversations from falling back to Captain tasks while
# preserving the same { message:, follow_up_context: } response shape.
class Marine::Copilot::SummaryService < Marine::Copilot::BaseService
  def perform
    return validation_error('conversation_not_found') if conversation.blank?

    transcript = context_builder.transcript
    return validation_error('empty_conversation') if transcript.blank?

    run_completion(system: system_prompt, prompt: transcript, event_name: 'summarize')
  end

  private

  def context_builder
    @context_builder ||= Marine::Copilot::ConversationContextBuilder.new(conversation)
  end

  def system_prompt
    <<~PROMPT.strip
      Summarize this customer support conversation for an agent.
      Include the customer's issue, important context, current status, and any promised next steps.
      Be concise and factual. Do not invent facts.
      Reply in #{account_locale_name}.
      Return only the summary text, with no labels, prefixes, or quotation marks.
    PROMPT
  end

  def account_locale_name
    account.respond_to?(:locale_english_name) ? account.locale_english_name : 'the account locale'
  end
end
