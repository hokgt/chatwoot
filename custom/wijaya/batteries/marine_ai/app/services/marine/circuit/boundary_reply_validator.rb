# Independent, model-free STRUCTURAL safety gate for a generated domain-boundary refusal, run as a
# SEPARATE pass from the composer so the refusal is never self-certified by the model that wrote it.
# It makes NO LLM / network call, so a denied Playground turn stays comfortably inside the controller's
# fixed 12-second budget: the only provider latency on a denied turn is the classifier's single call
# plus the composer's single generation — this gate adds none, and never triggers an HTTP timeout.
#
# Why a local check is a meaningful separate boundary here: the composer is given NO raw customer
# request, conversation history, assembled system prompt, assistant instructions/guardrails, or
# Knowledge Base — so there is no attacker-supplied or internal material for it to echo, and its only
# realistic failure mode is an unconstrained/garbled generation (blank, over-long, multi-paragraph, or
# code/JSON-shaped output that has drifted away from a plain refusal). This gate independently confirms
# the candidate is a short, well-formed, single customer-facing reply before delivery and rejects those
# degenerate shapes. It enforces NO attack-keyword blacklist — the semantic judgement stays with the
# classifier. Any failure or uncertainty returns false so the guard falls closed to its ONE safe
# fallback. Never raises, never logs the candidate.
class Marine::Circuit::BoundaryReplyValidator
  # A safe boundary refusal is one or two short sentences of prose. These bounds reject the degenerate
  # shapes of an unconstrained generation without inspecting meaning or matching any phrase list.
  MAX_CHARS = 600
  MAX_SENTENCES = 4
  MAX_NONBLANK_LINES = 3

  # A valid boundary refusal must visibly redirect the customer to Textilindo — the ONE thing every
  # safe refusal (including the guard's SAFE_FALLBACK) has in common. This is a positive OUTPUT
  # contract (the brand name must be present), not an attack-keyword blacklist and not a refusal-phrase
  # dictionary: it asserts the candidate points the customer back to Textilindo rather than silently
  # declining or drifting off into the declined task. A candidate missing it fails closed to the
  # guard's safe fallback (which itself names Textilindo). Case-insensitive literal brand token.
  REQUIRED_BRAND = 'textilindo'.freeze

  # category / language are accepted for signature parity with the guard and the prior contract; a
  # local structural gate does not need them. Returns true ONLY for a short, single, prose-shaped
  # candidate; false on blank / invalid-encoding / over-long / multi-line / code-or-JSON-shaped input.
  def valid?(candidate:, category: nil, language: nil) # rubocop:disable Lint/UnusedMethodArgument
    text = candidate.to_s
    return false unless text.valid_encoding?

    structurally_sound?(text.strip)
  rescue StandardError
    false
  end

  private

  # A short, single, prose-shaped refusal: non-blank, within the char/line/sentence bounds, and not a
  # code-fenced or whole-body JSON/array payload.
  def structurally_sound?(text)
    text.present? &&
      text.length <= MAX_CHARS &&
      redirects_to_brand?(text) &&
      !fenced_or_structured?(text) &&
      nonblank_line_count(text) <= MAX_NONBLANK_LINES &&
      sentence_count(text) <= MAX_SENTENCES
  end

  # The customer-facing redirect contract: the candidate must literally name Textilindo (any case).
  def redirects_to_brand?(text)
    text.downcase.include?(REQUIRED_BRAND)
  end

  # A code fence or a whole-body JSON/array signals the model emitted structured output or performed a
  # task rather than a plain refusal — reject it. Structural (delimiter shape), not a keyword match.
  def fenced_or_structured?(text)
    return true if text.include?('```')

    (text.start_with?('{') && text.end_with?('}')) ||
      (text.start_with?('[') && text.end_with?(']'))
  end

  def nonblank_line_count(text)
    text.lines.count { |line| line.strip.present? }
  end

  # Count sentence terminators (Latin and CJK); a candidate with no terminator is treated as one
  # sentence. A refusal with more than MAX_SENTENCES terminators is an over-long ramble.
  def sentence_count(text)
    count = text.scan(/[.!?。！？]+/).size
    count.zero? ? 1 : count
  end
end
