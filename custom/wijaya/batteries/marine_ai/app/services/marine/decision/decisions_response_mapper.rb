# Strict mapper from an OpenRouter Jev Decisions `answers` payload into an UNTRUSTED
# candidate hash for the battery-local Marine Decision Runner (Phase 2 / Stage 3 —
# ISOLATED, UNWIRED). Returns the raw candidate hash for the runner to intersect against
# capabilities and hand to CandidatePlan.normalize (the final authority), or nil on any
# violation.
#
# Jev Decisions returns ONLY typed primitives (verified against the official docs):
#   choice -> { type:'choice', choice:<key>, confidence:<0..1>, probabilities:{key=>0..1} }
#   noul   -> { type:'noul',   noul:<0..1 probability> }
# It NEVER generates free text, so slot_operations is ALWAYS [] and customer_language is
# ALWAYS nil for this mode — no value is ever derived by regex/token overlap/state copying.
#
# Trust boundary: the answer keys must be EXACTLY the scenario question plus the known
# intent questions (built by RequestBuilder); any unknown/missing/type-confused shape or a
# mixed/duplicate canonical key fails closed. Confidence levels are derived DETERMINISTIC-
# ALLY from the typed probabilities via documented thresholds; the provider's own prose or
# model name is never trusted. No I/O, settings read, or mutation happens here.
module Marine::Decision::DecisionsResponseMapper
  Schema = Marine::Decision::Schema
  Builder = Marine::Decision::RequestBuilder

  # Documented low/medium/high thresholds over the selected scenario probability, aligned
  # with the Stage 1 confidence semantics.
  CONFIDENCE_HIGH = 0.75
  CONFIDENCE_MEDIUM = 0.5
  # Conservative bar for treating a NOUL intent probability as "explicitly present".
  INTENT_THRESHOLD = 0.6

  module_function

  # answers: the bounded Decisions `answers` Hash. allowed_intents: the exact candidate
  # intents whose NOUL questions were asked (union of declared capabilities + unsupported).
  def map(answers, scenario_keys:, allowed_intents:)
    return nil unless valid_envelope?(answers, allowed_intents)

    scenario = scenario_answer(answers[Builder::SCENARIO_QUESTION_KEY], scenario_keys)
    return nil if scenario.nil?

    intents = intents(answers, allowed_intents)
    return nil if intents == :invalid # a malformed present NOUL answer fails the whole map closed

    {
      'schema_version' => Schema::SCHEMA_VERSION,
      'scenario_candidate' => { 'key' => scenario[:key], 'confidence' => confidence_level(scenario[:probability]) },
      'intents' => intents,
      'slot_operations' => [], # Jev cannot extract free text -> never a slot candidate.
      'customer_language' => nil, # Jev cannot extract free text -> never a language.
      'confidence' => confidence_level(scenario[:probability])
    }
  end

  # The answer envelope must be a String-keyed Hash (JSON-origin) whose keys are EXACTLY the
  # scenario question PLUS every intent question that was asked — no missing, unknown, or
  # duplicate key. A Symbol or mixed-key shape is rejected outright (never canonicalized), so
  # a Ruby symbol can never smuggle a second value past the boundary.
  def valid_envelope?(answers, allowed_intents)
    return false unless answers.is_a?(Hash) && answers.present?

    expected = [Builder::SCENARIO_QUESTION_KEY] + allowed_intents.map { |intent| "#{Builder::INTENT_QUESTION_PREFIX}#{intent}" }
    exact_string_keyed?(answers, expected)
  end

  # A valid CHOICE answer, matching the current official response shape: EXACTLY the String
  # keys type/choice/confidence/probabilities (no unknown/missing field). The selected key
  # must be one of the supplied keys; confidence must be present and finite in 0..1;
  # probabilities must be a String-keyed hash of finite 0..1 values keyed only by supplied
  # scenario keys, with the selected key present. Returns { key:, probability: } or nil.
  def scenario_answer(answer, scenario_keys)
    return nil unless exact_string_keyed?(answer, %w[type choice confidence probabilities])
    return nil unless answer['type'] == 'choice'

    key = answer['choice']
    return nil unless key.is_a?(String) && scenario_keys.include?(key)
    return nil unless probability?(answer['confidence'])
    return nil unless valid_probabilities?(answer['probabilities'], scenario_keys, key)

    { key: key.dup, probability: answer['probabilities'][key] }
  end

  # A String-keyed hash of finite-in-0..1 probabilities keyed only by supplied scenario keys,
  # with the selected key present. Probabilities for unreturned scenario keys are NOT required
  # (the official schema returns only scored keys); a Symbol/mixed key shape is rejected.
  def valid_probabilities?(probabilities, scenario_keys, selected)
    return false unless probabilities.is_a?(Hash)
    return false unless probabilities.keys.all?(String)
    return false unless probabilities.key?(selected)

    probabilities.all? { |key, value| scenario_keys.include?(key) && probability?(value) }
  end

  # Canonically-ordered, capped candidate intents whose NOUL probability clears the bar, or
  # the :invalid sentinel if any intent answer is malformed. valid_envelope? already required
  # a NOUL answer for EVERY asked intent, so a missing answer is impossible here; a nil answer
  # is still treated as :invalid defensively. The per-intent probabilities are retained only to
  # resolve the Schema mutual-exclusivity contract; they are never emitted.
  def intents(answers, allowed_intents)
    scored = {}
    allowed_intents.each do |intent|
      answer = answers["#{Builder::INTENT_QUESTION_PREFIX}#{intent}"]
      return :invalid unless valid_noul?(answer)

      scored[intent] = answer['noul'] if answer['noul'] >= INTENT_THRESHOLD
    end
    selected = resolve_mutually_exclusive(scored)
    Schema::INTENTS.select { |intent| selected.include?(intent) }.first(Schema::MAX_INTENTS).map(&:dup)
  end

  # Enforce the Schema mutually-exclusive contract over the above-threshold intents: within each
  # exclusive group at most ONE member may survive — the one with the strictly-higher NOUL
  # probability. An exact tie is genuinely ambiguous, so EVERY member of that group is dropped
  # (fail closed), never emitted together. Intents outside any group are untouched, so unrelated
  # multi-intent sets (e.g. price + stock) are fully preserved.
  def resolve_mutually_exclusive(scored)
    dropped = []
    Schema::MUTUALLY_EXCLUSIVE_INTENTS.each do |group|
      present = group.select { |intent| scored.key?(intent) }
      next if present.length < 2

      top = scored.values_at(*present).max
      winners = present.select { |intent| scored[intent] == top }
      dropped.concat(winners.length == 1 ? present - winners : present)
    end
    scored.keys - dropped
  end

  # A valid NOUL answer has EXACTLY the String keys type/noul (no unknown/missing/symbol/mixed
  # key), type 'noul', and a finite 0..1 probability.
  def valid_noul?(answer)
    exact_string_keyed?(answer, %w[type noul]) && answer['type'] == 'noul' && probability?(answer['noul'])
  end

  # A Hash whose keys are EXACTLY `allowed`, all String (JSON-origin) — no unknown, missing,
  # or duplicate key. Rejects any Symbol/mixed shape so the mapper only trusts JSON-parsed
  # String keys, never a Ruby-symbol smuggled second value.
  def exact_string_keyed?(value, allowed)
    return false unless value.is_a?(Hash)

    keys = value.keys
    return false unless keys.all?(String)

    keys.length == allowed.length && (keys - allowed).empty?
  end

  def confidence_level(probability)
    return 'high' if probability >= CONFIDENCE_HIGH
    return 'medium' if probability >= CONFIDENCE_MEDIUM

    'low'
  end

  # True only for a finite real Numeric in 0..1. Realistic JSON numerics (Integer/Float) are
  # accepted; NaN/Infinity/Complex/out-of-range are rejected. A malformed direct-Ruby numeric
  # whose comparison/finite check itself raises is caught here and treated as invalid, so a
  # direct mapper call never raises on a hostile numeric-shaped input.
  def probability?(value)
    return false unless value.is_a?(Numeric) && value.real?
    return false if value.respond_to?(:finite?) && !value.finite?

    value.between?(0, 1)
  rescue ArgumentError, TypeError, NoMethodError, RangeError
    false
  end
end
