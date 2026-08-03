# frozen_string_literal: true

require 'rails_helper'
require 'open3'

# End-to-end smoke coverage that drives the REAL Poppler/Tesseract (+ ImageMagick)
# binaries. The whole group is skipped ONLY when the required runtime tools are genuinely
# absent (as in the default containerized test image); it never skips individual examples
# on failure. In the derived SOP-processing image — which ships Poppler (incl. pdfunite),
# Tesseract eng+ind, and ImageMagick — every example runs and must pass.
#
# The programmable-runner unit specs (pdf_extractor_spec / image_ocr_service_spec) cover
# the branching logic; this file proves the argv contracts line up with the actual tools
# across all pipelines: text PDF, PNG OCR, JPG OCR, scanned-image PDF OCR fallback, and a
# mixed text+scanned PDF that must preserve page order and report pdf_mixed.
#
# All fixtures are generated deterministically in a private temp dir from tiny hand-built
# text PDFs; there are NO binary fixtures and no raw extracted content is ever logged.
# Every external tool is invoked via a direct argv API — never a shell string.
RSpec.describe 'Marine SOP extraction (real binaries)', type: :model do
  WORDS_TEXT = 'ALPHA BRAVO CHARLIE readable procedure'
  WORDS_SCAN = 'DELTA ECHO FOXTROT scanned section'

  # Direct PATH executable lookup — no shell, and not fooled by `command` being a shell
  # builtin (the previous `system('command', '-v', ...)` check could wrongly skip).
  def which(bin)
    ENV['PATH'].to_s.split(File::PATH_SEPARATOR).any? do |dir|
      candidate = File.join(dir, bin)
      File.file?(candidate) && File.executable?(candidate)
    end
  end

  def imagemagick_bin
    %w[magick convert].find { |b| which(b) }
  end

  def tesseract_langs
    stdout, = Open3.capture2e('tesseract', '--list-langs')
    stdout
  rescue StandardError
    ''
  end

  def binaries_present?
    %w[pdfinfo pdftotext pdftoppm pdfunite tesseract].all? { |b| which(b) } &&
      !imagemagick_bin.nil? &&
      tesseract_langs.include?('eng') && tesseract_langs.include?('ind')
  end

  # Minimal single-page PDF with a Helvetica text run. Poppler reconstructs the trivial
  # cross-reference table, which is enough for pdfinfo/pdftotext and for pdftoppm to paint
  # the glyphs.
  def build_text_pdf(text)
    objects = []
    objects << "1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n"
    objects << "2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
    objects << "3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]" \
               "/Resources<</Font<</F1 5 0 R>>>>/Contents 4 0 R>>endobj\n"
    stream = "BT /F1 32 Tf 72 700 Td (#{text}) Tj ET"
    objects << "4 0 obj<</Length #{stream.bytesize}>>stream\n#{stream}\nendstream endobj\n"
    objects << "5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj\n"
    ("%PDF-1.4\n" + objects.join + "startxref\n0\n%%EOF\n").b
  end

  around do |example|
    skip 'Poppler/Tesseract (eng+ind) + ImageMagick not installed' unless binaries_present?
    Dir.mktmpdir('sop-smoke') { |dir| @dir = dir; example.run }
  end

  # --- fixture builders (argv only; fail loudly so the derived image never silently skips)

  # Runs a tool by argv and returns its combined output; raises (failing the example) on a
  # non-zero exit. The message carries only the binary name — never content or a full path.
  def run!(*argv)
    out, status = Open3.capture2e(*argv)
    raise "smoke fixture command failed: #{argv.first}" unless status.success?

    out
  end

  def write_pdf(name, text)
    path = File.join(@dir, name)
    File.binwrite(path, build_text_pdf(text))
    path
  end

  def rasterize(pdf, prefix, format)
    flag, ext = format == :jpeg ? ['-jpeg', 'jpg'] : ['-png', 'png']
    run!('pdftoppm', flag, '-r', '300', '-scale-to', '4096', '-f', '1', '-l', '1', '-singlefile', pdf, prefix)
    path = "#{prefix}.#{ext}"
    raise 'pdftoppm produced no raster' unless File.file?(path)

    path
  end

  # Builds a text-free "scanned" single-page PDF: render a text PDF to a raster, then wrap
  # that raster in a PDF via ImageMagick so it carries an image layer only (no text).
  def scanned_pdf(words, tag)
    src = write_pdf("#{tag}-src.pdf", words)
    png = rasterize(src, File.join(@dir, "#{tag}-raster"), :png)
    out = File.join(@dir, "#{tag}.pdf")
    run!(imagemagick_bin, png, out)
    out
  end

  def extract_pdf(path)
    Marine::Documents::CommandRunner.open do |runner|
      Marine::Documents::Sop::PdfExtractor.new(path: path, runner: runner).call
    end
  end

  def extract_image(path)
    Marine::Documents::CommandRunner.open do |runner|
      Marine::Documents::Sop::ImageOcrService.new(path: path, runner: runner).call
    end
  end

  it 'extracts a text PDF directly (pdf_text) without OCR' do
    result = extract_pdf(write_pdf('text.pdf', WORDS_TEXT))

    expect(result.processing_method).to eq('pdf_text')
    expect(result.page_count).to eq(1)
    expect(result.content).to include('BRAVO')
    expect(result.content).to include('CHARLIE')
  end

  it 'OCRs a rendered PNG raster (image_ocr) via Tesseract' do
    png = rasterize(write_pdf('text.pdf', WORDS_TEXT), File.join(@dir, 'png'), :png)

    result = extract_image(png)

    expect(result.processing_method).to eq('image_ocr')
    expect(result.page_count).to eq(1)
    expect(result.content.upcase).to include('BRAVO')
  end

  it 'OCRs a rendered JPG raster (image_ocr) via Tesseract' do
    jpg = rasterize(write_pdf('text.pdf', WORDS_TEXT), File.join(@dir, 'jpg'), :jpeg)

    result = extract_image(jpg)

    expect(result.processing_method).to eq('image_ocr')
    expect(result.page_count).to eq(1)
    expect(result.content.upcase).to include('BRAVO')
  end

  it 'falls back to OCR for a scanned-image PDF (pdf_ocr)' do
    result = extract_pdf(scanned_pdf(WORDS_SCAN, 'scan'))

    expect(result.processing_method).to eq('pdf_ocr')
    expect(result.page_count).to eq(1)
    expect(result.content.upcase).to include('ECHO')
  end

  it 'preserves page order and reports pdf_mixed for a text + scanned PDF' do
    text = write_pdf('mixed-text.pdf', WORDS_TEXT)
    scanned = scanned_pdf(WORDS_SCAN, 'mixed-scan')
    mixed = File.join(@dir, 'mixed.pdf')
    run!('pdfunite', text, scanned, mixed)

    result = extract_pdf(mixed)

    expect(result.processing_method).to eq('pdf_mixed')
    expect(result.page_count).to eq(2)
    content = result.content.upcase
    expect(content).to include('BRAVO')
    expect(content).to include('ECHO')
    expect(content.index('BRAVO')).to be < content.index('ECHO')
  end
end
