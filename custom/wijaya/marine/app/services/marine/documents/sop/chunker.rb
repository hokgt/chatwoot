# Deterministic, Unicode-safe, bounded SOP text chunker (Commit 1D).
class Marine::Documents::Sop::Chunker
  MAX_CHARS = 1_200
  OVERLAP_CHARS = 150
  MAX_INPUT_CHARS = Marine::Document::MAX_CONTENT_CHARS
  MAX_CHUNKS = 500

  GRAPHEME = /\X/
  PARAGRAPH_BOUNDARY = /\n{2,}/
  SENTENCE_BOUNDARY = /(?<=[.!?…。！？])\s+/

  def initialize(text, max_chars: MAX_CHARS, overlap: OVERLAP_CHARS,
                 max_input_chars: MAX_INPUT_CHARS, max_chunks: MAX_CHUNKS)
    @text = text.to_s
    @max_chars = positive(max_chars, MAX_CHARS)
    @max_input_chars = positive(max_input_chars, MAX_INPUT_CHARS)
    @max_chunks = positive(max_chunks, MAX_CHUNKS)
    @overlap = overlap.to_i.clamp(0, @max_chars - 1)
    separator = @overlap.positive? ? 1 : 0
    @body_budget = [@max_chars - @overlap - separator, 1].max
  end

  def call
    bodies = pack(segment(bounded_input))
    bodies.first(@max_chunks).each_with_index.map do |body, index|
      index.zero? || @overlap.zero? ? body : with_overlap(bodies[index - 1], body)
    end.reject(&:blank?)
  end

  private

  def bounded_input
    graphemes(@text).first(@max_input_chars).join
  end

  def segment(text)
    text.split(PARAGRAPH_BOUNDARY).flat_map { |paragraph| segment_paragraph(paragraph) }
        .map { |unit| unit.gsub(/[\t\r\f\v ]+/, ' ').strip }
        .reject(&:empty?)
  end

  def segment_paragraph(paragraph)
    value = paragraph.strip
    return [] if value.empty?
    return [value] if length(value) <= @body_budget

    value.split(SENTENCE_BOUNDARY).flat_map do |sentence|
      length(sentence) <= @body_budget ? [sentence] : hard_split(sentence)
    end
  end

  def hard_split(sentence)
    graphemes(sentence).each_slice(@body_budget).map(&:join)
  end

  def pack(segments)
    segments.each_with_object([]) do |segment, bodies|
      if bodies.empty? || length(bodies.last) + 1 + length(segment) > @body_budget
        bodies << segment.dup
      else
        bodies.last << ' ' << segment
      end
    end
  end

  def with_overlap(previous, body)
    prefix = graphemes(previous).last(@overlap).join
    graphemes("#{prefix} #{body}").first(@max_chars).join
  end

  def graphemes(value) = value.scan(GRAPHEME)
  def length(value) = graphemes(value).length

  def positive(value, fallback)
    number = value.to_i
    number.positive? ? number : fallback
  end
end
