class Marine::Cell::RetrievalResult
  attr_reader :answer, :confidence, :citations, :source_type, :response_ids,
              :document_ids, :fallback_reason, :matched_response_id, :responses

  def self.empty(fallback_reason:)
    new(responses: [], confidence: 0.0, citations: [], fallback_reason: fallback_reason)
  end

  def initialize(responses:, confidence:, citations: nil, fallback_reason: nil)
    @responses = Array(responses)
    @confidence = confidence.to_f.clamp(0.0, 1.0)
    @fallback_reason = fallback_reason
    @citations = citations || Marine::Cell::CitationBuilder.build(@responses)
    top = @responses.first
    @answer = top&.answer
    @matched_response_id = top&.id
    @source_type = top ? Marine::Cell::CitationBuilder.source_type_for(top) : nil
    @response_ids = @responses.map(&:id)
    @document_ids = @citations.filter_map { |citation| citation[:document_id] }.uniq
  end

  def present?
    @responses.any?
  end

  def confident?(threshold)
    present? && @confidence >= threshold.to_f
  end

  # Compact, JSON-safe metadata for persisting on outgoing messages.
  def to_metadata
    {
      confidence: @confidence,
      citations: @citations,
      source_type: @source_type,
      response_ids: @response_ids,
      document_ids: @document_ids,
      fallback_reason: @fallback_reason
    }
  end

  def to_h
    to_metadata.merge(answer: @answer, matched_response_id: @matched_response_id)
  end
end
