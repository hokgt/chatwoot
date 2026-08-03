# Image OCR for SOP uploads (Commit 1C).
#
# OCRs a single JPG/PNG with Tesseract (ind+eng), normalizes the result, and returns
# an image_ocr Result. An empty result maps to sop_no_readable_text.
module Marine
  module Documents
    module Sop
      class ImageOcrService
        OCR_LANGUAGES = 'ind+eng'.freeze

        def initialize(path:, runner:)
          @path = path
          @runner = runner
        end

        def call
          ocr = @runner.run('tesseract', @path, 'stdout', '-l', OCR_LANGUAGES)
          raise Errors::SopOcrFailedError unless ocr.ok

          content = TextNormalizer.new(ocr.stdout).call
          raise Errors::SopNoReadableTextError if content.empty?

          ExtractionService::Result.new(content: content, processing_method: 'image_ocr', page_count: 1)
        end
      end
    end
  end
end
