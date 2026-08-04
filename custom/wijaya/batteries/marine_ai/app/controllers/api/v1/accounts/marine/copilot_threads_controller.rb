# Marine-owned copilot threads API. Mirrors the Captain copilot threads
# controller but without any premium/usage gate: Marine copilot is always
# available and scoped to the account, assistant, and current user. Renders JSON
# inline to match the existing Marine controllers.
#
# Answer generation runs synchronously via Marine::Copilot::QueryService (no
# background agent runner — that is out of scope for this commit) and always
# degrades safely when the Marine LLM is unconfigured.
class Api::V1::Accounts::Marine::CopilotThreadsController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Marine::CopilotThread) }
  before_action :set_assistant
  before_action :set_thread, only: [:show, :destroy]
  before_action :ensure_message, only: :create

  def index
    threads = assistant_threads.ordered
    render json: { payload: threads.map { |thread| serialize_thread(thread) }, meta: { total_count: threads.count } }
  end

  def show
    render json: serialize_thread(@thread, include_messages: true)
  end

  def create
    thread = nil
    ActiveRecord::Base.transaction do
      thread = assistant_threads.create!(
        title: thread_params[:message].to_s.truncate(120),
        account: Current.account,
        user: Current.user
      )
      thread.copilot_messages.create!(message_type: :user, message: { content: thread_params[:message] })
    end

    generate_answer(thread, thread_params[:message])
    render json: serialize_thread(thread.reload, include_messages: true), status: :created
  end

  def destroy
    @thread.destroy!
    head :no_content
  end

  private

  def set_assistant
    @assistant = Current.account.marine_assistants.find(params[:assistant_id])
  end

  def assistant_threads
    @assistant.copilot_threads.where(user_id: Current.user.id)
  end

  def set_thread
    @thread = assistant_threads.find(params[:id])
  end

  def ensure_message
    render_could_not_create_error('Message is required') if thread_params[:message].blank?
  end

  def generate_answer(thread, question)
    result = Marine::Copilot::QueryService.new(assistant: @assistant, user: Current.user, thread: thread).answer(question: question)
    thread.copilot_messages.create!(
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

  def thread_params
    params.permit(:message, :assistant_id)
  end

  def serialize_thread(thread, include_messages: false)
    payload = {
      id: thread.id,
      title: thread.title,
      assistant_id: thread.assistant_id,
      account_id: thread.account_id,
      user_id: thread.user_id,
      created_at: thread.created_at.to_i
    }
    payload[:messages] = thread.copilot_messages.order(created_at: :asc).map { |message| serialize_message(message) } if include_messages
    payload
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
