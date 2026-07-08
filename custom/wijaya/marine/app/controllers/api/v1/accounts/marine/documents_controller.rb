class Api::V1::Accounts::Marine::DocumentsController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Marine::Assistant) }
  before_action :set_documents, except: [:create]
  before_action :set_document, only: [:show, :destroy, :sync]

  def index
    docs = @documents
    docs = docs.where(assistant_id: params[:assistant_id]) if params[:assistant_id].present?
    render json: { payload: docs.ordered, count: docs.count }
  end

  def show
    render json: @document
  end

  def create
    assistant = Current.account.marine_assistants.find(document_params[:assistant_id])
    document = assistant.documents.create!(document_params)
    render json: document, status: :created
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
end
