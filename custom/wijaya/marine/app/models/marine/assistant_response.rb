class Marine::AssistantResponse < ApplicationRecord
  self.table_name = 'marine_assistant_responses'

  belongs_to :assistant, class_name: 'Marine::Assistant'
  belongs_to :account
  belongs_to :documentable, polymorphic: true, optional: true
  has_neighbors :embedding, normalize: true

  attr_accessor :skip_embedding_enqueue

  validates :question, :answer, presence: true

  before_validation :ensure_account
  before_validation :ensure_status
  before_validation :mark_as_edited, on: :update
  after_commit :update_response_embedding

  enum status: { pending: 0, approved: 1 }

  scope :ordered, -> { order(created_at: :desc) }
  scope :by_account, ->(account_id) { where(account_id: account_id) }
  scope :by_assistant, ->(assistant_id) { where(assistant_id: assistant_id) }

  def self.search(query, account_id: nil)
    sanitized = ActiveRecord::Base.sanitize_sql_like(query.to_s)
    scope = approved
    scope = scope.where(account_id: account_id) if account_id.present?
    textual = scope.where('question ILIKE :query OR answer ILIKE :query', query: "%#{sanitized}%")
    return textual.limit(5) if textual.exists?

    return scope.none if query.blank?
    embedding = Marine::Llm::EmbeddingService.new(account_id: account_id).get_embedding(query)
    return scope.none if embedding.blank?

    scope.nearest_neighbors(:embedding, embedding, distance: 'cosine').limit(5)
  end

  def embedding_text
    "#{question}: #{answer}"
  end

  private

  def ensure_account
    self.account = assistant&.account
  end

  def ensure_status
    self.status ||= :approved
  end

  def mark_as_edited
    self.edited = true if question_changed? || answer_changed?
  end

  def update_response_embedding
    return if destroyed? || skip_embedding_enqueue
    return unless saved_change_to_question? || saved_change_to_answer? || embedding.nil?

    Marine::Llm::UpdateEmbeddingJob.perform_later(self)
  end
end
