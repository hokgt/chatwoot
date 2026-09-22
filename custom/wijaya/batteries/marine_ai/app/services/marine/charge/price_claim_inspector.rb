# Local, model-free defense-in-depth guard for generated RAG output — the deterministic
# provenance boundary that keeps general RAG from ever becoming a source of a numeric product
# price. Numeric product pricing in Marine is DETERMINISTIC: it comes only from the catalog
# pricing path (PriceReplyComposer / PriceRangeReplyComposer, grounded on PriceDisplayFormatter).
# A generated (llm_rag) reply must never carry an invented monetary amount, so when one appears
# the caller drops the reply and falls CLOSED to its existing safe fallback (handoff / raw
# approved answer) instead of delivering a fabricated price.
#
# It makes NO LLM/network call — it is a purely local check. The signal is intentionally NARROW:
# a configured currency token sitting directly next to a number (either order, e.g. "Rp 1.000",
# "IDR2,000", "3000 IDR"). The currency tokens are derived data-driven from the catalog's own
# display policy (Marine::Catalog::PriceDisplayFormatter::CURRENCY_DISPLAY) — the raw currency
# codes AND their per-locale display symbols — never a hardcoded product, amount, or per-language
# phrase list. If the catalog display policy gains a currency, this guard picks it up.
#
# Structural bias to avoid false positives: an explicit currency token must be adjacent to a
# number, so ordinary non-price numbers — dates, product / variant codes, telephone numbers,
# addresses, quantities / MOQ — carry no adjacent currency token and are never flagged. A word
# boundary before the currency token keeps substrings inside ordinary words (e.g. "sharp",
# "corp", "rpm") from tripping it. A detected claim fails CLOSED, never open.
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

  # True when the reply states an explicit monetary amount — a configured currency token directly
  # adjacent to a number, in either order. Blank reply or empty token set is never a claim.
  def monetary_price_claim?(reply:)
    text = reply.to_s
    return false if text.blank? || @currency_tokens.empty?

    text.match?(matcher)
  end

  private

  def matcher
    alternation = @currency_tokens.map { |token| Regexp.escape(token) }.join('|')
    # currency token then a number: "Rp 1.000", "IDR: 2,000", "Rp3000"
    before = /\b(?:#{alternation})\s*[:.\-]?\s*\d/i
    # a number then a currency token: "1.000 Rp", "3000 IDR"
    after = /\d[\d.,]*\s*(?:#{alternation})\b/i
    Regexp.union(before, after)
  end
end
