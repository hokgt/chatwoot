require 'json'

# Strict parser for a chat/completions Decision transport payload (Phase 2 / Stage 3 —
# ISOLATED, UNWIRED). It returns a fully UNTRUSTED parsed candidate hash for the runner
# to intersect against capabilities and hand to CandidatePlan.normalize (the final
# authority), or nil on any violation.
#
#   Hash   -> structured RubyLLM output; returned as-is (its keys are already de-duplicated
#             in Ruby, so the normalizer revalidates structure).
#   String -> must be EXACTLY one JSON object: no code fences, no leading/trailing prose,
#             no trailing tokens, within a byte ceiling, valid encoding, and with NO
#             duplicate JSON keys at ANY depth (rejected by allow_duplicate_key: false —
#             a plain last-key-wins JSON.parse could let a smuggled second value win).
#
# This file performs no I/O, reads no settings, and mutates no input.
module Marine::Decision::ChatResponseParser
  # Conservative ceiling so a hostile/oversized reply is rejected before JSON.parse.
  MAX_BYTES = 100_000

  module_function

  # A Hash passes through; a String is strictly parsed; anything else -> nil (an
  # unsupported payload shape the runner folds to a safe unknown plan).
  def parse(payload)
    case payload
    when Hash then payload
    when String then parse_string(payload)
    end
  end

  def parse_string(text)
    return nil unless text.valid_encoding?

    stripped = text.strip
    return nil if stripped.empty? || stripped.bytesize > MAX_BYTES
    # Fail fast on code fences / leading prose: a JSON object must start with '{'.
    return nil unless stripped.start_with?('{')

    # allow_duplicate_key: false raises on a duplicate key at any depth; JSON.parse also
    # rejects any trailing tokens after the single object.
    parsed = JSON.parse(stripped, allow_duplicate_key: false)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError, EncodingError
    nil
  end
end
