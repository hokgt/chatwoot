# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Documents::Sop::ImageOcrService do
  let(:runner) { instance_double(Marine::Documents::CommandRunner) }

  def ok(stdout) = Marine::Documents::CommandRunner::Result.new(stdout: stdout, ok: true)
  def failed = Marine::Documents::CommandRunner::Result.new(stdout: '', ok: false)

  def extract = described_class.new(path: '/tmp/image', runner: runner).call

  it 'OCRs a JPG/PNG with ind+eng and returns an image_ocr result' do
    expect(runner).to receive(:run)
      .with('tesseract', '/tmp/image', 'stdout', '-l', 'ind+eng')
      .and_return(ok("Recognized  image\n\n\ntext"))

    result = extract
    expect(result.processing_method).to eq('image_ocr')
    expect(result.page_count).to eq(1)
    expect(result.content).to eq("Recognized image\n\ntext")
  end

  it 'raises sop_no_readable_text when OCR yields nothing' do
    allow(runner).to receive(:run).and_return(ok("   \n\n"))
    expect { extract }.to raise_error(Marine::Documents::Errors::SopNoReadableTextError)
  end

  it 'raises sop_ocr_failed when Tesseract exits non-zero' do
    allow(runner).to receive(:run).and_return(failed)
    expect { extract }.to raise_error(Marine::Documents::Errors::SopOcrFailedError)
  end

  it 'propagates a timeout as sop_ocr_timeout' do
    allow(runner).to receive(:run).and_raise(Marine::Documents::Errors::SopOcrTimeoutError)
    expect { extract }.to raise_error(Marine::Documents::Errors::SopOcrTimeoutError)
  end

  it 'propagates a missing dependency as sop_processing_dependency_unavailable' do
    allow(runner).to receive(:run).and_raise(Marine::Documents::Errors::SopProcessingDependencyUnavailableError)
    expect { extract }.to raise_error(Marine::Documents::Errors::SopProcessingDependencyUnavailableError)
  end
end
