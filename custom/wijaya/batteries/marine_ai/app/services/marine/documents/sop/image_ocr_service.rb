# Image OCR for SOP uploads (Commit 1C).
#
# OCRs a single JPG/PNG with Tesseract (ind+eng), normalizes the result, and returns
# an image_ocr Result. An empty result maps to sop_no_readable_text.
#
# BEFORE handing the file to Tesseract we parse its dimensions in pure Ruby directly from
# the PNG/JPEG header — no ImageMagick, no decode. A PNG's size lives in its first 24 bytes;
# a JPEG's Start-Of-Frame can legitimately sit AFTER large APPn/EXIF segments, so we scan
# up to the approved 2 MiB upload ceiling (hard bounded) to find it. Zero, missing,
# malformed, or overlarge dimensions are rejected with a stable error, so a tiny
# highly-compressed file cannot become a decompression bomb inside Tesseract.
module Marine
  module Documents
    module Sop
      class ImageOcrService
        OCR_LANGUAGES = 'ind+eng'.freeze
        # Conservative per-side and total-pixel bounds for a single SOP page image. An
        # A4 page at 300 DPI is ~2480x3508 (~8.7 MP); these leave generous headroom while
        # still capping a pathological input.
        MAX_IMAGE_DIMENSION = 10_000
        MAX_IMAGE_PIXELS = 25_000_000
        HEADER_READ_BYTES = 64 * 1024
        # Hard ceiling on the JPEG bytes we will scan for the Start-Of-Frame: the approved
        # 2 MiB SOP upload ceiling. A JPEG whose SOF only appears past this bound is treated
        # as unparseable (invalid) rather than read unbounded.
        MAX_SCAN_BYTES = 2 * 1024 * 1024

        def initialize(path:, runner:)
          @path = path
          @runner = runner
        end

        def call
          validate_dimensions!

          ocr = @runner.run('tesseract', @path, 'stdout', '-l', OCR_LANGUAGES)
          raise Errors::SopOcrFailedError unless ocr.ok

          content = TextNormalizer.new(ocr.stdout).call
          raise Errors::SopNoReadableTextError if content.empty?

          ExtractionService::Result.new(content: content, processing_method: 'image_ocr', page_count: 1)
        end

        private

        def validate_dimensions! # rubocop:disable Metrics/CyclomaticComplexity
          width, height = image_dimensions
          raise Errors::SopImageInvalidError if width.nil? || height.nil?
          raise Errors::SopImageInvalidError if width <= 0 || height <= 0
          raise Errors::SopImageInvalidError if width > MAX_IMAGE_DIMENSION || height > MAX_IMAGE_DIMENSION
          raise Errors::SopImageInvalidError if width * height > MAX_IMAGE_PIXELS
        end

        # Reads intrinsic dimensions from the raw header bytes. Returns [width, height] or
        # nil for anything it cannot safely parse (which the caller treats as invalid).
        def image_dimensions
          File.open(@path, 'rb') do |io|
            header = io.read(HEADER_READ_BYTES) || ''.b
            return png_dimensions(header) if png?(header)
            # A JPEG's SOF may sit past the first 64 KiB behind large APPn/EXIF segments;
            # extend the buffer up to the 2 MiB upload ceiling (hard bounded) before scanning.
            return jpeg_dimensions(scan_buffer(io, header)) if jpeg?(header)

            nil
          end
        rescue SystemCallError
          nil
        end

        # Grows the already-read header up to MAX_SCAN_BYTES total by reading the remaining
        # bytes once. Bounded strictly: never reads past the 2 MiB ceiling.
        def scan_buffer(io, header)
          remaining = MAX_SCAN_BYTES - header.bytesize
          return header unless remaining.positive?

          rest = io.read(remaining)
          rest ? header + rest : header
        end

        def png?(header) = header.byteslice(0, 8) == "\x89PNG\r\n\x1a\n".b

        def jpeg?(header) = header.byteslice(0, 2) == "\xFF\xD8".b

        def png_dimensions(header)
          return nil if header.bytesize < 24
          return nil unless header.byteslice(12, 4) == 'IHDR'.b

          [header.byteslice(16, 4).unpack1('N'), header.byteslice(20, 4).unpack1('N')]
        end

        # Walks JPEG marker segments to the first Start-Of-Frame (SOFn) and reads the
        # 16-bit height/width it declares. Bounded strictly by the bytes we already read.
        def jpeg_dimensions(header) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
          offset = 2
          size = header.bytesize
          while offset + 4 <= size
            return nil unless header.getbyte(offset) == 0xFF

            marker = header.getbyte(offset + 1)
            return nil if marker.nil?

            # Standalone markers (fill bytes, RSTn, SOI, EOI, TEM) carry no length payload.
            if marker == 0xFF
              offset += 1
              next
            end
            return nil if marker == 0xD9 || marker == 0x01 || (0xD0..0xD7).cover?(marker)

            length = (header.getbyte(offset + 2) << 8) | header.getbyte(offset + 3)
            return nil if length < 2

            if sof_marker?(marker)
              return nil if offset + 9 > size

              height = (header.getbyte(offset + 5) << 8) | header.getbyte(offset + 6)
              width  = (header.getbyte(offset + 7) << 8) | header.getbyte(offset + 8)
              return [width, height]
            end

            offset += 2 + length
          end
          nil
        end

        def sof_marker?(marker)
          (0xC0..0xCF).cover?(marker) && [0xC4, 0xC8, 0xCC].exclude?(marker)
        end
      end
    end
  end
end
