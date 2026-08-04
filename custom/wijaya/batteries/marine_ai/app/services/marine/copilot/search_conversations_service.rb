# Marine copilot conversation search. Runs a deterministic keyword/attribute
# search over the conversations the current user is permitted to see and returns
# JSON-safe result rows (citation metadata + short LLM text) for answer
# synthesis. Never leaks cross-account or cross-user conversations.
class Marine::Copilot::SearchConversationsService < Marine::Copilot::SearchBaseService
  def perform(query: nil, status: nil, priority: nil, limit: MAX_RESULTS)
    conversations = filtered_conversations(query, status, priority).limit(limit)

    conversations.map do |conversation|
      conversation_citation(conversation).merge(
        summary: safe_llm_text(conversation)
      )
    end
  end

  private

  def filtered_conversations(query, status, priority)
    conversations = permissible_conversations
    conversations = conversations.where(status: status) if valid_status?(status)
    conversations = conversations.where(priority: priority) if valid_priority?(priority)
    conversations = keyword_filter(conversations, query) if query.present?
    conversations.order(last_activity_at: :desc)
  end

  # Matches the free-text query against conversation display id or the text of
  # its messages, staying inside the already permission-filtered scope.
  def keyword_filter(conversations, query)
    term = query.to_s.strip
    matched_ids = account.messages
                         .where(conversation_id: conversations.select(:id))
                         .where('messages.content ILIKE ?', "%#{term}%")
                         .reorder(nil)
                         .distinct
                         .limit(200)
                         .pluck(:conversation_id)

    matched_ids |= conversations.where(display_id: term.to_i).pluck(:id) if term.match?(/\A\d+\z/)

    conversations.where(id: matched_ids)
  end

  def valid_status?(status)
    status.present? && Conversation.statuses.key?(status.to_s)
  end

  def valid_priority?(priority)
    priority.present? && Conversation.priorities.key?(priority.to_s)
  end

  def safe_llm_text(conversation)
    conversation.to_llm_text(include_contact_details: true).to_s.truncate(1500)
  rescue StandardError
    "Conversation ##{conversation.display_id}"
  end
end
