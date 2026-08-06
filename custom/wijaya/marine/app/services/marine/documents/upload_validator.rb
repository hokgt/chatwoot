# Reusable, defense-in-depth validator for Product Catalog source uploads.
#
# It independently validates THREE things and rejects any mismatch:
#   1. the filename extension,
#   2. the declared (browser-supplied) MIME type, and
#   3. the actual file signature (magic bytes) read from the stream.
#
# Only PDF, JPG/JPEG, and PNG are allowed, at most exactly 2 MiB (2 * 1024 * 1024),
# and never empty. The IO is rewound before and after inspection so the caller can
# store the exact original bytes. Errors are stable InvalidFileError instances that
# NEVER leak the filename, a filesystem path, or file content — only a generic reason.
module Marine
  module Documents
    class UploadValidator
      MAX_BYTES = Marine::Document::MAX_SOURCE_FILE_BYTES # 2 MiB

      # canonical content type => the extensions, declared MIME types, and magic-byte
      # signatures that must all agree for the upload to be accepted.
      SPECS = {
        'application/pdf' => {
          extensions: %w[pdf],
          mime_types: %w[application/pdf],
          signatures: ["%PDF-".b]
        },
        'image/png' => {
          extensions: %w[png],
          mime_types: %w[image/png],
          signatures: ["\x89PNG\r\n\x1A\n".b]
        },
        'image/jpeg' => {
          extensions: %w[jpg jpeg],
          mime_types: %w[image/jpeg image/jpg image/pjpeg],
          signatures: ["\xFF\xD8\xFF".b]
        }
      }.freeze

      # Longest signature is PNG (8 bytes); reading 8 covers every type.
      HEADER_BYTES = 8

      Result = Struct.new(:content_type, :byte_size, :filename, keyword_init: true)

      def initialize(upload)
        @upload = upload
      end

      # Returns a Result with the canonical (signature-derived) content type, byte
      # size, and original filename. Raises InvalidFileError on any problem.
      def call
        ensure_uploadish!

        size = byte_size
        raise invalid('is empty') if size.zero?
        raise invalid('is too large') if size > MAX_BYTES

        type = type_for_extension
        raise invalid('has an unsupported type') if type.nil?
        raise invalid('does not match its declared type') unless SPECS[type][:mime_types].include?(declared_mime)
        raise invalid('does not match its content') unless signature_matches?(type, read_header)

        Result.new(content_type: type, byte_size: size, filename: original_filename)
      ensure
        rewind!
      end

      private

      def ensure_uploadish!
        raise invalid('is missing') unless @upload.respond_to?(:read)
        raise invalid('is missing') if original_filename.blank?
      end

      def byte_size
        if @upload.respond_to?(:size) && !@upload.size.nil?
          @upload.size.to_i
        else
          rewind!
          @upload.read.to_s.bytesize
        end
      end

      def type_for_extension
        ext = File.extname(original_filename).delete_prefix('.').downcase
        return nil if ext.empty?

        SPECS.find { |_type, spec| spec[:extensions].include?(ext) }&.first
      end

      def declared_mime
        @upload.content_type.to_s.split(';').first.to_s.strip.downcase
      end

      def read_header
        rewind!
        @upload.read(HEADER_BYTES).to_s.b
      rescue StandardError
        ''.b
      ensure
        rewind!
      end

      def signature_matches?(type, header)
        SPECS[type][:signatures].any? { |signature| header.start_with?(signature) }
      end

      def original_filename
        @upload.respond_to?(:original_filename) ? @upload.original_filename.to_s : ''
      end

      def rewind!
        @upload.rewind if @upload.respond_to?(:rewind)
      rescue StandardError
        nil
      end

      # Message contains only a stable reason — never the filename, a path, or bytes.
      def invalid(reason)
        Errors::InvalidFileError.new("The uploaded file #{reason}")
      end
    end
  end
end
