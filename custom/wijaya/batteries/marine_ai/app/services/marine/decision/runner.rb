# Pure, ISOLATED orchestrator for the battery-local Marine Decision Maker (Phase 2 /
# Stage 3 — UNWIRED). Given the latest customer message, bounded recent context, coarse
# candidate state, and the enabled scenario/capability seam, it returns EXACTLY one
# canonical, deep-frozen Marine::Decision::CandidatePlan — a bounded SUGGESTION, never a
# validated fact, reply, or executable action.
#
# Trust discipline:
#   * Reads ONLY the decision-maker settings (SettingsStore.for(:decision_maker)) and its
#     api_mode; never the Response Generator config / BaseService.
#   * Talks to the network ONLY through the injected Marine::Decision::Client, which is
#     itself settings-bound and fail-closed.
#   * NEVER raises to the caller. Every failure — bad input, unconfigured/timeout/provider
#     transport, malformed builder/mapper/parser output, a mode race, or a normalizer
#     rejection — folds to CandidatePlan.unknown carrying ONLY an allowlisted opaque reason
#     (unconfigured / timeout / provider_error / malformed_response / unsupported_schema).
#     No log, metric, event, raw body, exception text, or input value rides out.
#
# It uses NO Agent::Runner, ScenarioSelector, DB/catalog model, repository, job, cache,
# persistence, or state mutation. Capability arrays are candidate CONSTRAINTS only: the
# surviving intents are intersected with the union of declared capabilities + unsupported,
# so the runner never proposes an intent no supplied scenario claims. It does NOT pick the
# final scenario/intent to execute — that is a later phase.
class Marine::Decision::Runner
  Schema = Marine::Decision::Schema
  VALID_MODES = %w[chat_completions openrouter_decisions].freeze

  # Internal control-flow signal carrying the allowlisted unknown reason to fold to. Never
  # escapes #call.
  class Fold < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(reason)
    end
  end

  def initialize(client: nil, settings: nil)
    @settings = settings || Marine::Llm::SettingsStore.for(:decision_maker)
    @client = client || Marine::Decision::Client.new(settings: @settings)
  end

  # Returns a canonical, deep-frozen CandidatePlan. `scenarios` is required; the rest
  # default to empty. Never raises.
  def call(message:, scenarios:, context: [], state: {})
    plan(message, context, state, scenarios)
  rescue Fold => e
    unknown(e.reason)
  rescue StandardError
    # Any unforeseen failure folds to the most generic provider outcome; nothing leaks.
    unknown('provider_error')
  end

  private

  def plan(message, context, state, scenarios)
    input = build_input(message, context, state, scenarios)
    mode = resolve_mode
    transport = @client.call(build_request(mode, input))
    raise Fold, transport_reason(transport) unless transport[:ok]

    normalize(interpret(mode, transport[:payload], input), input)
  end

  # The mode is already gated by resolve_mode, so RequestBuilder::Invalid is unreachable on
  # this path; folding it to malformed_response keeps the outcome consistent (never a leaked
  # provider_error) if that defense-in-depth guard ever fires. The Stage 2 transport client
  # owns the FINAL aggregate request-byte guard: an oversized-but-in-contract request is
  # rejected there before any network call and returns a malformed_response transport
  # failure, which folds to a safe unknown plan here.
  def build_request(mode, input)
    Marine::Decision::RequestBuilder.build(mode: mode, input: input)
  rescue Marine::Decision::RequestBuilder::Invalid
    raise Fold, 'malformed_response'
  end

  # Bad caller input is a malformed request, not a provider fault.
  def build_input(message, context, state, scenarios)
    Marine::Decision::InputContract.build(message: message, context: context, state: state, scenarios: scenarios)
  rescue Marine::Decision::InputContract::Invalid
    raise Fold, 'malformed_response'
  end

  # Only the decision-maker api_mode is read. An unrecognized mode (e.g. a config race)
  # folds to unconfigured rather than dispatching a wrong protocol.
  def resolve_mode
    mode = @settings.api_mode
    raise Fold, 'unconfigured' unless VALID_MODES.include?(mode)

    mode
  end

  # Turn the transport payload into an untrusted raw candidate hash. A payload whose shape
  # does not match the mode's transport contract is an unsupported schema; a well-shaped but
  # otherwise unusable payload is malformed.
  def interpret(mode, payload, input)
    raw =
      if mode == 'openrouter_decisions'
        raise Fold, 'unsupported_schema' unless payload.is_a?(Hash)

        Marine::Decision::DecisionsResponseMapper.map(payload, scenario_keys: input[:scenario_keys], allowed_intents: input[:allowed_intents])
      else
        parsed = Marine::Decision::ChatResponseParser.parse(payload)
        enforce_chat_scenario_allowlist!(parsed, input[:scenario_keys]) unless parsed.nil?
        parsed
      end
    raise Fold, 'malformed_response' if raw.nil?

    raw
  end

  # The chat JSON schema restricts scenario_candidate.key to the supplied scenario keys, but
  # a JSON schema is provider-advisory only — never our authority. We independently re-check
  # here: a non-nil candidate key that is not one of the supplied keys folds the WHOLE result
  # to malformed_response (never silently preserved or dropped), mirroring the Decisions
  # mapper. The normalizer only knows the key's FORMAT (SCENARIO_KEY_PATTERN), not which keys
  # were actually offered, so it cannot make this call. The raw provider hash is read, not
  # mutated, and a String- or Symbol-keyed shape is tolerated but a non-String key VALUE (or
  # an unsupplied key) fails closed.
  def enforce_chat_scenario_allowlist!(raw, scenario_keys)
    return unless raw.is_a?(Hash)

    candidate = dual_key(raw, 'scenario_candidate')
    return unless candidate.is_a?(Hash)

    key = dual_key(candidate, 'key')
    return if key.nil?

    raise Fold, 'malformed_response' unless key.is_a?(String) && scenario_keys.include?(key)
  end

  # Read a String- or Symbol-keyed value without mutating the (untrusted) provider hash.
  def dual_key(hash, name)
    hash.key?(name) ? hash[name] : hash[name.to_sym]
  end

  # Intersect the proposed intents with the allowed capability union, then hand the result
  # to the Stage 1 normalizer as the FINAL authority. A wrong schema_version is an explicit
  # unsupported-schema fold; any other contract violation is malformed.
  def normalize(raw, input)
    raise Fold, 'unsupported_schema' unless schema_version(raw) == Schema::SCHEMA_VERSION

    Marine::Decision::CandidatePlan.normalize(intersect_capabilities(raw, input[:allowed_intents]))
  rescue Marine::Decision::Errors::InvalidCandidatePlan
    raise Fold, 'malformed_response'
  end

  def schema_version(raw)
    return nil unless raw.is_a?(Hash)

    raw['schema_version'] || raw[:schema_version]
  end

  # Candidate intents that no supplied scenario declares (nor 'unsupported') are dropped
  # BEFORE normalization. Builds a fresh hash (parser/mapper output is never mutated) and
  # preserves the existing key form so no duplicate String/Symbol key is introduced; a
  # missing or non-array intents value is left for the normalizer to handle.
  def intersect_capabilities(raw, allowed_intents)
    return raw unless raw.is_a?(Hash)

    key = raw.key?('intents') ? 'intents' : (:intents if raw.key?(:intents))
    return raw if key.nil?

    intents = raw[key]
    return raw unless intents.is_a?(Array)

    raw.merge(key => intents.select { |intent| allowed_intents.include?(intent) })
  end

  def transport_reason(transport)
    reason = transport[:error_reason]
    # Transport reasons are already a subset of the unknown allowlist; an unknown/absent
    # reason folds to provider_error (documented choice).
    Schema::UNKNOWN_REASONS.include?(reason) ? reason : 'provider_error'
  end

  def unknown(reason)
    Marine::Decision::CandidatePlan.unknown(reason)
  end
end
