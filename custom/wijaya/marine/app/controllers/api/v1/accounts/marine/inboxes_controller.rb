class Api::V1::Accounts::Marine::InboxesController < Api::V1::Accounts::BaseController
  before_action :current_account
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

  def set_assistant
    @assistant = Current.account.marine_assistants.find(params[:assistant_id])
  end

  def inbox_params
    params.require(:inbox).permit(:inbox_id)
  end
end
