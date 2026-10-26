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

  # Batch-safe approved, assistant-scoped CANDIDATE load (Phase 3 product-description binding): the
  # approved responses whose question OR answer contains one of `keys`, in one bounded query. Candidate
  # retrieval only — the caller re-verifies exact identity before binding.
  def approved_mentioning(keys)
    retriever.approved_mentioning(keys)
  end

  private

  attr_reader :assistant

  def retriever
    @retriever ||= Marine::Cell::Retriever.new(assistant: assistant)
  end
end
