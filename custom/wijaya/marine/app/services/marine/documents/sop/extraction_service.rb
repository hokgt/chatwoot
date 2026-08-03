# Entry point for SOP text extraction (Commit 1C).
#
# Given an attached ActiveStorage blob, it opens a single CommandRunner (one shared
# private workspace + one shared 120s deadline for the whole document), downloads the
# EXACT original bytes into that private workspace, and dispatches to the PDF or image
# pipeline based on the validated content type. It returns a stable Result; it NEVER
# mutates the document or the blob.
module Marine
  module Documents
    module Sop
      class ExtractionService
        # method is one of: pdf_text, pdf_ocr, pdf_mixed, image_ocr.
        Result = Struct.new(:content, :processing_method, :page_count, keyword_init: true)

        def initialize(blob:)
          @blob = blob
        end

        def call
          CommandRunner.open do |runner|
            source = runner.workspace_path('source')
            download_to(source)
            dispatch(runner, source)
          end
        end

        private

        def download_to(path)
          File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
            @blob.download { |chunk| file.write(chunk) }
          end
        end

        def dispatch(runner, source)
          case @blob.content_type
          when 'application/pdf'
            PdfExtractor.new(path: source, runner: runner).call
          when 'image/jpeg', 'image/png'
            ImageOcrService.new(path: source, runner: runner).call
          else
            raise Errors::SopExtractionFailedError
          end
        end
      end
    end
  end
end
