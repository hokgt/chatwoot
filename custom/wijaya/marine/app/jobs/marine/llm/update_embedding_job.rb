class Marine::Llm::UpdateEmbeddingJob < ApplicationJob
  queue_as :low

  # The optional second argument keeps already-enqueued legacy jobs compatible. New jobs
  # pass only the response GlobalID so SOP body text never appears in ActiveJob/Sidekiq logs.
  def perform(response, legacy_text = nil)
    text = legacy_text.presence || response.embedding_text
    embedding = Marine::Llm::EmbeddingService.new(account_id: response.account_id).get_embedding(text)
    response.update_column(:embedding, embedding) if embedding.present?
  end
end
