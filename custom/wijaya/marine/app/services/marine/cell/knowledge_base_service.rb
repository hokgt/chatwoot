class Marine::Cell::KnowledgeBaseService
  MIN_SCORE = 0.18
  TOKEN_PATTERN = /[[:alnum:]]{3,}/

  def initialize(assistant:)
    @assistant = assistant
  end

  def search(query, limit: 5)
    normalized_query = query.to_s.strip
    return Marine::AssistantResponse.none if normalized_query.blank?

    text_matches = textual_matches(normalized_query, limit: limit)
    return text_matches if text_matches.any?

    ranked_keyword_matches(normalized_query, limit: limit)
  end

  def best_match(query)
    search(query, limit: 1).first
  end

  private

  attr_reader :assistant

  def base_scope
    assistant.responses.approved.includes(:documentable)
  end

  def textual_matches(query, limit:)
    sanitized = ActiveRecord::Base.sanitize_sql_like(query)
    base_scope.where('question ILIKE :query OR answer ILIKE :query', query: "%#{sanitized}%").limit(limit)
  end

  def ranked_keyword_matches(query, limit:)
    tokens = tokenize(query)
    return base_scope.none if tokens.empty?

    candidates = base_scope.limit(200).to_a
    ranked = candidates.map { |response| [response, score(response, tokens)] }
                       .select { |_response, value| value >= MIN_SCORE }
                       .sort_by { |_response, value| -value }
                       .first(limit)
                       .map(&:first)
    ids = ranked.map(&:id)
    return base_scope.none if ids.empty?

    Marine::AssistantResponse.where(id: ids).order(Arel.sql("array_position(ARRAY[#{ids.join(',')}]::bigint[], id)"))
  end

  def score(response, query_tokens)
    response_tokens = tokenize([response.question, response.answer].join(' '))
    return 0.0 if response_tokens.empty?

    overlap = query_tokens & response_tokens
    overlap.length.to_f / query_tokens.length
  end

  def tokenize(text)
    text.to_s.downcase.scan(TOKEN_PATTERN).uniq
  end
end
