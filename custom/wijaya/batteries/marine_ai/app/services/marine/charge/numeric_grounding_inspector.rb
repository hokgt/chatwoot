# Local, model-free numeric-grounding backstop for generated RAG (llm_rag) output. General RAG is
# GROUNDED generation — Marine's RAG policy tells the model to answer ONLY from the approved
# Knowledge Base — so any MATERIAL number a generated reply states must trace to that approved
# context. A material numeric token the approved grounding does not contain is an INVENTED numeric
# fact (a fabricated price/amount, MOQ, date, phone, ...), so the caller drops the reply and falls
# CLOSED to its existing safe fallback (handoff / raw approved answer) instead of delivering an
# ungrounded number.
#
# Paired with the monetary/rate SHAPE guard (Marine::Charge::PriceClaimInspector), this closes the
# residual bare-amount hole that shape alone cannot see: a bare invented price with no currency
# token and no rate unit (e.g. "Harganya 28500") is rejected here because 28500 is absent from the
# approved context — with no per-language price-word list and no hardcoded amount. Together they
# keep an invented product price — bare or currency-tagged — from ever escaping general RAG.
#
# It makes NO LLM/network call. A number is MATERIAL when it has at least MATERIAL_MIN_DIGITS
# significant digits (grouping separators stripped), so trivial 1-2 digit numbers (a day of month,
# a small count, a short percentage, a list ordinal) are never grounding-checked and never cause a
# false rejection, while larger fact-like numbers (prices, years, MOQ, phone segments) are. Both
# sides are reduced to canonical digit strings before comparison, so display grouping ("28.500" vs
# "28500") never masks a legitimate match. Empty/absent grounding is never a pass for a material
# number: an ungrounded material number always fails CLOSED. Grounded numbers (dates, product /
# variant codes, telephone numbers, addresses, approved quantities that appear in the approved
# context) pass through untouched.
class Marine::Charge::NumericGroundingInspector
  # Minimum significant digit count for a number to be treated as a material, grounding-checked
  # fact. Below this, a number is incidental (a day, a small count, a short ordinal) and skipped.
  MATERIAL_MIN_DIGITS = 3

  # A number possibly written with internal grouping/decimal separators, e.g. 28.500, 12,500, 123.
  NUMERIC_TOKEN = /\d[\d.,]*\d|\d/

  # True when the reply contains any MATERIAL numeric token whose canonical digits are absent from
  # the approved grounding context. Blank reply is never a claim.
  def ungrounded_numeric_claim?(reply:, grounding:)
    text = reply.to_s
    return false if text.blank?

    grounded = grounded_digit_tokens(grounding)
    material_digit_tokens(text).any? { |digits| grounded.exclude?(digits) }
  end

  private

  # The set of every canonical digit string present in the approved grounding, so a reply number is
  # grounded when its digits appear anywhere in the approved context regardless of grouping.
  def grounded_digit_tokens(grounding)
    grounding.to_s.scan(NUMERIC_TOKEN).map { |token| token.gsub(/\D/, '') }.reject(&:blank?).to_set
  end

  # The canonical digit strings of every MATERIAL number in the reply (>= MATERIAL_MIN_DIGITS digits
  # after stripping grouping separators); shorter, incidental numbers are skipped.
  def material_digit_tokens(text)
    text.scan(NUMERIC_TOKEN)
        .map { |token| token.gsub(/\D/, '') }
        .select { |digits| digits.length >= MATERIAL_MIN_DIGITS }
  end
end
