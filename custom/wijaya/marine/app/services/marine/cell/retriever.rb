class Marine::Cell::Retriever
  MIN_SCORE = 0.18
  TOKEN_PATTERN = /[[:alnum:]]{3,}/
  DEFAULT_CONFIDENCE_THRESHOLD = 0.15
  NO_MATCH_REASON = 'no_confident_cell_match'.freeze
  LOW_CONFIDENCE_REASON = 'low_confidence_cell_match'.freeze

  def initialize(assistant:, threshold: nil)
    @assistant = assistant
    @threshold = threshold
  end

  # Returns a Marine::Cell::RetrievalResult with confidence, citations, and
  # fallback metadata. Only records actually retrieved are cited/scored.
  def retrieve(query, limit: 5)
    records = responses(query, limit: limit).to_a
    return Marine::Cell::RetrievalResult.empty(fallback_reason: NO_MATCH_REASON) if records.empty?

    citations = Marine::Cell::CitationBuilder.build(records)
    confidence = confidence_for(query, records.first)
    confident = confidence >= threshold
    Marine::Cell::RetrievalResult.new(
      responses: records,
      confidence: confidence,
      citations: citations,
      fallback_reason: confident ? nil : LOW_CONFIDENCE_REASON
    )
  end

  # Record search preserved from the legacy KnowledgeBaseService behavior.
  # Returns an ActiveRecord relation / array of Marine::AssistantResponse.
  def responses(query, limit: 5)
    normalized_query = query.to_s.strip
    return Marine::AssistantResponse.none if normalized_query.blank?

    text_matches = textual_matches(normalized_query, limit: limit)
    return text_matches if text_matches.any?

    ranked_keyword_matches(normalized_query, limit: limit)
  end

  def best_match(query)
    responses(query, limit: 1).first
  end

  private

  attr_reader :assistant

  def confidence_for(query, response)
    distance = response.respond_to?(:neighbor_distance) ? response.neighbor_distance : nil
    Marine::Charge::ConfidenceScorer.score(query: query, response: response, distance: distance)
  end

  def threshold
    @threshold ||= (assistant&.config&.[]('confidence_threshold').presence || DEFAULT_CONFIDENCE_THRESHOLD).to_f
  end

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

    Marine::AssistantResponse.where(id: ids).includes(:documentable)
                             .order(Arel.sql("array_position(ARRAY[#{ids.join(',')}]::bigint[], id)"))
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
