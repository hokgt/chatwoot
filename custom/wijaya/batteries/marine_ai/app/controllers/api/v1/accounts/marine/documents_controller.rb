class Api::V1::Accounts::Marine::DocumentsController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Marine::Assistant) }
  before_action :set_documents, except: [:create, :product_catalog, :product_families]
  before_action :set_document, only: [:show, :destroy, :sync]

  rescue_from Marine::Documents::Errors::ServiceError, with: :render_document_error
  rescue_from Marine::Catalog::Errors::CatalogError, with: :render_catalog_unavailable

  def index
    docs = @documents
    docs = docs.where(assistant_id: params[:assistant_id]) if params[:assistant_id].present?
    render json: { payload: docs.ordered.map { |doc| Marine::Documents::Serializer.call(doc) }, count: docs.count }
  end

  def show
    render json: Marine::Documents::Serializer.call(@document)
  end

  # Website documents (URL/content) OR, for a multipart source_kind=sop_document
  # request, an SOP document routed to the dedicated SOP service. Website behavior is
  # unchanged; the SOP branch never permits client-controlled status/sync/blob metadata.
  def create
    return create_sop_document if sop_document_create?

    assistant = Current.account.marine_assistants.find(document_params[:assistant_id])
    document = assistant.documents.create!(document_params)
    render json: Marine::Documents::Serializer.call(document), status: :created
  end

  # Bounded, read-only product-family lookup for a later dropdown/API. Never touches
  # the Chatwoot DB; reads the canonical Marine item data via a stubbed-in-test repo.
  def product_families
    families = Marine::Catalog::ProductFamilyRepository.new.search(
      query: params[:query],
      limit: params[:limit]
    )
    render json: { payload: families }
  end

  # Multipart create/replace of the single primary Product Catalog for an
  # assistant + product family. All business logic lives in the service.
  def product_catalog
    assistant = Current.account.marine_assistants.find(product_catalog_params[:assistant_id])
    document = Marine::Documents::ProductCatalogService.new(
      account: Current.account,
      assistant: assistant,
      product_family_code: product_catalog_params[:product_family_code],
      upload: product_catalog_params[:file],
      primary_catalog: product_catalog_params.fetch(:primary_catalog, true),
      replace: product_catalog_params.fetch(:replace, false),
      name: product_catalog_params[:name]
    ).call
    render json: Marine::Documents::Serializer.call(document), status: :created
  end

  # Multipart SOP create/reprocess. All business logic lives in the service; the
  # controller permits only assistant_id, name, and the upload.
  def create_sop_document
    permitted = sop_document_params
    assistant = Current.account.marine_assistants.find(permitted[:assistant_id])
    document = Marine::Documents::CreateSopService.new(
      account: Current.account,
      assistant: assistant,
      name: permitted[:name],
      upload: permitted[:upload]
    ).call
    render json: Marine::Documents::Serializer.call(document), status: :created
  end

  # Website: unchanged (URL content rebuild). SOP: queue reprocessing via the SOP
  # extraction job, preserving the original file. Product catalog: never processable.
  def sync
    raise Marine::Documents::Errors::NotSyncableError if @document.product_catalog?

    @document.update!(sync_status: :syncing, last_sync_attempted_at: Time.current)
    if @document.sop_document?
      enqueue_sop_reprocessing(@document)
    else
      Marine::Documents::ResponseBuilderJob.perform_later(@document)
    end
    head :accepted
  end

  def destroy
    @document.destroy!
    head :no_content
  end

  private

  def set_documents
    @documents = Current.account.marine_documents.includes(:assistant)
  end

  def set_document
    @document = @documents.find(params[:id])
  end

  def document_params
    params.require(:document).permit(:name, :external_link, :assistant_id, :content)
  end

  # Detects an SOP create in BOTH the approved nested shape
  # (document[source_kind]=sop_document) and the flat compatibility shape
  # (source_kind=sop_document).
  def sop_document_create?
    (params[:source_kind] || params.dig(:document, :source_kind)).to_s == 'sop_document'
  end

  # Deliberately permits ONLY assistant_id, name, and the upload — never a blob id,
  # source_kind, content, external_link, status, or sync fields, so clients cannot
  # smuggle them. Accepts BOTH the approved nested keys (document[assistant_id],
  # document[name], document[source_file]) and the flat compatibility keys
  # (assistant_id, name, file), normalized to a single hash with an :upload.
  def sop_document_params
    scoped = params.key?(:document) ? params.require(:document) : params
    permitted = scoped.permit(:assistant_id, :name, :source_file, :file)
    {
      assistant_id: permitted[:assistant_id],
      name: permitted[:name],
      upload: permitted[:source_file] || permitted[:file]
    }
  end

  # Queues SOP reprocessing. A broker failure must NOT leak a raw exception or leave the
  # document stuck syncing: roll it back to a stable failed state and surface a
  # sanitized, deterministic service error. We pass the expected source blob id and a
  # fresh opaque run token so the job's atomic claim guards against stale/concurrent runs.
  def enqueue_sop_reprocessing(document)
    Marine::Documents::ProcessJob.perform_later(document, document.source_file.blob.id, SecureRandom.uuid)
  rescue StandardError
    document.update!(
      sync_status: :failed,
      last_sync_attempted_at: Time.current,
      last_sync_error_code: 'sop_enqueue_failed',
      sync_run_token: nil
    )
    raise Marine::Documents::Errors::EnqueueFailedError
  end

  # Deliberately flat/multipart: never permits an ActiveStorage blob id, source_kind,
  # content, external_link, or other processing fields — clients cannot smuggle them.
  def product_catalog_params
    params.permit(:assistant_id, :product_family_code, :name, :primary_catalog, :replace, :file)
  end

  def render_document_error(error)
    render json: { error: error.message, i18n_key: error.i18n_key }, status: document_error_status(error)
  end

  def document_error_status(error)
    case error
    when Marine::Documents::Errors::PrimaryConflictError then :conflict
    when Marine::Documents::Errors::AccountMismatchError then :forbidden
    when Marine::Documents::Errors::EnqueueFailedError then :service_unavailable
    else :unprocessable_entity
    end
  end

  def render_catalog_unavailable(error)
    render json: { error: error.message, i18n_key: error.i18n_key }, status: :service_unavailable
  end
end
