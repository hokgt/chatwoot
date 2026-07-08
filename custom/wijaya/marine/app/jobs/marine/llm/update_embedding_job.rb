class Marine::Llm::UpdateEmbeddingJob < ApplicationJob
  queue_as :low

  def perform(response, text)
    embedding = Marine::Llm::EmbeddingService.new(account_id: response.account_id).get_embedding(text)
    response.update_column(:embedding, embedding) if embedding.present?
  end
end
