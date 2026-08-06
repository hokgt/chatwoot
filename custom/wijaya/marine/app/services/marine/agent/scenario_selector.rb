# Deterministic scenario selection for the Marine agent runner. Given a customer
# query and an assistant, it picks the best-matching enabled scenario using pure
# token overlap against each scenario's title/description/instruction — no LLM,
# no external calls, so it is safe and reproducible even when the Marine LLM is
# unconfigured. Fully Marine-owned; never touches Captain, hub, or premium gates.
class Marine::Agent::ScenarioSelector
  TOKEN_PATTERN = /[[:alnum:]]{3,}/
  MIN_SCORE = 0.2

  def initialize(assistant:)
    @assistant = assistant
  end

  # Returns the highest-scoring enabled Marine::Scenario whose token overlap with
  # the query clears MIN_SCORE, or nil when nothing matches. Ties resolve to the
  # lowest id so selection stays stable across calls.
  def select(query)
    query_tokens = tokenize(query)
    return nil if query_tokens.empty?

    scored = enabled_scenarios.filter_map do |scenario|
      score = overlap_score(query_tokens, scenario)
      [scenario, score] if score >= MIN_SCORE
    end
    return nil if scored.empty?

    scored.min_by { |scenario, score| [-score, scenario.id] }&.first
  end

  private

  attr_reader :assistant

  def enabled_scenarios
    return [] unless assistant.respond_to?(:scenarios)

    assistant.scenarios.enabled.order(:id).to_a
  end

  def overlap_score(query_tokens, scenario)
    scenario_tokens = tokenize([scenario.title, scenario.description, scenario.instruction].join(' '))
    return 0.0 if scenario_tokens.empty?

    (query_tokens & scenario_tokens).length.to_f / query_tokens.length
  end

  def tokenize(text)
    text.to_s.downcase.scan(TOKEN_PATTERN).uniq
  end
end
