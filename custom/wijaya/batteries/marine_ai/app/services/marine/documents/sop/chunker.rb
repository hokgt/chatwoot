# Deterministic, Unicode-safe, bounded SOP text chunker (Commit 1D).
module Marine
  module Documents
    module Sop
      class Chunker
        MAX_CHARS = 1_200
        OVERLAP_CHARS = 150
        MAX_INPUT_CHARS = Marine::Document::MAX_CONTENT_CHARS
        MAX_CHUNKS = 500
        MAX_BYTES_PER_CHAR = 4

        GRAPHEME = /\X/
        PARAGRAPH_BOUNDARY = /\n{2,}/
        SENTENCE_BOUNDARY = /(?<=[.!?…。！？])\s+/

        class OversizedGrapheme < StandardError; end

        def initialize(text, max_chars: MAX_CHARS, overlap: OVERLAP_CHARS,
                       max_input_chars: MAX_INPUT_CHARS, max_chunks: MAX_CHUNKS)
          @text = text.to_s
          @max_chars = positive(max_chars, MAX_CHARS)
          @max_input_chars = positive(max_input_chars, MAX_INPUT_CHARS)
          @max_chunks = positive(max_chunks, MAX_CHUNKS)
          @max_bytes = @max_chars * MAX_BYTES_PER_CHAR
          @max_input_bytes = @max_input_chars * MAX_BYTES_PER_CHAR
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
          take_prefix(@text, @max_input_chars, @max_input_bytes)
        end

        def segment(text)
          text.split(PARAGRAPH_BOUNDARY).flat_map { |paragraph| segment_paragraph(paragraph) }
              .map { |unit| unit.gsub(/[\t\r\f\v ]+/, ' ').strip }
              .reject(&:empty?)
        end

        def segment_paragraph(paragraph)
          value = paragraph.strip
          return [] if value.empty?
          return [value] if fits?(value, @body_budget)

          value.split(SENTENCE_BOUNDARY).flat_map do |sentence|
            fits?(sentence, @body_budget) ? [sentence] : hard_split(sentence)
          end
        end

        def hard_split(sentence)
          sentence.scan(GRAPHEME).each_with_object([]) do |grapheme, chunks|
            validate_grapheme!(grapheme, @body_budget)
            if chunks.empty? || !fits?(chunks.last + grapheme, @body_budget)
              chunks << grapheme.dup
            else
              chunks.last << grapheme
            end
          end
        end

        def pack(segments)
          segments.each_with_object([]) do |segment, bodies|
            candidate = bodies.empty? ? segment : "#{bodies.last} #{segment}"
            if bodies.empty? || !fits?(candidate, @body_budget)
              bodies << segment.dup
            else
              bodies[-1] = candidate
            end
          end
        end

        def with_overlap(previous, body)
          prefix = take_suffix(previous, @overlap, @overlap * MAX_BYTES_PER_CHAR)
          take_prefix("#{prefix} #{body}", @max_chars, @max_bytes)
        end

        def take_prefix(value, char_limit, byte_limit)
          bounded_graphemes(value.scan(GRAPHEME), char_limit, byte_limit)
        end

        def take_suffix(value, char_limit, byte_limit)
          bounded_graphemes(value.scan(GRAPHEME).reverse, char_limit, byte_limit).scan(GRAPHEME).reverse.join
        end

        def bounded_graphemes(graphemes, char_limit, byte_limit)
          graphemes.each_with_object(+'') do |grapheme, result|
            validate_grapheme!(grapheme)
            break result if result.length + grapheme.length > char_limit
            break result if result.bytesize + grapheme.bytesize > byte_limit

            result << grapheme
          end
        end

        def validate_grapheme!(grapheme, char_limit = @max_chars)
          return if grapheme.length <= char_limit && grapheme.bytesize <= char_limit * MAX_BYTES_PER_CHAR

          raise OversizedGrapheme, 'grapheme exceeds chunk payload limit'
        end

        def fits?(value, char_limit)
          value.length <= char_limit && value.bytesize <= char_limit * MAX_BYTES_PER_CHAR
        end

        def positive(value, fallback)
          number = value.to_i
          number.positive? ? number : fallback
        end
      end
    end
  end
end
