class Marine::Document < ApplicationRecord
  self.table_name = 'marine_documents'

  belongs_to :assistant, class_name: 'Marine::Assistant'
  belongs_to :account
  has_many :responses, class_name: 'Marine::AssistantResponse', dependent: :destroy, as: :documentable

  store_accessor :metadata, :content_fingerprint, :last_sync_error_code, :sync_step

  validates :external_link, presence: true, uniqueness: { scope: :assistant_id }
  validates :content, length: { maximum: 200_000 }

  before_validation :ensure_account_id
  before_validation :normalize_external_link
  after_commit :enqueue_response_builder_job

  enum status: { in_progress: 0, available: 1 }
  enum :sync_status, { syncing: 0, synced: 1, failed: 2 }, prefix: :sync

  scope :ordered, -> { order(created_at: :desc) }
  scope :for_account, ->(account_id) { where(account_id: account_id) }
  scope :for_assistant, ->(assistant_id) { where(assistant_id: assistant_id) }

  def syncable? = true
  def display_url = external_link
  def to_llm_metadata = { document_id: id, assistant_id: assistant_id, external_link: external_link }

  private

  # Marine Cell: when source content changes, rebuild local knowledge entries.
  def enqueue_response_builder_job
    return if destroyed?
    return unless content.present?
    return unless previous_changes.key?('id') || previous_changes.key?('content')

    Marine::Documents::ResponseBuilderJob.perform_later(self)
  end

  def ensure_account_id
    self.account_id = assistant&.account_id
  end

  def normalize_external_link
    self.external_link = external_link.delete_suffix('/') if external_link.present?
  end
end
