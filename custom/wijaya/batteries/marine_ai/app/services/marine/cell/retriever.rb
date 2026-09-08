class Marine::Cell::Retriever
  MIN_SCORE = 0.18
  TOKEN_PATTERN = /[[:alnum:]]{3,}/
  DEFAULT_CONFIDENCE_THRESHOLD = 0.15
  NO_MATCH_REASON = 'no_confident_cell_match'.freeze
  LOW_CONFIDENCE_REASON = 'low_confidence_cell_match'.freeze
  # Candidate pool for in-memory keyword ranking. Kept generous so document-backed
  # responses (whose question is only the document name) aren't dropped before scoring.
  CANDIDATE_LIMIT = 500
  # Answer text carries the substance for document-backed responses, so answer-field
  # overlap is weighted above question-field overlap, with a small boost for documents.
  QUESTION_WEIGHT = 1.0
  ANSWER_WEIGHT = 2.0
  DOCUMENT_BOOST = 0.1

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

  def ranked_keyword_matches(query, limit:) # rubocop:disable Metrics/CyclomaticComplexity
    tokens = tokenize(query)
    return base_scope.none if tokens.empty?

    candidates = keyword_candidates(tokens)
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

  # Narrows the candidate pool to responses whose question OR answer contains any
  # significant query token, so document answer content is matched in SQL rather than
  # relying on the default scope order. Falls back to the full pool if nothing matches.
  def keyword_candidates(tokens)
    clauses = tokens.map.with_index { |_token, i| "question ILIKE :t#{i} OR answer ILIKE :t#{i}" }.join(' OR ')
    params = tokens.each_with_index.with_object({}) do |(token, i), hash|
      hash[:"t#{i}"] = "%#{ActiveRecord::Base.sanitize_sql_like(token)}%"
    end
    matched = base_scope.where(clauses, params).limit(CANDIDATE_LIMIT).to_a
    return matched if matched.any?

    base_scope.limit(CANDIDATE_LIMIT).to_a
  end

  def score(response, query_tokens)
    question_tokens = tokenize(response.question)
    answer_tokens = tokenize(response.answer)
    return 0.0 if question_tokens.empty? && answer_tokens.empty?

    question_overlap = (query_tokens & question_tokens).length
    answer_overlap = (query_tokens & answer_tokens).length
    weighted = (question_overlap * QUESTION_WEIGHT) + (answer_overlap * ANSWER_WEIGHT)
    base = weighted.to_f / (query_tokens.length * ANSWER_WEIGHT)
    base += DOCUMENT_BOOST if document_backed?(response)
    base
  end

  def document_backed?(response)
    response.respond_to?(:documentable_type) && response.documentable_type.to_s == 'Marine::Document'
  end

  def tokenize(text)
    text.to_s.downcase.scan(TOKEN_PATTERN).uniq
  end
end
