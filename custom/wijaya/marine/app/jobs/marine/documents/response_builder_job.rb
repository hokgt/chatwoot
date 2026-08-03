class Marine::Documents::ResponseBuilderJob < ApplicationJob
  queue_as :low

  TITLE_MAX_GRAPHEMES = 255

  # expected_fingerprint is optional for jobs serialized before Commit 1D and for the
  # unchanged website path. SOP jobs enqueued by ProcessJob always carry the exact
  # extracted-content fingerprint so a stale job cannot replace newer chunks.
  def perform(document, expected_fingerprint = nil)
    return if document.product_catalog?
    return index_sop_document(document, expected_fingerprint) if document.sop_document?

    build_website_response(document)
  end

  private

  # Existing website behavior remains unchanged: fetch URL content when needed and keep
  # one deterministic document-backed knowledge entry.
  def build_website_response(document)
    Marine::Documents::SyncService.new(document).call if document.content.blank? && document.external_link.present?
    return if document.content.blank?

    question = document.name.presence || document.external_link
    answer = document.content.to_s.truncate(4000)
    response = document.responses.find_or_initialize_by(question: question)
    response.assign_attributes(answer: answer, assistant: document.assistant, account: document.account, status: :approved)
    response.save!
    document.update!(status: :available) unless document.available?
  end

  # Commit 1D SOP indexing. Replacement is scoped to this document and atomic; create
  # failure rolls the delete back. Each committed create uses the existing embedding callback.
  def index_sop_document(document, expected_fingerprint)
    Marine::Document.transaction do
      locked = Marine::Document.lock.find_by(id: document.id)
      next unless indexable?(locked, expected_fingerprint)

      rows = desired_rows(locked, Marine::Documents::Sop::Chunker.new(locked.content).call)
      next if rows.empty?

      reconcile_rows!(locked, rows)
      mark_indexed!(locked, rows.length)
    end
  rescue ActiveRecord::RecordNotFound
    nil
  rescue StandardError => e
    Rails.logger.error({ tag: 'marine.sop.index_error', error_class: e.class.name }.to_json)
    mark_index_failed(document, expected_fingerprint)
    nil
  end

  def reconcile_rows!(document, rows)
    return if current_rows(document) == rows

    document.responses.delete_all
    rows.each do |question, answer|
      document.responses.create!(question: question, answer: answer, assistant: document.assistant,
                                 account: document.account, status: :approved)
    end
  end

  def indexable?(document, expected_fingerprint)
    return false unless document&.sop_document?
    return false unless document.sync_synced? && document.available? && document.content.present?
    return true if expected_fingerprint.blank?

    document.content_fingerprint == expected_fingerprint
  end

  def desired_rows(document, chunks)
    total = chunks.length
    chunks.each_with_index.map { |chunk, index| [chunk_title(document, index + 1, total), chunk] }
  end

  # Equality makes an unchanged retry a true no-op even if indexing metadata was lost.
  def current_rows(document)
    document.responses.order(:id).pluck(:question, :answer)
  end

  def mark_indexed!(document, count)
    document.update!(indexing_status: 'indexed', indexed_fingerprint: document.content_fingerprint,
                     indexed_chunk_count: count, indexed_at: Time.current, indexing_error_code: nil)
  end

  # Persist only a stable code, guarded by the same fingerprint; prior good chunks remain.
  def mark_index_failed(document, expected_fingerprint)
    Marine::Document.transaction do
      locked = Marine::Document.lock.find_by(id: document.id)
      next unless indexable?(locked, expected_fingerprint)

      locked.update!(indexing_status: 'failed', indexing_error_code: 'sop_index_failed')
    end
  rescue StandardError => e
    Rails.logger.error({ tag: 'marine.sop.index_failed_persist', error_class: e.class.name }.to_json)
  end

  # Exposes only sanitized source name and ordered part, never body content.
  def chunk_title(document, part, total)
    suffix = " (Part #{part} of #{total})"
    base = document.name.to_s.gsub(/[[:cntrl:]]/, ' ').squish.presence || "SOP ##{document.id}"
    room = [TITLE_MAX_GRAPHEMES - suffix.scan(/\X/).length, 1].max
    "#{base.scan(/\X/).first(room).join}#{suffix}"
  end
end
