class Api::V1::Accounts::Marine::InboxesController < Api::V1::Accounts::BaseController
  before_action :current_account
  # The Marine Inboxes area (assistant<->inbox associations) is administrator-only.
  # Reading the associations (index) is as sensitive as mutating them, so the whole
  # controller is admin-gated — unlike Marine::AssistantPolicy#index?, which stays
  # open because it is shared by the assistant list every Marine page needs.
  before_action :authorize_account_update
  before_action -> { check_authorization(Marine::Assistant) }
  before_action :set_assistant

  def index
    render json: { payload: @assistant.inboxes }
  end

  def create
    inbox = Current.account.inboxes.find(inbox_params[:inbox_id])
    link = @assistant.marine_inboxes.create!(inbox: inbox)
    render json: link, status: :created
  end

  def destroy
    @assistant.marine_inboxes.find_by!(inbox_id: params[:inbox_id]).destroy!
    head :no_content
  end

  private

  def authorize_account_update
    authorize Current.account, :update?
  end

  def set_assistant
    @assistant = Current.account.marine_assistants.find(params[:assistant_id])
  end

  def inbox_params
    params.require(:inbox).permit(:inbox_id)
  end
end
