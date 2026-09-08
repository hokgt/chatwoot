require 'timeout'

class Api::V1::Accounts::Marine::AssistantsController < Api::V1::Accounts::BaseController
  # Playground transcript is an untrusted client payload, so it is bounded/allowlisted server-side
  # before it ever reaches the runner: only user/assistant roles, the newest turns, each truncated.
  # Mirrors the canonical ContextBuilder bounds so the preview grounds on the same window a real
  # conversation would (Marine::Conversation::ContextBuilder MAX_HISTORY_MESSAGES / _MESSAGE_CHARS).
  PLAYGROUND_MAX_HISTORY_TURNS = 10
  PLAYGROUND_MAX_TURN_CHARS = 500
  PLAYGROUND_HISTORY_ROLES = %w[user assistant].freeze

  # Wall-clock ceiling for the synchronous playground preview. The preview can make several
  # sequential provider calls (translate -> RAG -> contextual wording -> translate), each bounded
  # only by Marine::Llm::BaseService::REQUEST_TIMEOUT (30s) and RubyLLM retries, so the total can
  # outrun the 15s Rack::Timeout service deadline and surface as an unhandled 500. This deadline
  # fires first (12s < 15s, leaving margin for the sanitized render) so a slow/hung provider fails
  # closed as a controlled 504 instead. It is deliberately scoped to this controller action: the
  # shared Sidekiq ResponseBuilderJob path (same AssistantChatService, no Rack deadline) is untouched.
  PLAYGROUND_REQUEST_DEADLINE = 12

  # Raised by Timeout.timeout below when the deadline elapses. It intentionally subclasses Exception
  # rather than StandardError: the deadline must unwind PAST the `rescue StandardError` guards inside
  # BaseService/ResponseGenerator/Agent::Runner (which would otherwise swallow it and let the pipeline
  # begin the NEXT provider call, defeating the wall-clock), exactly as Rack::Timeout's own exception
  # does. It is caught explicitly by class in #playground, never leaks to a generic handler.
  PlaygroundDeadlineError = Class.new(Exception) # rubocop:disable Lint/InheritException

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
    service = Marine::Llm::AssistantChatService.new(assistant: @assistant, source: 'playground',
                                                    state_token: playground_params[:state_token].presence)
    payload = Timeout.timeout(PLAYGROUND_REQUEST_DEADLINE, PlaygroundDeadlineError) do
      service.generate_response(additional_message: playground_params[:message_content],
                                message_history: playground_message_history)
    end
    render json: payload
  rescue PlaygroundDeadlineError
    Rails.logger.warn("[Marine::Playground] provider deadline exceeded after #{PLAYGROUND_REQUEST_DEADLINE}s " \
                      "account_id=#{Current.account&.id} assistant_id=#{@assistant&.id}")
    render json: { error: 'playground_timeout' }, status: :gateway_timeout
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
    params.require(:assistant).permit(:message_content, :state_token, message_history: [:role, :content])
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
