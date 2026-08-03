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

  # Website documents only (URL/content). Unchanged behavior — never accepts a file,
  # a product family, or a source_kind, so it can only ever create a website source.
  def create
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

  def sync
    @document.update!(sync_status: :syncing, last_sync_attempted_at: Time.current)
    Marine::Documents::ResponseBuilderJob.perform_later(@document)
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
    else :unprocessable_entity
    end
  end

  def render_catalog_unavailable(error)
    render json: { error: error.message, i18n_key: error.i18n_key }, status: :service_unavailable
  end
end
