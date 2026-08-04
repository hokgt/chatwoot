# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Documents::Sop::ExtractionService do
  # Regression for the production async PNG blocker: real image/PDF bytes contain byte
  # sequences that are NOT valid UTF-8, so streaming the ActiveStorage download into a
  # text-mode sink raised Encoding::UndefinedConversionError immediately after download.
  # Earlier unit doubles used plain ASCII text and never exercised this. The source file
  # must be opened in binary mode so the EXACT stored bytes reach the extractor untouched.
  it 'streams invalid-UTF-8 binary bytes to a byte-identical source file for the extractor' do
    # A minimal PNG-style prefix followed by bytes that are invalid UTF-8 (0xFF, 0xFE, a
    # lone 0x80 continuation). Split across chunks to mirror ActiveStorage's streaming.
    binary = "\x89PNG\r\n\x1a\n\xFF\xFE\x00\x01\x80\x81\x82".b
    expect(binary.dup.force_encoding(Encoding::UTF_8).valid_encoding?).to be(false)
    chunks = [binary.byteslice(0, 5), binary.byteslice(5..)]

    blob = instance_double(ActiveStorage::Blob, content_type: 'image/png')
    allow(blob).to receive(:download) do |&block|
      chunks.each { |chunk| block.call(chunk) }
    end

    # Capture the bytes INSIDE the extractor: the runner deletes its private workspace on
    # block exit, so the source file no longer exists once .call returns.
    received = nil
    result = described_class::Result.new(content: 'ocr', processing_method: 'image_ocr', page_count: 1)
    allow(Marine::Documents::Sop::ImageOcrService).to receive(:new) do |**kwargs|
      received = File.binread(kwargs[:path])
      instance_double(Marine::Documents::Sop::ImageOcrService, call: result)
    end

    expect { described_class.new(blob: blob).call }.not_to raise_error

    expect(received).to eq(binary)
    expect(received.encoding).to eq(Encoding::ASCII_8BIT)
  end
end
