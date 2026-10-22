# Immutable, sanitized value factory for the battery-local Marine Decision Maker
# TRANSPORT layer (Phase 2 / Stage 2). A transport result is the ONLY thing a
# Decision transport client returns; it is strict, bounded, and deeply immutable and
# carries NO provider object/body/headers, API key, raw exception, or customer
# request text — only a bounded payload plus an allowlisted opaque outcome.
#
#   success: { ok: true,  payload: <String (chat) | Hash (decisions)>, error_reason: nil,
#              model: <bounded String>, api_mode: <allowlisted mode> }
#   failure: { ok: false, payload: nil, error_reason: <allowlisted opaque reason>,
#              model: <bounded String or nil>, api_mode: <allowlisted mode or nil> }
#
# The failure reasons are a subset of Marine::Decision::Schema::UNKNOWN_REASONS, so a
# runner can feed error_reason straight into Marine::Decision::CandidatePlan.unknown.
# Any unrecognized reason folds to 'malformed_response'; raw error prose never rides out.
#
# The payload is DEEP-COPIED into result-owned objects and the whole result is
# deep-frozen, so a caller can neither mutate a returned result nor cause a
# caller-/provider-owned input object to be frozen. This file performs no I/O.
module Marine::Decision::TransportResult
  # The two protocols a Decision transport can speak (mirrors SettingsStore::API_MODES).
  API_MODES = %w[chat_completions openrouter_decisions].freeze

  # Closed, opaque failure vocabulary — a subset of the candidate-plan unknown reasons.
  FAILURE_REASONS = %w[unconfigured timeout provider_error malformed_response].freeze
  DEFAULT_FAILURE_REASON = 'malformed_response'.freeze

  # Conservative bound so a hostile/oversized model string can never ride out unbounded.
  MAX_MODEL_LENGTH = 200

  module_function

  def success(payload:, model:, api_mode:)
    build(ok: true, payload: deep_copy(payload), error_reason: nil,
          model: bounded_model(model), api_mode: check_mode(api_mode))
  end

  def failure(reason:, api_mode:, model: nil)
    build(ok: false, payload: nil, error_reason: normalize_reason(reason),
          model: bounded_model(model), api_mode: check_mode(api_mode))
  end

  # Deep-freeze the whole result and every nested value so callers cannot mutate it.
  def build(attrs)
    deep_freeze(attrs)
  end

  # Fold any input to an allowlisted opaque reason, returning a FRESH owned string so
  # deep-freeze never freezes a shared constant.
  def normalize_reason(reason)
    code = reason.to_s
    (FAILURE_REASONS.include?(code) ? code : DEFAULT_FAILURE_REASON).dup
  end

  # api_mode is either an allowlisted mode or nil (nil only when no transport was
  # selected, e.g. an unrecognized configured mode). Anything else is a programmer error.
  # A FRESH owned copy is returned so deep-freeze never freezes a caller-owned mode string.
  def check_mode(api_mode)
    return nil if api_mode.nil?
    raise ArgumentError, "unknown transport api_mode: #{api_mode}" unless API_MODES.include?(api_mode)

    api_mode.dup
  end

  def bounded_model(model)
    return nil if model.nil?

    model.to_s[0, MAX_MODEL_LENGTH]
  end

  # Rebuild a caller-/provider-owned structure into fresh, result-owned objects so
  # deep_freeze can never freeze anything the caller still holds a reference to.
  def deep_copy(value)
    case value
    when Hash then value.each_with_object({}) { |(k, v), copy| copy[deep_copy(k)] = deep_copy(v) }
    when Array then value.map { |item| deep_copy(item) }
    when String then value.dup
    else value
    end
  end

  # Freeze copied hash KEYS as well as values so a deep-copied result is fully immutable
  # (the keys are result-owned copies from deep_copy, never the caller's originals).
  def deep_freeze(value)
    case value
    when Hash then value.each_pair { |key, child| freeze_entry(key, child) }
    when Array then value.each { |child| deep_freeze(child) }
    end
    value.freeze
  end

  def freeze_entry(key, child)
    key.freeze
    deep_freeze(child)
  end
end
