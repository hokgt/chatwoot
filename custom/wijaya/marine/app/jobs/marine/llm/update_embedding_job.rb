class Marine::Llm::UpdateEmbeddingJob < ApplicationJob
  queue_as :low

  # A Hash context carries only a non-secret SOP fingerprint. String context remains
  # supported for already-enqueued legacy jobs that serialized embedding text directly.
  def perform(response, context = nil)
    return unless current_context?(response, context)

    text = context.is_a?(Hash) ? response.embedding_text : context.presence || response.embedding_text
    embedding = Marine::Llm::EmbeddingService.new(account_id: response.account_id).get_embedding(text)
    response.update_column(:embedding, embedding) if embedding.present?
  end

  private

  def current_context?(response, context)
    return true unless context.is_a?(Hash)

    expected = context['expected_fingerprint'] || context[:expected_fingerprint]
    document = response.documentable
    document&.sop_document? && expected.present? && document.content_fingerprint == expected
  end
end
