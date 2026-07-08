require 'ruby_llm'

class Marine::Llm::EmbeddingService
  def initialize(account_id: nil)
    @account_id = account_id
  end

  # Returns an embedding vector when a Marine LLM provider is configured, otherwise
  # nil. Text search stays fully functional without embeddings, so any failure or
  # missing configuration degrades to the historical nil/no-remote-call behavior.
  def get_embedding(text)
    return nil if text.blank?
    return nil unless Marine::Llm::Config.configured?

    context.embed(text, model: Marine::Llm::Config.embedding_model).vectors
  rescue StandardError => e
    capture(e)
    nil
  end

  private

  def context
    @context ||= RubyLLM.context do |config|
      config.openai_api_key = Marine::Llm::Config.api_key
      config.openai_api_base = Marine::Llm::Config.api_base
      config.request_timeout = Marine::Llm::BaseService::REQUEST_TIMEOUT
      config.max_retries = Marine::Llm::BaseService::MAX_RETRIES
    end
  end

  def capture(exception)
    account = Account.find_by(id: @account_id) if @account_id
    ChatwootExceptionTracker.new(exception, account: account).capture_exception
  end
end
