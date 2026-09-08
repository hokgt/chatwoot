# Marine-owned copilot messages API, nested under a copilot thread. Appends a
# user question to an existing thread and synchronously generates the assistant
# answer through Marine::Copilot::QueryService. Account + assistant + user
# scoping is enforced through the parent thread lookup.
class Api::V1::Accounts::Marine::CopilotMessagesController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Marine::CopilotMessage) }
  before_action :set_assistant
  before_action :set_thread
  before_action :ensure_message, only: :create

  def index
    messages = @thread.copilot_messages.order(created_at: :asc)
    render json: { payload: messages.map { |message| serialize_message(message) } }
  end

  def create
    @thread.copilot_messages.create!(message_type: :user, message: { content: params[:message] })
    generate_answer(params[:message])
    render json: { payload: @thread.copilot_messages.order(created_at: :asc).map { |message| serialize_message(message) } }, status: :created
  end

  private

  def set_assistant
    @assistant = Current.account.marine_assistants.find(params[:assistant_id])
  end

  def set_thread
    @thread = @assistant.copilot_threads.where(user_id: Current.user.id).find(params[:copilot_thread_id])
  end

  def ensure_message
    render_could_not_create_error('Message is required') if params[:message].blank?
  end

  def generate_answer(question)
    result = Marine::Copilot::QueryService.new(assistant: @assistant, user: Current.user, thread: @thread).answer(question: question)
    @thread.copilot_messages.create!(
      message_type: :assistant,
      message: assistant_message_payload(result)
    )
  end

  def assistant_message_payload(result)
    if result[:error].present?
      { content: result[:error], error: result[:error] }
    else
      { content: result[:content].to_s, citations: result[:citations] || [] }
    end
  end

  def serialize_message(message)
    {
      id: message.id,
      message: message.message,
      message_type: message.message_type,
      created_at: message.created_at.to_i
    }
  end
end
