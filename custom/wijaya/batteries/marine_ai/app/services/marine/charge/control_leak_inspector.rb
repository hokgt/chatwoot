# Local, model-free confidentiality backstop for generated RAG output — defense in depth behind the
# semantic domain-boundary gate, in case classification ever misses a leak the model still emitted.
#
# Given the generated reply and the assembled INTERNAL control texts (the assistant's own
# instructions, guardrails, and response guidelines — never the approved Knowledge Base, whose answer
# text is legitimately quotable and is NOT treated as secret), it reports a leak only when a
# sufficiently long EXACT run of consecutive normalized word tokens from a control text reappears
# verbatim in the reply. It makes NO LLM/network call and never sends the control text anywhere; it
# is a purely local overlap check.
#
# Structural bias to avoid false positives: a run shorter than SHINGLE_SIZE can never match, so blank
# or short control texts, short replies, and ordinary domain words like "instruction", "system",
# "developer", "price", or "stock" are never flagged — only a long contiguous copy of the control
# WORDING trips it. A detected leak fails CLOSED (the caller drops the reply and hands off / returns
# its approved fallback), never open.
class Marine::Charge::ControlLeakInspector
  # Number of consecutive normalized tokens that must match verbatim to count as disclosure. Long
  # enough that incidental phrase overlap with an approved answer does not trip it.
  SHINGLE_SIZE = 8

  def initialize(shingle_size: SHINGLE_SIZE)
    @shingle_size = shingle_size
  end

  # True when any control text shares a run of @shingle_size consecutive normalized tokens with the
  # reply. Blank reply or blank control set is never a leak.
  def leak?(reply:, control_texts:)
    reply_shingles = shingles(reply)
    return false if reply_shingles.empty?

    Array(control_texts).any? do |control|
      shingles(control).intersect?(reply_shingles)
    end
  end

  private

  def shingles(text)
    tokens = tokenize(text)
    return Set.new if tokens.size < @shingle_size

    tokens.each_cons(@shingle_size).to_set { |run| run.join(' ') }
  end

  def tokenize(text)
    text.to_s.downcase.scan(/[[:alnum:]]+/)
  end
end
