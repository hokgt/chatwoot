# Read-only adapter that turns an assistant's ENABLED Marine scenarios into the owned,
# bounded, string-keyed scenario seam the Decision InputContract accepts (Phase 2 /
# Stage 4 — shadow-only). It is the single place that maps a persisted Marine::Scenario to
# the isolated Decision Runner's scenario contract.
#
# Discipline:
#   * ONLY assistant.scenarios.enabled, ordered by id (stable). It fetches at most
#     MAX_SCENARIOS + 1 rows so an oversized set is DETECTED (see #overflow?) rather than
#     silently truncated to a partial population the shadow would then compare as if complete.
#   * The stable key is EXACTLY `scenario_<database id>` — never derived from the title,
#     so it stays stable across renames and is directly comparable to the ScenarioSelector's
#     chosen scenario key.
#   * description/instruction are bounded, owned copies (data only). The scenario seam carries
#     identity/context ONLY — no capabilities. Execution authorization is backend-policy-owned
#     (the backend execution policy) and the classification vocabulary is injected downstream.
#
# It reads persisted scenarios but MUTATES nothing: it never freezes or writes back to the
# ActiveRecord rows and returns freshly-built, owned Ruby hashes/strings.
class Marine::Decision::ScenarioAdapter
  # Stay within the InputContract's own scenario ceiling so the shadow builds a real plan
  # rather than folding to unknown when an assistant has an unusually large scenario set.
  MAX_SCENARIOS = Marine::Decision::InputContract::MAX_SCENARIOS
  # Bound each text to the contract's per-summary character ceiling; the InputContract
  # strips/validates the owned copy again.
  MAX_TEXT_CHARS = Marine::Decision::InputContract::MAX_SUMMARY_CHARS

  def initialize(assistant:)
    @assistant = assistant
  end

  # True when the assistant exposes MORE than MAX_SCENARIOS enabled scenarios — detected from
  # the MAX_SCENARIOS + 1 bounded fetch, never by loading the whole set. When true the caller
  # (ShadowExecution) MUST fail closed instead of comparing a truncated scenario population.
  def overflow?
    enabled_scenarios.length > MAX_SCENARIOS
  end

  # An Array of owned, string-keyed scenario data hashes for the InputContract, or [] when
  # the assistant exposes no enabled scenarios. Read-only. Callers must check #overflow? first:
  # on overflow this head is NOT a complete population and must not be compared.
  def scenarios
    enabled_scenarios.first(MAX_SCENARIOS).map { |scenario| entry(scenario) }
  end

  private

  # The enabled scenarios id-ordered, fetched at most MAX_SCENARIOS + 1 rows so overflow is
  # detected without loading an unbounded set. Memoized so one query serves both public methods.
  def enabled_scenarios
    return [] unless @assistant.respond_to?(:scenarios)

    @enabled_scenarios ||= @assistant.scenarios.enabled.order(:id).limit(MAX_SCENARIOS + 1).to_a
  end

  def entry(scenario)
    {
      'key' => "scenario_#{scenario.id}",
      'description' => clean(scenario.description),
      'instruction' => clean(scenario.instruction)
    }
  end

  # A bounded, owned copy of the scenario text. The InputContract strips and re-validates it.
  def clean(text)
    text.to_s[0, MAX_TEXT_CHARS].dup
  end
end
