# BACKEND-AUTHORITATIVE resolver from a stable scenario key to the ACTUAL enabled Marine::Scenario
# for a specific assistant (Phase 2 / Stage 6 — controlled cutover). The Decision Maker may only
# ever NOMINATE a scenario by its stable `scenario_<id>` key; it is never trusted to carry a title,
# model, adapter row, account, or an enabled/disabled flag. This resolver re-queries the database
# at resolution time so the authority is always the persisted, currently-enabled row — never the
# untrusted plan.
#
# It accepts ONLY the exact stable key format `scenario_<positive integer>` (no leading zero, no
# `scenario_0`, no title-derived key) and re-queries assistant.scenarios.enabled by that id. A
# wrong format, a zero / negative / out-of-range id, a missing / disabled / cross-assistant /
# foreign-account row, or ANY error yields nil. It never raises and returns the real
# ActiveRecord Marine::Scenario object or nil — nothing else.
class Marine::Decision::ScenarioResolver
  # Exact `scenario_<positive integer>`: a leading non-zero digit then up to 18 more digits (19
  # total covers a bigint), so a single canonical string maps to a single id and `scenario_0`,
  # a leading-zero form, an uppercase/hyphenated/whitespace key, or a title-derived key never match.
  KEY_PATTERN = /\Ascenario_([1-9]\d{0,18})\z/
  # PostgreSQL bigint ceiling; a 19-digit id above this is out of range and resolves to nil.
  MAX_ID = 9_223_372_036_854_775_807

  def initialize(assistant:)
    @assistant = assistant
  end

  def self.resolve(assistant:, key:)
    new(assistant: assistant).resolve(key)
  end

  # The actual ENABLED Marine::Scenario belonging to THIS assistant whose id matches the stable
  # key, re-queried now, or nil. The scope (assistant.scenarios.enabled) guarantees a disabled,
  # cross-assistant, or foreign-account row can never be returned. Never raises.
  def resolve(key)
    id = extract_id(key)
    return nil if id.nil?
    return nil unless @assistant.respond_to?(:scenarios)

    @assistant.scenarios.enabled.find_by(id: id)
  rescue StandardError
    nil
  end

  private

  # The positive Integer id encoded by an exact `scenario_<id>` key, or nil for a wrong format or
  # an out-of-range (above bigint) id. Never raises.
  def extract_id(key)
    return nil unless key.is_a?(String)

    match = KEY_PATTERN.match(key)
    return nil if match.nil?

    id = Integer(match[1], 10)
    id <= MAX_ID ? id : nil
  rescue ArgumentError
    nil
  end
end
