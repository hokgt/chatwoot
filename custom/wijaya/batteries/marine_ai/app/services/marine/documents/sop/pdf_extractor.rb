# Page-aware PDF extraction with per-page OCR fallback (Commit 1C).
#
# For each page, IN ORDER:
#   1. pdftotext extracts that single page's embedded text, which is normalized.
#   2. If the normalized text meets a deterministic meaningful-text threshold, it is
#      kept as-is and the page is NOT OCRed.
#   3. Otherwise ONLY that page is rendered to an image (pdftoppm) and OCRed with
#      Tesseract (ind+eng), then normalized.
#
# Pages are recombined in their original order. The processing method is pdf_text when
# every page used direct text, pdf_ocr when every page used OCR, and pdf_mixed when
# both occurred. An empty final result maps to sop_no_readable_text.
module Marine
  module Documents
    module Sop
      class PdfExtractor
        MAX_PAGES = 50
        RENDER_DPI = 200
        # Hard cap on the rendered raster's longest side (pixels). Combined with the DPI
        # this bounds output dimensions so a pathological MediaBox cannot trigger a
        # decompression bomb, while a normal A4 page keeps high-quality text.
        RENDER_MAX_PX = 4096
        OCR_LANGUAGES = 'ind+eng'.freeze
        # A page's direct text is "meaningful" when it has at least this many
        # alphanumeric characters after normalization. Scanned pages yield little or
        # no embedded text and fall through to OCR.
        MIN_MEANINGFUL_ALNUM = 24

        def initialize(path:, runner:)
          @path = path
          @runner = runner
        end

        def call # rubocop:disable Metrics/MethodLength
          page_count = count_pages
          raise Errors::SopPageLimitExceededError if page_count > MAX_PAGES

          texts = []
          used_ocr = false
          used_text = false

          (1..page_count).each do |page|
            direct = TextNormalizer.new(direct_text(page)).call
            if meaningful?(direct)
              texts << direct
              used_text = true
            else
              texts << TextNormalizer.new(ocr_page(page)).call
              used_ocr = true
            end
          end

          content = TextNormalizer.new(texts.reject(&:empty?).join("\n\n")).call
          raise Errors::SopNoReadableTextError if content.empty?

          ExtractionService::Result.new(
            content: content,
            processing_method: method_for(used_text, used_ocr),
            page_count: page_count
          )
        end

        private

        def count_pages
          result = @runner.run('pdfinfo', @path)
          raise Errors::SopPdfInvalidError unless result.ok

          match = result.stdout.to_s.match(/^Pages:\s+(\d+)/)
          raise Errors::SopPdfInvalidError if match.nil?

          count = match[1].to_i
          raise Errors::SopPdfInvalidError if count < 1

          count
        end

        def direct_text(page)
          result = @runner.run('pdftotext', '-f', page.to_s, '-l', page.to_s, '-layout', @path, '-')
          raise Errors::SopExtractionFailedError unless result.ok

          result.stdout
        end

        def ocr_page(page)
          prefix = @runner.workspace_path("page-#{page}")
          render = @runner.run('pdftoppm', '-png', '-r', RENDER_DPI.to_s, '-scale-to', RENDER_MAX_PX.to_s,
                               '-f', page.to_s, '-l', page.to_s, '-singlefile', @path, prefix)
          image = "#{prefix}.png"
          raise Errors::SopOcrFailedError unless render.ok && File.file?(image)

          ocr = @runner.run('tesseract', image, 'stdout', '-l', OCR_LANGUAGES)
          raise Errors::SopOcrFailedError unless ocr.ok

          ocr.stdout
        ensure
          # The rendered raster is only needed for this page's OCR. Delete it immediately
          # so a large multi-page scan never accumulates every page's image on disk at
          # once (the whole workspace is still removed on completion by CommandRunner).
          File.delete(image) if image && File.file?(image)
        end

        def meaningful?(text)
          text.scan(/[[:alnum:]]/).size >= MIN_MEANINGFUL_ALNUM
        end

        def method_for(used_text, used_ocr)
          return 'pdf_mixed' if used_text && used_ocr
          return 'pdf_ocr' if used_ocr

          'pdf_text'
        end
      end
    end
  end
end
