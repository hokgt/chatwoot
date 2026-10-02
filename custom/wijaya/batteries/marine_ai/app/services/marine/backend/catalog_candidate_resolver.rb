# Phase 2A (PRICE-ONLY shadow bridge) — the closed resolver seam between the untrusted JEV
# CandidatePlan path and the Backend Authority. It turns the bounded current trigger plus the
# read-only product-flow snapshot into a single deep-frozen, closed Result describing the EXACT
# catalog identity (family/child) the turn can be grounded on — and NOTHING else. It is pure glue
# over the existing exact-catalog semantics: it NEVER calls the private recovery methods of
# Marine::Catalog::ProductQueryOrchestrator, performs no provider call, writes no state, and emits
# no raw customer text, DB row, product list, or alias.
#
# The status is an EXACT catalog-lookup outcome only — it never claims semantic knowledge of
# whether the customer "mentioned a product". `no_catalog_match` means the exact DB lookup found no
# match; it is NOT proof that no product was named. Because an exact-catalog span cannot tell
# "no product mention" apart from "an unknown/out-of-catalog product", the active flow state is
# NEVER used as the sole family authority for a fact/price range (see the precedence below).
#
# Precedence (grounded in ProductQueryOrchestrator#family_decision / #resolved_variant_code):
#   1. An EXACT current-turn family identity is primary. A current family DIFFERENT from the state
#      is a switch (the stale saved variant is NEVER reused). The same current family as the active
#      state may reuse a REVALIDATED saved child ONLY when no current child candidate resolves. A
#      current exact child wins over a saved variant; an AMBIGUOUS exact child identity never falls
#      back to a saved variant/range.
#   2. With no current family, the active state family may be used ONLY when a current exact
#      child-code resolves under the REVALIDATED state family (bare exact variant-code continuation).
#   3. With neither a current exact family nor a current exact child-under-state, the Result is
#      `no_catalog_match` / `candidate_context_insufficient`. The state is never sole family
#      authority and never produces a state-only range/fact. An unknown product name and ordinary
#      non-matching prose are intentionally indistinguishable here (no second classifier) — both
#      preserve legacy.
#   4. Ambiguous/duplicate exact catalog identities fail closed to `ambiguous`; a repository outage
#      to `unavailable`. An exact DB no-match is NOT "invalid".
class Marine::Backend::CatalogCandidateResolver
  Schema = Marine::Decision::Schema

  # Bounded candidate generation: at most MAX_CANDIDATES distinct candidates, each at most
  # MAX_CANDIDATE_BYTES bytes — grounded in the candidate-plan schema bounds so the resolver and the
  # plan contract can never drift. Neither bound can produce a false pick. Count overflow is NEVER
  # truncated: once the complete allowed candidate set would exceed MAX_CANDIDATES the resolver fails
  # closed to candidate_context_insufficient rather than resolve from a partial set. A value over
  # MAX_CANDIDATE_BYTES is DROPPED, never prefix-sliced into a different identifier, and is anyway
  # unmatchable because the resolver and the batched repositories enforce the SAME 120-byte structural
  # bound — so an oversized value could never match a row even if it were carried.
  MAX_CANDIDATES = Schema::MAX_RAW_ARRAY            # 32
  MAX_CANDIDATE_BYTES = Schema::MAX_RAW_CANDIDATE_LENGTH # 120

  STATUS_EXACT_FAMILY = :exact_family
  STATUS_EXACT_CHILD = :exact_child
  STATUS_AMBIGUOUS = :ambiguous
  STATUS_NO_CATALOG_MATCH = :no_catalog_match
  STATUS_UNAVAILABLE = :unavailable

  SOURCE_CURRENT_TURN = :current_turn
  SOURCE_FLOW_STATE = :flow_state
  SOURCE_NONE = :none

  REASON_ACCEPTED = :accepted
  REASON_FAMILY_AMBIGUOUS = :family_ambiguous
  REASON_VARIANT_AMBIGUOUS = :variant_ambiguous
  REASON_CANDIDATE_CONTEXT_INSUFFICIENT = :candidate_context_insufficient
  REASON_CATALOG_UNAVAILABLE = :catalog_unavailable

  FLOW_STATUS_ACTIVE = Marine::Catalog::ProductFlowStateStore::STATUS_ACTIVE

  # Closed, deep-frozen resolver outcome. family_name is a bounded row-derived display token used
  # ONLY as a trusted language token — never a final fact without planner revalidation.
  Result = Struct.new(:status, :source, :family_code, :family_name, :child_code, :reason, keyword_init: true)

  def initialize(family_repository: nil, variant_repository: nil)
    @family_repository = family_repository || Marine::Catalog::ProductFamilyRepository.new
    @variant_repository = variant_repository || Marine::Catalog::VariantRepository.new
  end

  # trigger:    the bounded current customer turn (String).
  # flow_state: the read-only ProductFlowStateStore#current_for_planning snapshot (string-keyed
  #             Hash) or nil. Only an ACTIVE flow with a validated family is ever consulted.
  def call(trigger:, flow_state:)
    candidates = bounded_candidates(trigger)
    # blank (nil => the complete allowed candidate set would exceed MAX_CANDIDATES, or empty => blank
    # trigger): fail closed to candidate_context_insufficient rather than resolve from a truncated set.
    return no_match if candidates.blank?

    state = usable_state(flow_state)
    family = @family_repository.resolve_exact_any(candidates)
    return unavailable if family[:status] == :unavailable
    return ambiguous_family if family[:status] == :ambiguous

    current = accepted_family(family, candidates, trigger)
    current ? resolve_with_current_family(current, candidates, state) : resolve_with_state_only(candidates, state)
  end

  private

  attr_reader :family_repository, :variant_repository

  # A current exact family resolved from the trigger. A child wins when present; an ambiguous child
  # fails closed; otherwise a revalidated saved child (same family) continues, else a family-only
  # (range) outcome. A switch (current family differs from state) never reuses the saved variant —
  # it simply never reaches the saved-child branch because the family differs.
  def resolve_with_current_family(current, candidates, state)
    child = variant_repository.resolve_child_any(current[:code], candidates)
    return unavailable if child[:status] == :unavailable
    return ambiguous_variant(current, SOURCE_CURRENT_TURN) if child[:status] == :ambiguous
    return exact_child(current, child[:code], SOURCE_CURRENT_TURN) if child[:status] == :resolved

    saved = reuse_saved_child(current, state)
    saved || exact_family(current, SOURCE_CURRENT_TURN)
  end

  # Reuse the active flow's saved child ONLY when the current family IS the active state family and
  # a saved variant revalidates as an exact active child under it (no current child candidate
  # resolved). Returns an exact_child Result sourced from flow_state, or nil to fall through to the
  # family-only range. A saved variant that no longer revalidates (:missing) is NOT a conflict here
  # (there was no current child candidate), so it falls through rather than clarifying — but an
  # AMBIGUOUS saved-child identity fails closed to variant_ambiguous and NEVER falls to the range.
  def reuse_saved_child(current, state)
    return nil unless state && state[:variant] && state[:family] == current[:code]

    revalidated = variant_repository.resolve_child_any(current[:code], [state[:variant]])
    return unavailable if revalidated[:status] == :unavailable
    return exact_child(current, revalidated[:code], SOURCE_FLOW_STATE) if revalidated[:status] == :resolved
    return ambiguous_variant(current, SOURCE_FLOW_STATE) if revalidated[:status] == :ambiguous

    nil
  end

  # No current exact family resolved. The active state family may continue ONLY when it revalidates
  # as an active template AND a current exact child resolves under it (bare variant-code
  # continuation). An AMBIGUOUS state-family identity fails closed to family_ambiguous; otherwise the
  # state is never sole family authority → candidate_context_insufficient.
  def resolve_with_state_only(candidates, state)
    return no_match unless state

    family = revalidated_state_family(state)
    return family if family.is_a?(Result) # unavailable / ambiguous / no_match terminal

    child_under_state(family, candidates)
  end

  # The revalidated active-state family as a { code:, name: } Hash, or a terminal Result when the
  # state family is unavailable (outage), ambiguous (fail closed), or no longer an exact active row.
  def revalidated_state_family(state)
    family = family_repository.resolve_exact_any([state[:family]])
    return unavailable if family[:status] == :unavailable
    return ambiguous_family if family[:status] == :ambiguous
    return no_match unless family[:status] == :resolved && family[:code] == state[:family]

    { code: family[:code], name: family[:name] }
  end

  # A current exact child under the revalidated state family continues (bare variant-code); an
  # ambiguous child fails closed; anything else is candidate_context_insufficient.
  def child_under_state(family, candidates)
    child = variant_repository.resolve_child_any(family[:code], candidates)
    return unavailable if child[:status] == :unavailable
    return exact_child(family, child[:code], SOURCE_FLOW_STATE) if child[:status] == :resolved
    return ambiguous_variant(family, SOURCE_FLOW_STATE) if child[:status] == :ambiguous

    no_match
  end

  # The resolved current family after the one-token display-name collision guard: a code match is
  # always authoritative; a case-insensitive exact NAME match is authoritative only when the matched
  # candidate is name-eligible (multi-token OR the whole normalized turn), so an ordinary single word
  # that merely equals a one-word family name in a longer sentence never resolves a family. Returns
  # { code:, name: } or nil (reject → treat as no current family).
  def accepted_family(family, candidates, trigger)
    return nil unless family[:status] == :resolved

    code = family[:code].to_s
    return { code: family[:code], name: family[:name] } if candidates.include?(code)

    matched = candidates.find { |candidate| candidate.casecmp?(family[:name].to_s) }
    return nil if matched.nil?

    name_eligible?(matched, trigger) ? { code: family[:code], name: family[:name] } : nil
  end

  # A name match is authoritative only from a multi-token candidate or one equal to the whole
  # normalized turn — never a lone embedded single word.
  def name_eligible?(candidate, trigger)
    candidate.include?(' ') || candidate.casecmp?(trigger.to_s.strip)
  end

  # Deterministic, bounded candidate generation with EXPLICIT overflow detection. Order:
  #   (1) the full trimmed trigger;
  #   (2) individual tokens in reading order (punctuation preserved) so a short exact code at the end
  #       of a long turn is never starved by spans;
  #   (3) multi-token spans longest-first (original order within a length).
  # Oversized (> MAX_CANDIDATE_BYTES) candidates are DROPPED — never prefix-truncated into a different
  # identifier. Returns [] for a blank trigger and nil when the COMPLETE allowed candidate set would
  # exceed MAX_CANDIDATES: the resolver then fails closed rather than resolve from a truncated set
  # (an omitted exact identity could otherwise flip family-vs-child or which family wins).
  def bounded_candidates(trigger)
    text = trigger.to_s.strip
    return [] if text.empty?

    tokens = text.split(/\s+/)
    base = within_bytes([text] + tokens).uniq
    # If the full trigger + tokens alone already exceed the cap, stop immediately (incomplete).
    return nil if base.length > MAX_CANDIDATES

    add_spans(base, tokens)
  end

  # Append multi-token spans (longest-first, original order within a length), skipping oversized and
  # duplicate spans. Returns nil (incomplete) at the FIRST unique span beyond MAX_CANDIDATES so a
  # truncated span set can never yield a false family/child pick; otherwise the full candidate array.
  def add_spans(base, tokens)
    result = base.dup
    tokens.length.downto(2) do |span_length|
      (0..(tokens.length - span_length)).each do |start|
        span = tokens[start, span_length].join(' ')
        next if span.bytesize > MAX_CANDIDATE_BYTES || result.include?(span)
        return nil if result.length >= MAX_CANDIDATES

        result << span
      end
    end
    result
  end

  # The subset of candidates within the byte bound (oversized candidates are dropped, never sliced).
  def within_bytes(values)
    values.reject(&:empty?).select { |value| value.bytesize <= MAX_CANDIDATE_BYTES }
  end

  # The usable active-flow family/variant, or nil. current_for_planning already downgrades an
  # elapsed ACTIVE flow to 'expired', so only a genuinely active flow with a validated family is
  # consulted; the variant is nil unless a nonblank saved child is present.
  def usable_state(flow_state)
    return nil unless flow_state.is_a?(Hash)

    flow = flow_state.transform_keys(&:to_s)
    return nil unless flow['status'] == FLOW_STATUS_ACTIVE

    family = flow['validated_family'].to_s.strip
    return nil if family.empty?

    { family: family, variant: flow['validated_variant'].to_s.strip.presence }
  end

  def exact_child(family, child_code, source)
    build(status: STATUS_EXACT_CHILD, source: source, reason: REASON_ACCEPTED, family: family, child_code: child_code)
  end

  def exact_family(family, source)
    build(status: STATUS_EXACT_FAMILY, source: source, reason: REASON_ACCEPTED, family: family)
  end

  def ambiguous_family
    build(status: STATUS_AMBIGUOUS, source: SOURCE_NONE, reason: REASON_FAMILY_AMBIGUOUS)
  end

  def ambiguous_variant(family, source)
    build(status: STATUS_AMBIGUOUS, source: source, reason: REASON_VARIANT_AMBIGUOUS, family: family)
  end

  def no_match
    build(status: STATUS_NO_CATALOG_MATCH, source: SOURCE_NONE, reason: REASON_CANDIDATE_CONTEXT_INSUFFICIENT)
  end

  def unavailable
    build(status: STATUS_UNAVAILABLE, source: SOURCE_NONE, reason: REASON_CATALOG_UNAVAILABLE)
  end

  # Build a deep-frozen Result: every carried String is frozen so a caller can never mutate it.
  # `family` is an optional { code:, name: } Hash sourced from a resolved catalog row.
  def build(status:, source:, reason:, family: nil, child_code: nil)
    Result.new(
      status: status, source: source, reason: reason,
      family_code: freeze_string(family && family[:code]),
      family_name: freeze_string(family && family[:name]),
      child_code: freeze_string(child_code)
    ).freeze
  end

  def freeze_string(value)
    value.is_a?(String) ? value.dup.freeze : value
  end
end
