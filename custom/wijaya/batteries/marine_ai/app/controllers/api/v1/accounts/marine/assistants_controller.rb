class Api::V1::Accounts::Marine::AssistantsController < Api::V1::Accounts::BaseController
  # Playground transcript is an untrusted client payload, so it is bounded/allowlisted server-side
  # before it ever reaches the runner: only user/assistant roles, the newest turns, each truncated.
  # Mirrors the canonical ContextBuilder bounds so the preview grounds on the same window a real
  # conversation would (Marine::Conversation::ContextBuilder MAX_HISTORY_MESSAGES / _MESSAGE_CHARS).
  PLAYGROUND_MAX_HISTORY_TURNS = 10
  PLAYGROUND_MAX_TURN_CHARS = 500
  PLAYGROUND_HISTORY_ROLES = %w[user assistant].freeze

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
    service = Marine::Llm::AssistantChatService.new(assistant: @assistant, source: 'playground')
    render json: service.generate_response(additional_message: playground_params[:message_content],
                                           message_history: playground_message_history)
  end

  private

  def set_assistant
    @assistant = Current.account.marine_assistants.find(params[:id])
  end

  def assistant_params
    params.require(:assistant).permit(:name, :description, guardrails: [], response_guidelines: [],
                                                           config: [:product_name, :welcome_message, :handoff_message,
                                                                    :resolution_message, :instructions, :temperature,
                                                                    :feature_faq, :feature_memory, :feature_contact_attributes])
  end

  def playground_params
    params.require(:assistant).permit(:message_content, message_history: [:role, :content])
  end

  # Sanitized, bounded prior turns for the multi-turn playground preview. Untrusted input, so
  # every turn is allowlisted by role, blank content dropped, content truncated, and only the
  # newest PLAYGROUND_MAX_HISTORY_TURNS kept (oldest-to-newest order preserved).
  def playground_message_history
    Array(playground_params[:message_history]).filter_map do |turn|
      role = turn[:role].to_s
      content = turn[:content].to_s.strip
      next if content.blank? || PLAYGROUND_HISTORY_ROLES.exclude?(role)

      { role: role, content: content[0, PLAYGROUND_MAX_TURN_CHARS] }
    end.last(PLAYGROUND_MAX_HISTORY_TURNS)
  end
end
