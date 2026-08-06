# frozen_string_literal: true

require 'rails_helper'

# The PdfExtractor orchestration is exercised with a programmable in-memory runner so
# these specs never require the real Poppler/Tesseract binaries. Real-binary behavior is
# covered by extraction_smoke_spec.rb (skipped unless the tools are installed).
RSpec.describe Marine::Documents::Sop::PdfExtractor do
  # Programmable runner. `pages` is an array of { text:, ocr: } (embedded text and the
  # OCR text for each page, 1-indexed). Optional flags force pdfinfo / pdftotext /
  # pdftoppm / tesseract failures.
  class PdfFakeRunner
    Result = Marine::Documents::CommandRunner::Result

    attr_reader :ocr_pages

    def initialize(pages:, page_count: nil, pdfinfo_ok: true, pdftotext_ok: true,
                   pdftoppm_ok: true, tesseract_ok: true)
      @pages = pages
      @page_count = page_count || pages.length
      @pdfinfo_ok = pdfinfo_ok
      @pdftotext_ok = pdftotext_ok
      @pdftoppm_ok = pdftoppm_ok
      @tesseract_ok = tesseract_ok
      @dir = Dir.mktmpdir('fake-runner')
      @seq = 0
      @ocr_pages = []
    end

    def workspace_path(label)
      @seq += 1
      File.join(@dir, "#{label}-#{@seq}")
    end

    def written_images = (@image_to_page || {}).keys

    def run(*argv)
      case argv.first
      when 'pdfinfo'   then pdfinfo
      when 'pdftotext' then pdftotext(page_arg(argv))
      when 'pdftoppm'  then pdftoppm(page_arg(argv), argv.last)
      when 'tesseract' then tesseract(argv[1])
      else Result.new(stdout: '', ok: false)
      end
    end

    private

    def page_arg(argv)
      argv[argv.index('-f') + 1].to_i
    end

    def pdfinfo
      return Result.new(stdout: '', ok: false) unless @pdfinfo_ok

      Result.new(stdout: "Title: x\nPages:          #{@page_count}\nEncrypted: no\n", ok: true)
    end

    def pdftotext(page)
      return Result.new(stdout: '', ok: false) unless @pdftotext_ok

      Result.new(stdout: @pages[page - 1][:text].to_s, ok: true)
    end

    def pdftoppm(page, prefix)
      return Result.new(stdout: '', ok: false) unless @pdftoppm_ok

      image = "#{prefix}.png"
      File.binwrite(image, 'PNG-BYTES')
      @image_to_page ||= {}
      @image_to_page[image] = page
      Result.new(stdout: '', ok: true)
    end

    def tesseract(image)
      return Result.new(stdout: '', ok: false) unless @tesseract_ok

      page = (@image_to_page || {})[image]
      @ocr_pages << page
      Result.new(stdout: @pages[page - 1][:ocr].to_s, ok: true)
    end
  end

  def extract(runner)
    described_class.new(path: '/tmp/source', runner: runner).call
  end

  it 'extracts a fully text PDF directly and never OCRs any page' do
    runner = PdfFakeRunner.new(pages: [
                              { text: 'This is the first page with plenty of real embedded words.' },
                              { text: 'Second page also has clearly readable embedded text content.' }
                            ])
    result = extract(runner)

    expect(result.processing_method).to eq('pdf_text')
    expect(result.page_count).to eq(2)
    expect(runner.ocr_pages).to be_empty
    expect(result.content).to include('first page')
    expect(result.content).to include('Second page')
  end

  it 'OCRs every page of a scanned PDF (no embedded text)' do
    runner = PdfFakeRunner.new(pages: [
                              { text: '', ocr: 'Recognized text from the first scanned page.' },
                              { text: "   \n", ocr: 'Recognized text from the second scanned page.' }
                            ])
    result = extract(runner)

    expect(result.processing_method).to eq('pdf_ocr')
    expect(runner.ocr_pages).to eq([1, 2])
    expect(result.content).to include('first scanned page')
    expect(result.content).to include('second scanned page')
  end

  it 'handles a mixed PDF page-by-page and preserves original order' do
    runner = PdfFakeRunner.new(pages: [
                              { text: 'Alpha page has genuine embedded selectable text here.' },
                              { text: '', ocr: 'Bravo page recovered only through optical recognition.' },
                              { text: 'Charlie page again contains proper embedded machine text.' }
                            ])
    result = extract(runner)

    expect(result.processing_method).to eq('pdf_mixed')
    expect(runner.ocr_pages).to eq([2])
    expect(result.content.index('Alpha')).to be < result.content.index('Bravo')
    expect(result.content.index('Bravo')).to be < result.content.index('Charlie')
  end

  it 'deletes each per-page rendered raster immediately after OCR (no disk accumulation)' do
    runner = PdfFakeRunner.new(pages: [
                              { text: '', ocr: 'First scanned page recognized text content here.' },
                              { text: '', ocr: 'Second scanned page recognized text content here.' }
                            ])
    extract(runner)

    expect(runner.written_images).not_to be_empty
    expect(runner.written_images.select { |path| File.exist?(path) }).to be_empty
  end

  it 'raises sop_page_limit_exceeded for more than 50 pages' do
    runner = PdfFakeRunner.new(pages: [{ text: 'x' }], page_count: 51)
    expect { extract(runner) }.to raise_error(Marine::Documents::Errors::SopPageLimitExceededError)
  end

  it 'raises sop_pdf_invalid when pdfinfo fails' do
    runner = PdfFakeRunner.new(pages: [{ text: 'x' }], pdfinfo_ok: false)
    expect { extract(runner) }.to raise_error(Marine::Documents::Errors::SopPdfInvalidError)
  end

  it 'raises sop_extraction_failed when pdftotext fails' do
    runner = PdfFakeRunner.new(pages: [{ text: 'x' }], pdftotext_ok: false)
    expect { extract(runner) }.to raise_error(Marine::Documents::Errors::SopExtractionFailedError)
  end

  it 'raises sop_ocr_failed when rendering or OCR of a page fails' do
    runner = PdfFakeRunner.new(pages: [{ text: '', ocr: 'x' }], tesseract_ok: false)
    expect { extract(runner) }.to raise_error(Marine::Documents::Errors::SopOcrFailedError)
  end

  it 'raises sop_no_readable_text when nothing readable is produced' do
    runner = PdfFakeRunner.new(pages: [{ text: '', ocr: '   ' }])
    expect { extract(runner) }.to raise_error(Marine::Documents::Errors::SopNoReadableTextError)
  end

  it 'propagates a runner timeout as sop_ocr_timeout' do
    runner = instance_double(Marine::Documents::CommandRunner)
    allow(runner).to receive(:run).and_raise(Marine::Documents::Errors::SopOcrTimeoutError)
    expect { extract(runner) }.to raise_error(Marine::Documents::Errors::SopOcrTimeoutError)
  end

  it 'propagates a missing dependency as sop_processing_dependency_unavailable' do
    runner = instance_double(Marine::Documents::CommandRunner)
    allow(runner).to receive(:run).and_raise(Marine::Documents::Errors::SopProcessingDependencyUnavailableError)
    expect { extract(runner) }.to raise_error(Marine::Documents::Errors::SopProcessingDependencyUnavailableError)
  end
end
