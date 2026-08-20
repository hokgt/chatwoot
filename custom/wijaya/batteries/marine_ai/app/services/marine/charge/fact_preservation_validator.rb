# Phase 5 — semantic gate for contextual FAQ wording. A contextual candidate is
# untrusted, so it is only delivered when a SEPARATE LLM call proves it preserves the
# approved answer's facts. The approved answer is the ONLY factual source; the exact
# candidate is the text that would be delivered. The validator requests strict
# machine-readable JSON and fails closed: it accepts ONLY a complete, exact, all-true
# verdict and rejects blank/fenced/prose-wrapped/malformed JSON, the wrong top-level
# type, missing/extra/duplicate keys, non-boolean or false/uncertain values, and any LLM
# error/exception/unconfigured state. Malformed output is never repaired.
class Marine::Charge::FactPreservationValidator
  # Every verdict field must be present, boolean, and true for the candidate to pass.
  # Conversational framing/greeting is explicitly NOT a factual claim (see SYSTEM_PROMPT).
  REQUIRED_KEYS = %w[all_facts_preserved no_unsupported_facts_added no_contradiction meaning_equivalent certain].freeze

  SYSTEM_PROMPT = <<~PROMPT.strip
    You verify whether a Candidate Reply preserves the facts of an Approved Answer.
    The Approved Answer is the ONLY source of truth; compare the Candidate Reply against it alone.
    Conversational framing, acknowledgements, or greetings in the candidate are acceptable and must NOT be counted as added facts.
    Respond with ONLY a JSON object — no markdown, no code fences, no prose — containing exactly these boolean fields:
    "all_facts_preserved": every material fact in the Approved Answer appears in the candidate with none omitted.
    "no_unsupported_facts_added": the candidate introduces no factual claim absent from the Approved Answer.
    "no_contradiction": the candidate contradicts nothing in the Approved Answer.
    "meaning_equivalent": the candidate is factually entailed by and equivalent to the Approved Answer.
    "certain": you are certain of this judgement.
    Set any field to false whenever it does not clearly hold.
  PROMPT

  def initialize(account: nil)
    @account = account
  end

  # Returns true ONLY when the LLM returns a complete all-true verdict; false on every
  # failure or uncertainty. Never raises, never logs the approved answer or candidate.
  def valid?(approved_answer:, candidate:)
    service = Marine::Llm::BaseService.new(account: @account)
    return false unless service.configured?

    result = service.chat(messages: [{ role: 'user', content: user_prompt(approved_answer, candidate) }], system: SYSTEM_PROMPT)
    return false unless result[:ok] && result[:message].present?

    accepted?(result[:message])
  rescue StandardError
    false
  end

  private

  def accepted?(raw)
    # allow_duplicate_key: false makes the parser itself raise JSON::ParserError on a
    # repeated key instead of silently keeping the last value, so an ambiguous verdict
    # (e.g. a field stated both false and true) is treated as malformed rather than
    # slipping through. A custom object_class cannot do this: the parser deduplicates
    # keys internally before it ever assigns them to the object, so an overridden []=
    # never sees the duplicate. The default object_class keeps the exact top-level type
    # check below (a non-object top level such as an array or bare boolean is not a Hash).
    parsed = JSON.parse(raw, allow_duplicate_key: false)
    return false unless parsed.is_a?(Hash)
    return false unless parsed.keys.sort == REQUIRED_KEYS.sort

    REQUIRED_KEYS.all? { |key| parsed[key] == true }
  rescue JSON::ParserError
    false
  end

  def user_prompt(approved_answer, candidate)
    "Approved Answer:\n#{approved_answer}\n\nCandidate Reply:\n#{candidate}"
  end
end
