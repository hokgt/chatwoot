class Marine::Charge::ConfidenceScorer
  TOKEN_PATTERN = /[[:alnum:]]{3,}/
  EXACT_MATCH_SCORE = 1.0
  CONTAINMENT_SCORE = 0.9
  SUBSET_MATCH_SCORE = 0.85

  def self.score(query:, response:, distance: nil)
    new(query: query, response: response, distance: distance).score
  end

  def initialize(query:, response:, distance: nil)
    @query = query.to_s.strip
    @response = response
    @distance = distance
  end

  # Deterministic 0.0..1.0 confidence based on exact text match, token overlap,
  # and optional vector distance (cosine/L2 similarity) when available.
  def score
    return 0.0 if @query.blank? || @response.nil?

    clamp([exact_match_score, blended_score].max)
  end

  private

  def exact_match_score
    normalized_query = normalize(@query)
    return 0.0 if normalized_query.blank?
    return EXACT_MATCH_SCORE if normalize(@response.question) == normalized_query
    return CONTAINMENT_SCORE if normalize(@response.question).include?(normalized_query) ||
                                normalize(@response.answer).include?(normalized_query)

    0.0
  end

  def blended_score
    overlap = subset_capped_overlap
    return overlap if @distance.nil?

    (overlap + vector_similarity) / 2.0
  end

  # Full token overlap (all query tokens present) only earns a perfect score when
  # the query is an exact match of the question. When the query's tokens are merely
  # a subset of a longer question (e.g. "Apa itu Textilindo?" vs an "Apa itu MOQ ...
  # Textilindo" FAQ), cap the score below containment so RAG synthesis runs instead
  # of returning the unrelated FAQ answer verbatim.
  def subset_capped_overlap
    overlap = token_overlap
    return overlap if overlap < 1.0 || normalize(@response.question) == normalize(@query)

    SUBSET_MATCH_SCORE
  end

  def token_overlap
    query_tokens = tokenize(@query)
    return 0.0 if query_tokens.empty?

    response_tokens = tokenize("#{@response.question} #{@response.answer}")
    return 0.0 if response_tokens.empty?

    (query_tokens & response_tokens).length.to_f / query_tokens.length
  end

  def vector_similarity
    clamp(1.0 - @distance.to_f)
  end

  def tokenize(text)
    text.to_s.downcase.scan(TOKEN_PATTERN).uniq
  end

  def normalize(text)
    text.to_s.downcase.strip.gsub(/\s+/, ' ')
  end

  def clamp(value)
    value.to_f.clamp(0.0, 1.0)
  end
end
