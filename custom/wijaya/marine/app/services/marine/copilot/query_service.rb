# Marine copilot natural-language query orchestrator.
#
# Given an assistant + acting user + a natural-language question, it runs the
# Marine copilot search tools (conversations + contacts) inside the user's RBAC
# scope, builds grounded context, and asks Marine::Llm::BaseService to synthesize
# an answer. It always degrades safely:
#   - LLM unconfigured or failing  -> returns a deterministic summary of the
#     records that were found (plus their citations), never raising.
#   - No records found and no LLM  -> returns a clear "nothing found" message.
#
# Fully Marine-owned: only Marine::Llm::BaseService and Marine copilot search
# services. No Captain runtime dependencies, premium gates, or hub checks.
#
# Returns: { content:, citations:, error: }
class Marine::Copilot::QueryService
  MAX_CONTEXT_RECORDS = 5

  def initialize(assistant:, user: nil, thread: nil)
    @assistant = assistant
    @account = assistant.account
    @user = user
    @thread = thread
  end

  def answer(question:)
    question = question.to_s.strip
    return validation_error if question.blank?

    conversations = search_conversations(question)
    contacts = search_contacts(question)
    citations = conversations + contacts

    synthesize(question, conversations, contacts, citations)
  rescue StandardError => e
    capture(e)
    { content: nil, citations: [], error: e.message }
  end

  private

  attr_reader :assistant, :account, :user, :thread

  def synthesize(question, conversations, contacts, citations)
    return fallback_result(citations) unless base_service.configured?

    result = base_service.chat(
      messages: history_messages + [{ role: 'user', content: question }],
      system: system_prompt(conversations, contacts)
    )
    return fallback_result(citations) unless result[:ok] && result[:message].to_s.strip.present?

    { content: result[:message].strip, citations: citations, error: nil }
  end

  def search_conversations(question)
    Marine::Copilot::SearchConversationsService.new(account: account, user: user).perform(query: question)
  end

  def search_contacts(question)
    Marine::Copilot::SearchContactsService.new(account: account, user: user).perform(query: question)
  end

  def system_prompt(conversations, contacts)
    <<~PROMPT.strip
      You are #{product_name}, a helpful support copilot for account ##{account.id}.
      Answer the user's question using ONLY the context below. Cite conversations by
      their number (e.g. Conversation #12) and contacts by name. If the context does
      not contain the answer, say so plainly.
      #{assistant_instructions}

      Conversations found (#{conversations.length}):
      #{conversations.map { |row| "- #{row[:title]}: #{row[:summary]}" }.join("\n").presence || 'None'}

      Contacts found (#{contacts.length}):
      #{contacts.map { |row| "- #{row[:name]}: #{row[:summary]}" }.join("\n").presence || 'None'}
    PROMPT
  end

  # Deterministic answer when the Marine LLM is unconfigured or fails. Surfaces
  # the records that were found so the user still gets useful, cited results.
  def fallback_result(citations)
    if citations.empty?
      return { content: 'No matching conversations or contacts were found for your query.', citations: [], error: nil }
    end

    lines = citations.first(MAX_CONTEXT_RECORDS).map do |citation|
      citation[:type] == 'conversation' ? "- #{citation[:title]}" : "- Contact: #{citation[:name]}"
    end
    content = "Marine AI synthesis is not configured. Here are the matching records:\n#{lines.join("\n")}"
    { content: content, citations: citations, error: nil }
  end

  def history_messages
    return [] if thread.blank?

    thread.previous_history.last(10)
  end

  def base_service
    @base_service ||= Marine::Llm::BaseService.new(account: account)
  end

  def product_name
    assistant.config.to_h['product_name'].to_s.strip.presence || 'Marine AI'
  end

  def assistant_instructions
    assistant.config.to_h['instructions'].to_s.strip
  end

  def validation_error
    { content: nil, citations: [], error: 'Question is required' }
  end

  def capture(exception)
    ChatwootExceptionTracker.new(exception, account: account).capture_exception
  end
end
