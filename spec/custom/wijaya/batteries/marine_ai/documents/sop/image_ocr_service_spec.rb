# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Documents::Sop::ImageOcrService do
  let(:runner) { instance_double(Marine::Documents::CommandRunner) }

  around do |example|
    Dir.mktmpdir do |dir|
      @tmp = dir
      example.run
    end
  end

  def ok(stdout) = Marine::Documents::CommandRunner::Result.new(stdout: stdout, ok: true)
  def failed = Marine::Documents::CommandRunner::Result.new(stdout: '', ok: false)

  # Minimal valid headers — only the bytes the pure-Ruby dimension parser reads matter.
  def png_bytes(width, height)
    "\x89PNG\r\n\x1a\n".b + [13].pack('N') + 'IHDR'.b + [width, height].pack('NN') +
      [8, 6, 0, 0, 0].pack('C5') + [0].pack('N')
  end

  def jpeg_bytes(width, height)
    soi = "\xFF\xD8".b
    app0 = "\xFF\xE0".b + [16].pack('n') + 'JFIF'.b + "\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00".b
    sof0 = "\xFF\xC0".b + [17].pack('n') + [8].pack('C') + [height, width].pack('nn') +
           [3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1].pack('C10')
    soi + app0 + sof0 + "\xFF\xD9".b
  end

  # A JPEG whose SOF only appears AFTER total_app_bytes of APPn payload. Each JPEG segment
  # length is a 16-bit field (payload <= 65_533), so pushing SOF past 64 KiB requires more
  # than one APP1 segment — exactly the real EXIF/thumbnail case the scanner must handle.
  def jpeg_with_apps_before_sof(width, height, total_app_bytes:)
    soi = "\xFF\xD8".b
    apps = ''.b
    remaining = total_app_bytes
    while remaining.positive?
      chunk = [remaining, 65_533].min
      apps << ("\xFF\xE1".b + [chunk + 2].pack('n') + ("\x00".b * chunk))
      remaining -= chunk
    end
    sof0 = "\xFF\xC0".b + [17].pack('n') + [8].pack('C') + [height, width].pack('nn') +
           [3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1].pack('C10')
    soi + apps + sof0 + "\xFF\xD9".b
  end

  def image_path(bytes = png_bytes(120, 80))
    path = File.join(@tmp, "img-#{SecureRandom.hex(4)}.png")
    File.binwrite(path, bytes)
    path
  end

  def extract(path = image_path) = described_class.new(path: path, runner: runner).call

  it 'OCRs a JPG/PNG with ind+eng and returns an image_ocr result' do
    path = image_path
    expect(runner).to receive(:run)
      .with('tesseract', path, 'stdout', '-l', 'ind+eng')
      .and_return(ok("Recognized  image\n\n\ntext"))

    result = extract(path)
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

  describe 'dimension validation (pre-OCR, pure Ruby, no decode)' do
    it 'accepts a valid JPEG header and OCRs it' do
      path = image_path(jpeg_bytes(200, 150))
      allow(runner).to receive(:run).and_return(ok('hello'))
      expect(extract(path).content).to eq('hello')
    end

    it 'finds a JPEG SOF sitting past 64 KiB behind large APP/EXIF segments (scans to 2 MiB)' do
      # ~100 KiB of APP payload pushes the SOF well past the old 64 KiB header window: the
      # scanner must read up to the 2 MiB ceiling to recover the real dimensions.
      bytes = jpeg_with_apps_before_sof(200, 150, total_app_bytes: 100_000)
      expect(bytes.bytesize).to be > 64 * 1024
      path = image_path(bytes)
      allow(runner).to receive(:run).and_return(ok('deep sof'))
      expect(extract(path).content).to eq('deep sof')
    end

    it 'still rejects an over-large JPEG whose SOF sits past 64 KiB' do
      expect(runner).not_to receive(:run)
      path = image_path(jpeg_with_apps_before_sof(30_000, 30_000, total_app_bytes: 100_000))
      expect { extract(path) }.to raise_error(Marine::Documents::Errors::SopImageInvalidError)
    end

    it 'rejects an over-large PNG before invoking Tesseract' do
      expect(runner).not_to receive(:run)
      path = image_path(png_bytes(30_000, 30_000))
      expect { extract(path) }.to raise_error(Marine::Documents::Errors::SopImageInvalidError)
    end

    it 'rejects a PNG within per-side bounds but over the total-pixel bound' do
      # 6000x5000 = 30 MP: neither side exceeds MAX_IMAGE_DIMENSION (10000) but the pixel
      # product exceeds MAX_IMAGE_PIXELS (25 MP), so the product branch must reject it.
      expect(runner).not_to receive(:run)
      path = image_path(png_bytes(6_000, 5_000))
      expect { extract(path) }.to raise_error(Marine::Documents::Errors::SopImageInvalidError)
    end

    it 'rejects a zero-dimension PNG before invoking Tesseract' do
      expect(runner).not_to receive(:run)
      path = image_path(png_bytes(0, 100))
      expect { extract(path) }.to raise_error(Marine::Documents::Errors::SopImageInvalidError)
    end

    it 'rejects a file that is not a parseable PNG/JPEG' do
      expect(runner).not_to receive(:run)
      path = image_path('not really an image at all'.b)
      expect { extract(path) }.to raise_error(Marine::Documents::Errors::SopImageInvalidError)
    end
  end
end
