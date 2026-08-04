# Deterministic normalization for SOP extracted/OCR text (Commit 1C).
#
# Produces valid UTF-8 and:
#   * scrubs invalid byte sequences,
#   * removes NUL and other ASCII control characters (keeping newline + tab),
#   * normalizes CRLF/CR line endings to LF,
#   * collapses runs of horizontal whitespace (spaces/tabs/NBSP) to a single space,
#   * trims horizontal whitespace around line breaks,
#   * collapses 3+ consecutive newlines to a blank-line paragraph break (so empty
#     pages/regions disappear while paragraph structure is preserved),
#   * hard-caps the result at 200,000 characters.
module Marine
  module Documents
    module Sop
      class TextNormalizer
        MAX_CHARACTERS = 200_000
        # ASCII control chars EXCEPT tab (0x09) and newline (0x0A).
        CONTROL_CHARS = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/
        HORIZONTAL_WS = /[ \t\u00A0]+/

        def initialize(text)
          @text = text.to_s
        end

        def call
          s = @text.dup.force_encoding(Encoding::UTF_8)
          s = s.scrub('') unless s.valid_encoding?
          s = s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: '')
          s = s.gsub(/\r\n?/, "\n")
          s = s.gsub(CONTROL_CHARS, '')
          s = s.gsub(HORIZONTAL_WS, ' ')
          s = s.gsub(/ *\n */, "\n")
          s = s.gsub(/\n{3,}/, "\n\n")
          s = s.strip
          s = s[0, MAX_CHARACTERS] if s.length > MAX_CHARACTERS
          s
        end
      end
    end
  end
end
