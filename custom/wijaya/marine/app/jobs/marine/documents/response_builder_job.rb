class Marine::Documents::ResponseBuilderJob < ApplicationJob
  queue_as :low

  TITLE_MAX_CODEPOINTS = 255

  class EmbeddingEnqueueError < StandardError; end

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

  # Chunk replacement commits atomically with embedding callbacks suppressed. Embedding
  # jobs are then explicitly enqueued outside the transaction. A partial enqueue failure
  # leaves the document failed; retry re-enqueues the complete current set without
  # recreating rows, so chunks cannot become permanently unembedded.
  def index_sop_document(document, expected_fingerprint)
    plan = prepare_indexing(document, expected_fingerprint)
    return if plan.nil? || plan == :noop

    enqueue_embeddings!(plan)
    mark_indexed_after_enqueue!(plan)
  rescue ActiveRecord::RecordNotFound
    nil
  rescue StandardError => e
    Rails.logger.error({ tag: 'marine.sop.index_error', error_class: e.class.name }.to_json)
    mark_index_failed(document, expected_fingerprint)
    nil
  end

  def prepare_indexing(document, expected_fingerprint)
    Marine::Document.transaction do
      locked = Marine::Document.lock.find_by(id: document.id)
      next unless indexable?(locked, expected_fingerprint)

      rows = desired_rows(locked, Marine::Documents::Sop::Chunker.new(locked.content).call)
      next if rows.empty?
      next :noop if indexing_complete?(locked, rows)

      responses = reconcile_rows!(locked, rows)
      locked.update!(indexing_status: 'embedding_pending', indexed_fingerprint: locked.content_fingerprint,
                     indexed_chunk_count: rows.length, indexed_at: nil, indexing_error_code: nil)
      { document_id: locked.id, fingerprint: locked.content_fingerprint,
        response_ids: responses.map(&:id), chunk_count: rows.length }
    end
  end

  def reconcile_rows!(document, rows)
    return document.responses.order(:id).to_a if current_rows(document) == rows

    document.responses.delete_all
    rows.map do |question, answer|
      document.responses.create!(question: question, answer: answer, assistant: document.assistant,
                                 account: document.account, status: :approved, skip_embedding_enqueue: true)
    end
  end

  def enqueue_embeddings!(plan)
    plan.fetch(:response_ids).each do |response_id|
      response = Marine::AssistantResponse.find(response_id)
      job = Marine::Llm::UpdateEmbeddingJob.perform_later(
        response, { 'expected_fingerprint' => plan.fetch(:fingerprint) }
      )
      raise EmbeddingEnqueueError unless job&.successfully_enqueued?
    end
  end

  def mark_indexed_after_enqueue!(plan)
    Marine::Document.transaction do
      locked = Marine::Document.lock.find_by(id: plan.fetch(:document_id))
      next unless indexable?(locked, plan.fetch(:fingerprint))
      next unless locked.responses.order(:id).ids == plan.fetch(:response_ids)

      mark_indexed!(locked, plan.fetch(:chunk_count))
    end
  end

  def indexing_complete?(document, rows)
    current_rows(document) == rows && document.indexing_status == 'indexed' &&
      document.indexed_fingerprint == document.content_fingerprint &&
      document.indexed_chunk_count.to_i == rows.length
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

  # Preserve full grapheme clusters while enforcing PostgreSQL varchar(255)'s code-point
  # limit. A multi-code-point grapheme is included only when the complete cluster fits.
  def chunk_title(document, part, total)
    suffix = " (Part #{part} of #{total})"
    base = document.name.to_s.gsub(/[[:cntrl:]]/, ' ').squish.presence || "SOP ##{document.id}"
    room = [TITLE_MAX_CODEPOINTS - suffix.length, 0].max
    "#{grapheme_prefix(base, room)}#{suffix}"
  end

  def grapheme_prefix(value, codepoint_limit)
    value.scan(/\X/).each_with_object(+'') do |grapheme, prefix|
      break prefix if prefix.length + grapheme.length > codepoint_limit

      prefix << grapheme
    end
  end
end
