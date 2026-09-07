module Wijaya::Marine::AccountExtensions
  extend ActiveSupport::Concern

  included do
    store_accessor :settings, :marine_models, :marine_features
    # Synchronous dependent: :destroy (not destroy_async) so children are removed
    # in the same transaction before the account row, satisfying the restrictive
    # Marine foreign keys and preserving ActiveStorage / callback cleanup.
    has_many :marine_assistants, dependent: :destroy, class_name: 'Marine::Assistant'
    has_many :marine_assistant_responses, dependent: :destroy, class_name: 'Marine::AssistantResponse'
    has_many :marine_documents, dependent: :destroy, class_name: 'Marine::Document'
    has_many :marine_custom_tools, dependent: :destroy, class_name: 'Marine::CustomTool'
    has_many :marine_copilot_threads, dependent: :destroy, class_name: 'Marine::CopilotThread'
    has_many :marine_copilot_messages, dependent: :destroy, class_name: 'Marine::CopilotMessage'
  end

  def marine_usage_limits
    max_limit = ChatwootApp.max_limit.to_i
    {
      documents: { total_count: max_limit, current_available: max_limit, consumed: marine_documents.count },
      responses: { total_count: max_limit, current_available: max_limit, consumed: custom_attributes['marine_responses_usage'].to_i }
    }
  end

  def increment_marine_response_usage
    # `increment_custom_attribute` is an Enterprise-only Account method (plan usage/limits).
    # Prefer it when present so Enterprise behaviour is unchanged; in the CE/FOSS build it is
    # absent, but `custom_attributes` is a core column. Mirror the Enterprise atomic jsonb_set
    # UPDATE (not a read-modify-write of the whole column) so concurrent increments are not
    # lost and a concurrent write to a different custom_attributes key is never clobbered.
    return increment_custom_attribute('marine_responses_usage') if respond_to?(:increment_custom_attribute)

    key = 'marine_responses_usage'
    self.class.where(id: id).update_all([ # rubocop:disable Rails/SkipsModelValidations
                                          "custom_attributes = jsonb_set(COALESCE(custom_attributes, '{}'), ARRAY[:key], " \
                                          '(COALESCE((custom_attributes ->> :key)::int, 0) + 1)::text::jsonb)',
                                          { key: key }
                                        ])
    custom_attributes[key] = custom_attributes[key].to_i + 1
  end

  def marine_preferences
    features = {
      'assistant' => true,
      'knowledge_base' => true,
      'handoff' => true
    }.merge(marine_features || {})
    models = marine_models || {}
    {
      enabled: true,
      hub: 'local',
      remote_hub: false,
      account_id: id,
      default_model: models['default'].presence || 'local-knowledge-base',
      assistants_count: marine_assistants.count,
      models: models,
      features: features,
      llm: marine_llm_metadata
    }.with_indifferent_access
  end

  # Non-secret readiness metadata for the Marine LLM foundation. Never exposes
  # the API key — only whether one is configured plus the resolved model names.
  def marine_llm_metadata
    {
      configured: ::Marine::Llm::Config.configured?,
      default_model: ::Marine::Llm::Config.model,
      embedding_model: ::Marine::Llm::Config.embedding_model
    }
  end
end
