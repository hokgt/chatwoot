class Marine::Document < ApplicationRecord
  self.table_name = 'marine_documents'

  MAX_SOURCE_FILE_BYTES = 2_097_152 # 2 MiB
  ALLOWED_SOURCE_FILE_TYPES = %w[application/pdf image/jpeg image/png].freeze

  belongs_to :assistant, class_name: 'Marine::Assistant'
  belongs_to :account
  has_many :responses, class_name: 'Marine::AssistantResponse', dependent: :destroy, as: :documentable
  has_one_attached :source_file

  store_accessor :metadata, :content_fingerprint, :last_sync_error_code, :sync_step,
                 :original_filename, :detected_content_type, :original_byte_size,
                 :processing_method, :page_count

  enum status: { in_progress: 0, available: 1 }
  enum :sync_status, { syncing: 0, synced: 1, failed: 2 }, prefix: :sync
  enum :source_kind, { website: 'website', product_catalog: 'product_catalog', sop_document: 'sop_document' }

  # Website sources are URL-backed.
  validates :external_link, presence: true, uniqueness: { scope: :assistant_id }, if: :website?
  validates :external_link, absence: true, unless: :website?
  validates :content, length: { maximum: 200_000 }
  validates :content, absence: true, if: :product_catalog?

  # Product catalog / SOP sources are file-backed and never carry a family/website URL mismatch.
  validates :product_family_code, presence: true, if: :product_catalog?
  validates :product_family_code, absence: true, unless: :product_catalog?
  validates :product_family_code,
            uniqueness: { scope: :assistant_id, conditions: -> { where(source_kind: 'product_catalog', primary_catalog: true) } },
            if: -> { product_catalog? && primary_catalog? }

  validate :validate_primary_catalog_flag
  validate :validate_source_file_presence
  validate :validate_source_file_blob

  before_validation :ensure_account_id
  before_validation :normalize_external_link, if: :website?
  after_commit :enqueue_response_builder_job

  scope :ordered, -> { order(created_at: :desc) }
  scope :for_account, ->(account_id) { where(account_id: account_id) }
  scope :for_assistant, ->(assistant_id) { where(assistant_id: assistant_id) }

  def syncable? = !product_catalog?
  def display_url = external_link
  def to_llm_metadata = { document_id: id, assistant_id: assistant_id, external_link: external_link }

  private

  def requires_source_file? = product_catalog? || sop_document?

  # Marine Cell: when source content changes, rebuild local knowledge entries.
  # Product catalogs are handled by a dedicated pipeline (Commit 1B) and never
  # enqueue the URL/content response builder. SOP documents are extracted by the
  # dedicated Commit 1C Marine::Documents::ProcessJob and must NOT create any
  # AssistantResponse (that indexing pipeline is Commit 1D).
  def enqueue_response_builder_job
    return if destroyed?
    return if product_catalog?
    return if sop_document?
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

  def validate_primary_catalog_flag
    if product_catalog?
      errors.add(:primary_catalog, 'must be true for product catalogs') unless primary_catalog?
    elsif primary_catalog?
      errors.add(:primary_catalog, 'is not allowed for this source kind')
    end
  end

  def validate_source_file_presence
    if requires_source_file?
      errors.add(:source_file, 'must be attached') unless source_file.attached?
    elsif source_file.attached?
      errors.add(:source_file, 'is not allowed for website sources')
    end
  end

  def validate_source_file_blob
    return unless source_file.attached?

    blob = source_file.blob
    errors.add(:source_file, 'must not be empty') if blob.byte_size.zero?
    errors.add(:source_file, 'must be at most 2 MiB') if blob.byte_size > MAX_SOURCE_FILE_BYTES
    errors.add(:source_file, 'has an unsupported content type') unless ALLOWED_SOURCE_FILE_TYPES.include?(blob.content_type)
  end
end
