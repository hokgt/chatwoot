# Local, model-free defense-in-depth guard for generated RAG output — the deterministic
# provenance boundary that keeps general RAG from ever becoming a source of a numeric product
# price. Numeric product pricing in Marine is DETERMINISTIC: it comes only from the catalog
# pricing path (PriceReplyComposer / PriceRangeReplyComposer, grounded on PriceDisplayFormatter).
# A generated (llm_rag) reply must never carry an invented monetary amount, so when one appears
# the caller drops the reply and falls CLOSED to its existing safe fallback (handoff / raw
# approved answer) instead of delivering a fabricated price.
#
# It makes NO LLM/network call — it is a purely local check. It fires on either explicit
# monetary/rate SHAPE — no currency token, product, amount, or per-language phrase is ever
# hardcoded:
#   * a configured currency token sitting directly next to a number, either order, e.g. "Rp 1.000",
#     "IDR2,000", "3000 IDR". The currency tokens are derived data-driven from the catalog's own
#     display policy (Marine::Catalog::PriceDisplayFormatter::CURRENCY_DISPLAY) — the raw currency
#     codes AND their per-locale display symbols — so if the display policy gains a currency this
#     guard picks it up;
#   * a bare unit-RATE amount — a number priced per a unit with NO currency token at all, e.g.
#     "28.500 per yard", "28500/yard". This is the price SHAPE itself; the rate connector ("per" as
#     a whole word, or a slash) must be directly followed by a letter, so a non-rate slash/word
#     ("24/7", a bare "per color" with no leading number) never trips it.
#
# Structural bias to avoid false positives: a flagged number must carry an explicit currency token
# or a directly-attached rate unit, so ordinary non-price numbers — dates, product / variant codes,
# telephone numbers, addresses, plain quantities / MOQ ("50 yard per color" is quantity-then-unit,
# not amount-per-unit) — are never flagged. A word boundary before the currency token / the "per"
# connector keeps substrings inside ordinary words (e.g. "sharp", "corp", "rpm", "superb") from
# tripping it. A detected claim fails CLOSED, never open. A bare invented amount with NEITHER shape
# (e.g. "Harganya 28500") is out of scope here by design and is caught by the complementary
# numeric-grounding guard (Marine::Charge::NumericGroundingInspector), which rejects any material
# number absent from the approved Knowledge Base context.
class Marine::Charge::PriceClaimInspector
  # The currency tokens the catalog's own display policy uses, downcased and deduped: the raw
  # currency codes (e.g. "idr") and every per-locale display symbol (e.g. "rp", "idr"). Sourced
  # from the single authoritative display map so the guard and the deterministic price renderer
  # never drift, with no product/amount/language hardcoding.
  def self.currency_tokens
    display = Marine::Catalog::PriceDisplayFormatter::CURRENCY_DISPLAY
    (display.keys + display.values.flat_map(&:values))
      .map { |token| token.to_s.strip.downcase }
      .reject(&:blank?)
      .uniq
  end

  def initialize(currency_tokens: self.class.currency_tokens)
    @currency_tokens = currency_tokens
  end

  # True when the reply states an explicit monetary/rate amount — a configured currency token
  # directly adjacent to a number (either order) OR a bare number priced per a unit. Blank reply is
  # never a claim; the rate shape needs no currency token, so an empty token set still flags a rate.
  def monetary_price_claim?(reply:)
    text = reply.to_s
    return false if text.blank?

    text.match?(matcher)
  end

  private

  # A number possibly rendered with grouping/decimal separators, e.g. 28.500, 12,500, 3000.
  NUMBER = /\d[\d.,]*/

  # A bare unit-RATE amount with NO currency token: a number priced per a unit — a slash directly
  # before a letter ("28500/yard") or the whole word "per" between the number and a unit letter
  # ("28.500 per yard"). The trailing letter requirement keeps "24/7" and a leading-number-less
  # "per color" from matching; the \b around "per" keeps it out of ordinary words.
  RATE = %r{#{NUMBER}\s*(?:/\s*\p{L}|\bper\b\s*\p{L})}i

  def matcher
    return RATE if @currency_tokens.empty?

    alternation = @currency_tokens.map { |token| Regexp.escape(token) }.join('|')
    # currency token then a number: "Rp 1.000", "IDR: 2,000", "Rp3000"
    before = /\b(?:#{alternation})\s*[:.\-]?\s*\d/i
    # a number then a currency token: "1.000 Rp", "3000 IDR"
    after = /#{NUMBER}\s*(?:#{alternation})\b/i
    Regexp.union(before, after, RATE)
  end
end
