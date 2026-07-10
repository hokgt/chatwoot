class Api::V1::Accounts::Marine::AssistantsController < Api::V1::Accounts::BaseController
  before_action :current_account
  before_action -> { check_authorization(Marine::Assistant) }
  before_action :set_assistant, only: [:show, :update, :destroy, :playground]

  def index
    render json: { payload: Current.account.marine_assistants.ordered.as_json(methods: [:avatar_url]) }
  end

  def show
    render json: @assistant
  end

  def create
    assistant = Current.account.marine_assistants.create!(assistant_params)
    render json: assistant, status: :created
  end

  def update
    @assistant.update!(assistant_params)
    render json: @assistant
  end

  def destroy
    @assistant.destroy!
    head :no_content
  end

  def playground
    render json: Marine::Llm::AssistantChatService.new(assistant: @assistant, source: 'playground').generate_response(additional_message: playground_params[:message_content])
  end

  private

  def set_assistant
    @assistant = Current.account.marine_assistants.find(params[:id])
  end

  def assistant_params
    params.require(:assistant).permit(:name, :description, guardrails: [], response_guidelines: [], config: [:product_name, :welcome_message, :handoff_message, :resolution_message, :instructions, :temperature, :feature_faq, :feature_memory, :feature_contact_attributes])
  end

  def playground_params
    params.require(:assistant).permit(:message_content)
  end
end
