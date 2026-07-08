class Marine::Llm::EmbeddingService
  def initialize(account_id: nil)
    @account_id = account_id
  end

  def get_embedding(_text)
    # Marine intentionally avoids any remote call unless a future Marine-specific
    # provider is configured. Text search remains available without embeddings.
    nil
  end
end
