# Fase 3A-1 (isolated / mock-only) — persona / role gate for the Model 2 generated wording
# path. Marine speaks AS the "Marine Sales & Customer Service" assistant; it must never deflect
# the customer to "contact the sales team" (the approved handoff wording is "we will forward
# this to our team", handled by the deterministic handoff path — not a self-deflection).
#
# This holds the narrowly-approved persona contract the checklist permits: the sales-team
# self-deflection block PLUS an explicit role-override / non-Marine-identity block. Both stay as
# small and generic as possible (narrow deterministic patterns, no broad product/business phrase
# list — broader factual equivalence is the injected semantic verifier's job). It runs on the
# untrusted generated candidate only — no provider, no DB, no state, no runtime wiring — and never
# raises: any failure returns a closed rejection so the caller falls back safely.
class Marine::Backend::PersonaValidator
  # Self-deflection to a sales team, in the two languages the approved contract covers. These
  # match the "contact/hubungi ... (sales|penjualan)" deflection ONLY; the legitimate
  # "forward to our team" handoff wording is deliberately not matched.
  SELF_DEFLECTION_PATTERNS = [
    /hubungi\s+(?:tim\s+)?(?:sales|penjualan)/i,
    /kontak\s+(?:tim\s+)?(?:sales|penjualan)/i,
    /contact\s+(?:our\s+|the\s+)?sales(?:\s+team)?/i,
    /reach\s+out\s+to\s+(?:our\s+|the\s+)?sales(?:\s+team)?/i
  ].freeze

  # Explicit role override / non-Marine identity: unambiguous model/provider brand tokens, a
  # "language model" self-description, an "I am an AI/chatbot" role break, an explicit "I am not
  # Marine", or a provider attribution (EN + ID). Narrow and deterministic — no product/business
  # phrase list.
  NON_MARINE_IDENTITY_PATTERNS = [
    /\bchat\s*gpt\b/i,
    /\bopen\s*ai\b/i,
    /\bgpt[\s-]?[0-9]/i,
    /\b(?:a\s+)?(?:large\s+)?language\s+model\b/i,
    /\bmodel\s+bahasa\b/i,
    /\bI(?:'m| am)\s+(?:an?\s+)?(?:ai|artificial intelligence|chatbot)\b/i,
    /\bsaya\s+(?:adalah\s+)?(?:sebuah\s+)?(?:ai|chatbot|kecerdasan buatan)\b/i,
    /\bI\s+am\s+not\s+Marine\b/i,
    /\bsaya\s+bukan\s+Marine\b/i,
    /\b(?:developed|trained|created|made|built|powered)\s+by\s+(?:openai|google|anthropic|microsoft|meta)\b/i,
    /\b(?:dikembangkan|dibuat|dilatih|ditenagai)\s+oleh\s+(?:openai|google|anthropic|microsoft|meta)\b/i
  ].freeze

  Result = Struct.new(:ok, :reason, keyword_init: true) do
    def ok? = ok == true
  end

  def call(candidate:) # rubocop:disable Metrics/CyclomaticComplexity -- a flat sequence of independent persona guards
    return reject(:malformed_candidate) unless candidate.is_a?(String) && candidate.valid_encoding?
    return reject(:self_deflection) if SELF_DEFLECTION_PATTERNS.any? { |pattern| candidate.match?(pattern) }
    return reject(:identity_override) if NON_MARINE_IDENTITY_PATTERNS.any? { |pattern| candidate.match?(pattern) }

    Result.new(ok: true, reason: nil).freeze
  rescue StandardError
    reject(:error)
  end

  private

  def reject(reason)
    Result.new(ok: false, reason: reason).freeze
  end
end
