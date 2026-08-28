# Phase 5 — semantic gate for contextual FAQ wording. A contextual candidate is
# untrusted, so it is only delivered when a SEPARATE LLM call proves it preserves the
# approved answer's facts. The approved answer is the ONLY factual source; the exact
# candidate is the text that would be delivered. The validator asks the provider to enforce a
# strict machine-readable envelope (VERDICT_SCHEMA) — a bare object whose single "verdict" field
# carries the five-field verdict as a JSON string — and fails closed regardless of whether that
# enforcement holds: it accepts ONLY a complete, exact, all-true verdict and rejects
# blank/fenced/prose-wrapped/malformed JSON, the wrong top-level type, missing/extra/duplicate
# keys, non-boolean or false/uncertain values, and any LLM error/exception/unconfigured state.
# The verdict travels as a string specifically so RubyLLM's eager JSON parse (which silently
# deduplicates keys) cannot collapse a repeated verdict key before accepted? strict-parses it.
# Malformed output is never repaired.
class Marine::Charge::FactPreservationValidator
  # Every verdict field must be present, boolean, and true for the candidate to pass.
  # Conversational framing/greeting is explicitly NOT a factual claim (see SYSTEM_PROMPT).
  REQUIRED_KEYS = %w[all_facts_preserved no_unsupported_facts_added no_contradiction meaning_equivalent certain].freeze

  # Provider-enforced structured-output envelope (RubyLLM #with_schema format). RubyLLM eagerly
  # JSON.parse's a structured reply into a Hash *before* Marine::Llm::BaseService can see the raw
  # bytes, and that parse silently collapses duplicate keys (last value wins). Were the five
  # booleans top-level fields, an ambiguous verdict repeating a key (e.g. all_facts_preserved
  # false then true) would be deduplicated away before accepted?'s allow_duplicate_key: false
  # ever ran, defeating the safeguard. So the provider is constrained to a bare object with a
  # SINGLE string field, "verdict", whose value is the five-field verdict object encoded as JSON
  # text. RubyLLM parses only the envelope; it never descends into the string, so the inner bytes
  # (duplicate keys intact) reach accepted? verbatim. strict: true + additionalProperties: false
  # keeps the envelope a clean bare object — the structural fix for the fenced/prose verdict that
  # caused the Gate F failure. This is a REQUEST-side control only; accepted? still independently
  # strict-parses the inner verdict and fails closed on anything non-conforming (a provider that
  # ignores or lacks structured output degrades to a fail-closed rejection, still safe).
  VERDICT_SCHEMA = {
    name: 'fact_preservation_verdict',
    strict: true,
    schema: {
      type: 'object',
      additionalProperties: false,
      required: %w[verdict],
      properties: { 'verdict' => { type: 'string' } }
    }
  }.freeze

  SYSTEM_PROMPT = <<~PROMPT.strip
    You verify whether a Candidate Reply preserves the facts of an Approved Answer.
    The Approved Answer is the ONLY source of truth; compare the Candidate Reply against it alone.
    Conversational framing, acknowledgements, or greetings in the candidate are acceptable and must NOT be counted as added facts.
    Respond with ONLY a JSON object of the form {"verdict": "..."} — no markdown, no code fences, no prose.
    The value of the "verdict" field MUST be a STRING whose contents are a JSON object with exactly these boolean fields:
    "all_facts_preserved": every material fact in the Approved Answer appears in the candidate with none omitted.
    "no_unsupported_facts_added": the candidate introduces no factual claim absent from the Approved Answer.
    "no_contradiction": the candidate contradicts nothing in the Approved Answer.
    "meaning_equivalent": the candidate is factually entailed by and equivalent to the Approved Answer.
    "certain": you are certain of this judgement.
    Set any field to false whenever it does not clearly hold.
    Embed the inner verdict object as a properly escaped JSON string, and add no field to either object beyond those listed.
  PROMPT

  def initialize(account: nil)
    @account = account
  end

  # Returns true ONLY when the LLM returns a complete all-true verdict; false on every
  # failure or uncertainty. Never raises, never logs the approved answer or candidate.
  #
  # fact_focus: an OPTIONAL caller-supplied clarification of what the material fact IS for this
  # particular answer (e.g. a binary stock-availability reply's sole fact is one in/out boolean).
  # It is appended to SYSTEM_PROMPT so the judge anchors materiality and stops counting benign
  # same-meaning rephrasings as added/unequal facts. It NEVER relaxes acceptance: the five
  # fail-closed booleans and the strict envelope parse below are unchanged, and a blank/absent
  # focus leaves the prompt byte-identical to the base rubric (the FAQ/handoff/localizer path).
  def valid?(approved_answer:, candidate:, fact_focus: nil)
    service = Marine::Llm::BaseService.new(account: @account)
    return false unless service.configured?

    # schema: VERDICT_SCHEMA asks the provider to enforce a bare { "verdict": "<json>" } envelope
    # (the structural fix for a fenced/prose-wrapped/unparseable verdict) whose string value carries
    # the verdict so RubyLLM's eager parse cannot deduplicate its keys. temperature 0.0 is a
    # complementary stability control that removes sampling variance in the judgement. Neither
    # relaxes acceptance: accepted? still strict-parses the returned text and fails closed on any
    # non-all-true/malformed verdict, so a provider that ignores or cannot enforce the schema is
    # still rejected.
    result = service.chat(
      messages: [{ role: 'user', content: user_prompt(approved_answer, candidate) }],
      system: system_prompt(fact_focus),
      temperature: 0.0,
      schema: VERDICT_SCHEMA
    )
    return false unless result[:ok] && result[:message].present?

    accepted?(result[:message])
  rescue StandardError
    false
  end

  private

  # The base rubric, plus the caller's optional materiality clarification when present. A
  # blank/absent focus returns the base rubric unchanged (no new fact, no relaxed rule).
  def system_prompt(fact_focus)
    return SYSTEM_PROMPT if fact_focus.blank?

    "#{SYSTEM_PROMPT}\n\n#{fact_focus.strip}"
  end

  def accepted?(raw)
    # `raw` is the { "verdict": "<json>" } envelope. RubyLLM has already parsed (and, at the
    # envelope level, deduplicated) that outer object before BaseService reserialized it, so the
    # SAFETY-CRITICAL parse is the INNER one: the verdict object travels as an opaque string value
    # that RubyLLM never descends into, so its bytes — duplicate keys included — survive verbatim
    # to here. allow_duplicate_key: false makes JSON.parse itself raise JSON::ParserError on a
    # repeated key instead of silently keeping the last value, so an ambiguous verdict (a field
    # stated both false and true) is treated as malformed rather than slipping through. A custom
    # object_class cannot do this: the parser deduplicates keys before it ever assigns them, so an
    # overridden []= never sees the duplicate. Everything fails closed: a wrong envelope shape, a
    # non-string verdict, a wrong inner top-level type, a missing/extra key, or any unparseable
    # text is rejected. It is applied to the envelope parse too, so a duplicate "verdict" key that
    # RubyLLM did not collapse (an unparsed, passed-through reply) is likewise refused.
    envelope = JSON.parse(raw, allow_duplicate_key: false)
    return false unless envelope.is_a?(Hash) && envelope.keys == %w[verdict]
    return false unless envelope['verdict'].is_a?(String)

    all_true_verdict?(envelope['verdict'])
  rescue JSON::ParserError
    false
  end

  # Strict, duplicate-key-sensitive parse of the inner verdict string (JSON::ParserError propagates
  # to accepted?'s rescue). Passes only for a bare object holding exactly the five required keys, all
  # boolean true.
  def all_true_verdict?(verdict_json)
    parsed = JSON.parse(verdict_json, allow_duplicate_key: false)
    return false unless parsed.is_a?(Hash)
    return false unless parsed.keys.sort == REQUIRED_KEYS.sort

    REQUIRED_KEYS.all? { |key| parsed[key] == true }
  end

  def user_prompt(approved_answer, candidate)
    "Approved Answer:\n#{approved_answer}\n\nCandidate Reply:\n#{candidate}"
  end
end
