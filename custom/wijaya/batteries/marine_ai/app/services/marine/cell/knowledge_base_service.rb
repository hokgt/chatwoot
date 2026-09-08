class Marine::Cell::KnowledgeBaseService
  def initialize(assistant:)
    @assistant = assistant
  end

  # Kept as an ActiveRecord relation / array of response records for callers
  # that rely on the legacy return type.
  def search(query, limit: 5)
    retriever.responses(query, limit: limit)
  end

  def best_match(query)
    retriever.best_match(query)
  end

  # Rich retrieval result with confidence, citations, and fallback metadata.
  def retrieve(query, limit: 5)
    retriever.retrieve(query, limit: limit)
  end

  private

  attr_reader :assistant

  def retriever
    @retriever ||= Marine::Cell::Retriever.new(assistant: assistant)
  end
end
