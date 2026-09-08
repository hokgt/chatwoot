class Api::V1::Accounts::Marine::AssistantResponsesController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Marine::Assistant) }
  before_action :set_responses, except: [:create]
  before_action :set_response, only: [:show, :update, :destroy]

  def index
    responses = @responses
    responses = responses.where(assistant_id: params[:assistant_id]) if params[:assistant_id].present?
    responses = responses.where(status: params[:status]) if params[:status].present?
    render json: { payload: responses.ordered, count: responses.count }
  end

  def show
    render json: @response
  end

  def create
    response = Current.account.marine_assistant_responses.create!(response_params.merge(documentable: Current.user))
    render json: response, status: :created
  end

  def update
    @response.update!(response_params)
    render json: @response
  end

  def destroy
    @response.destroy!
    head :no_content
  end

  private

  def set_responses
    @responses = Current.account.marine_assistant_responses.includes(:assistant, :documentable)
  end

  def set_response
    @response = @responses.find(params[:id])
  end

  def response_params
    params.require(:assistant_response).permit(:question, :answer, :assistant_id, :status)
  end
end
