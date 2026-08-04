# Marine agent runner — the top-level orchestration layer for automated Marine
# replies. It ties together the already implemented Marine pieces behind a single
# deterministic, always-safe entry point:
#
#   * retrieval/knowledge answer generation, citations and confidence,
#   * multilingual detection/translation metadata,
#   * enabled scenario selection (deterministic keyword matching),
#   * enabled custom tools referenced by the selected scenario (resolution only),
#   * Marine fallback/handoff behavior,
#   * structured production logging/observability.
#
# Safety contract (holds even when the Marine LLM is blank/unconfigured on dev):
#   * never raises — any unexpected error degrades to a handoff payload;
#   * performs no external calls itself. Custom tools are only resolved to
#     metadata (slug/title/description) and exposed for downstream execution
#     through the existing tool safety code (Marine::Tools::HttpTool + SafeFetch);
#     the runner never invokes them and never surfaces auth config;
#   * always returns a payload shape compatible with the existing response path
#     (Marine::Charge::ResponseGenerator), enriched with orchestration metadata.
#
# Fully Marine-owned: no Captain runtime classes, hub checks, pricing plans, or
# premium feature flags.
class Marine::Agent::Runner
  LOG_PREFIX = '[Marine::Agent::Runner]'.freeze
  RUNNER_ERROR_REASON = 'runner_error'.freeze

  PATH_HANDOFF = 'handoff'.freeze
  PATH_RETRIEVAL = 'retrieval'.freeze
  PATH_SCENARIO_RETRIEVAL = 'scenario_retrieval'.freeze

  def initialize(assistant:, conversation: nil, source: nil)
    @assistant = assistant
    @conversation = conversation
    @source = source
  end

  def run(additional_message: nil, message_history: [])
    query = resolve_query(additional_message, message_history)
    log_event('runner.start', assistant_id: assistant_id, conversation_id: conversation_id,
                              source: source, query_present: query.present?)

    scenario = select_scenario(query)
    tool_slugs = resolved_tool_slugs(scenario)

    payload = response_generator.generate(additional_message: additional_message, message_history: message_history)
    enriched = enrich(payload, scenario, tool_slugs)

    log_result(enriched)
    enriched
  rescue StandardError => e
    handle_error(e)
  end

  private

  attr_reader :assistant, :conversation, :source

  def response_generator
    @response_generator ||= Marine::Charge::ResponseGenerator.new(
      assistant: assistant,
      conversation: conversation,
      source: source
    )
  end

  def select_scenario(query)
    return nil if query.blank?

    scenario = Marine::Agent::ScenarioSelector.new(assistant: assistant).select(query)
    if scenario
      log_event('scenario.selected', scenario_id: scenario.id)
    else
      log_event('scenario.none')
    end
    scenario
  end

  # Resolves the enabled custom tools referenced by the scenario down to their
  # slugs only. Uses Marine::CustomTool (via scenario.resolved_tools) exclusively
  # and never reads or logs auth_config.
  def resolved_tool_slugs(scenario)
    return [] if scenario.nil?

    slugs = scenario.resolved_tools.filter_map { |tool| tool[:id] }
    log_event('tools.resolved', scenario_id: scenario.id, tool_count: slugs.length, tools: slugs.join(',')) if slugs.any?
    slugs
  end

  def enrich(payload, scenario, tool_slugs)
    payload.merge(
      'orchestration_path' => orchestration_path(payload, scenario),
      'marine_scenario_id' => scenario&.id,
      'marine_scenario_title' => scenario&.title,
      'marine_scenario_tools' => tool_slugs
    )
  end

  def orchestration_path(payload, scenario)
    return PATH_HANDOFF if handoff?(payload)

    scenario ? PATH_SCENARIO_RETRIEVAL : PATH_RETRIEVAL
  end

  def handoff?(payload)
    payload['action'] == 'handoff' || payload['response'] == 'conversation_handoff'
  end

  def resolve_query(additional_message, message_history)
    additional_message.presence || extract_last_user_message(message_history)
  end

  def extract_last_user_message(message_history)
    message = Array(message_history).reverse.find do |item|
      item[:role].to_s == 'user' || item['role'].to_s == 'user'
    end
    message&.dig(:content) || message&.dig('content')
  end

  def handle_error(error)
    log_event('runner.error', error_class: error.class.name)
    capture(error)
    Marine::Circuit::HandoffService
      .low_confidence_payload(reason: RUNNER_ERROR_REASON)
      .merge('orchestration_path' => PATH_HANDOFF)
  end

  def capture(error)
    account = conversation&.account || (assistant.account if assistant.respond_to?(:account))
    return if account.nil?

    ChatwootExceptionTracker.new(error, account: account).capture_exception
  end

  def log_result(payload)
    if handoff?(payload)
      log_event('answer.handoff', path: payload['orchestration_path'], reason: payload['action_reason'])
    else
      log_event('answer.reply', path: payload['orchestration_path'],
                                confidence: payload['confidence'], source_type: payload['source_type'])
    end
  end

  # Structured, secret-free single-line logging. Only ids, slugs, confidence,
  # language, and reason codes are ever emitted — never auth config or API keys.
  def log_event(event, **fields)
    parts = fields.compact.map { |key, value| "#{key}=#{value}" }.join(' ')
    Rails.logger.info("#{LOG_PREFIX} event=#{event} #{parts}".strip)
  end

  def assistant_id
    assistant.id if assistant.respond_to?(:id)
  end

  def conversation_id
    conversation.id if conversation.respond_to?(:id)
  end
end
