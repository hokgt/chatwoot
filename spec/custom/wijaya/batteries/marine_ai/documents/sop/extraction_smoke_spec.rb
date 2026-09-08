# frozen_string_literal: true

require 'rails_helper'
require 'open3'
require 'zlib'
require 'fileutils'

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
# All fixtures are generated deterministically in a private temp dir and there are NO
# binary fixtures and no raw extracted content is ever logged:
#   * text PDFs are tiny hand-built PDF-1.4 files with a real Helvetica text run;
#   * OCR rasters are drawn from a hand-built 5x7 bitmap glyph map into a high-contrast
#     grayscale PGM — so no system font is required for the images Tesseract reads;
#   * scanned-image PDFs are assembled in pure Ruby as a conforming PDF whose only content
#     is a FlateDecode DeviceGray image XObject — no ImageMagick PDF output, no Ghostscript.
# ImageMagick is used ONLY to transcode the in-memory PGM into real PNG/JPG files (a raster
# format conversion that needs neither a font nor a PDF delegate). Every external tool is
# invoked via a direct argv API — never a shell string.
RSpec.describe 'Marine SOP extraction (real binaries)', type: :model do
  WORDS_TEXT = 'ALPHA BRAVO CHARLIE readable procedure'
  WORDS_SCAN = 'DELTA ECHO FOXTROT scanned section'

  # 9x13 bitmap glyphs for every uppercase letter used by the words above, plus space.
  # '#' is an inked (black) pixel, '.' is background (white). The shapes are deliberately
  # thick and distinct (rounded O/C, diagonal A/V/X, waisted B/R) so Tesseract reads them
  # reliably; they are drawn font-free so OCR rasters never depend on an installed font.
  GLYPHS = {
    ' ' => ['.........', '.........', '.........', '.........', '.........', '.........', '.........', '.........', '.........', '.........',
            '.........', '.........', '.........'],
    'A' => ['....#....', '...###...', '..##.##..', '..##.##..', '.##...##.', '.##...##.', '.#######.', '.#######.', '##.....##', '##.....##',
            '##.....##', '##.....##', '##.....##'],
    'B' => ['#######..', '########.', '##.....##', '##.....##', '##.....##', '########.', '########.', '##.....##', '##.....##', '##.....##',
            '##.....##', '########.', '#######..'],
    'C' => ['..######.', '.#######.', '##.......', '##.......', '##.......', '##.......', '##.......', '##.......', '##.......', '##.......',
            '##.......', '.#######.', '..######.'],
    'D' => ['#######..', '########.', '##.....##', '##.....##', '##.....##', '##.....##', '##.....##', '##.....##', '##.....##', '##.....##',
            '##.....##', '########.', '#######..'],
    'E' => ['#########', '#########', '##.......', '##.......', '##.......', '#######..', '#######..', '##.......', '##.......', '##.......',
            '##.......', '#########', '#########'],
    'F' => ['#########', '#########', '##.......', '##.......', '##.......', '#######..', '#######..', '##.......', '##.......', '##.......',
            '##.......', '##.......', '##.......'],
    'H' => ['##.....##', '##.....##', '##.....##', '##.....##', '##.....##', '#########', '#########', '##.....##', '##.....##', '##.....##',
            '##.....##', '##.....##', '##.....##'],
    'I' => ['#########', '#########', '....#....', '....#....', '....#....', '....#....', '....#....', '....#....', '....#....', '....#....',
            '....#....', '#########', '#########'],
    'L' => ['##.......', '##.......', '##.......', '##.......', '##.......', '##.......', '##.......', '##.......', '##.......', '##.......',
            '##.......', '#########', '#########'],
    'O' => ['..#####..', '.#######.', '##.....##', '##.....##', '##.....##', '##.....##', '##.....##', '##.....##', '##.....##', '##.....##',
            '##.....##', '.#######.', '..#####..'],
    'P' => ['#######..', '########.', '##.....##', '##.....##', '##.....##', '########.', '#######..', '##.......', '##.......', '##.......',
            '##.......', '##.......', '##.......'],
    'R' => ['#######..', '########.', '##.....##', '##.....##', '##.....##', '########.', '#######..', '##..##...', '##...##..', '##....##.',
            '##.....##', '##.....##', '##.....##'],
    'T' => ['#########', '#########', '....#....', '....#....', '....#....', '....#....', '....#....', '....#....', '....#....', '....#....',
            '....#....', '....#....', '....#....'],
    'V' => ['##.....##', '##.....##', '##.....##', '##.....##', '.##...##.', '.##...##.', '.##...##.', '..##.##..', '..##.##..', '..##.##..',
            '...###...', '...###...', '....#....'],
    'X' => ['##.....##', '##.....##', '.##...##.', '..##.##..', '..##.##..', '...###...', '....#....', '...###...', '..##.##..', '..##.##..',
            '.##...##.', '##.....##', '##.....##']
  }.freeze

  GLYPH_W = 9
  GLYPH_H = 13
  PIXEL = 12    # each glyph pixel becomes a PIXEL x PIXEL block (large + crisp for Tesseract)
  GAP = 6       # blank glyph-columns between adjacent characters
  MARGIN = 140  # white border, in device pixels

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

  # Minimal single-page PDF with a Helvetica text run, hand-built as a fully valid
  # PDF-1.4 file: real object byte offsets, a conforming xref table (20-byte entries),
  # a trailer and a startxref that points at the xref. This is what pdfinfo/pdftotext
  # parse and what pdftoppm/pdfunite accept — no external PDF authoring dependency, and
  # no reliance on a reader reconstructing a missing cross-reference table.
  def build_text_pdf(text)
    # Escape the three PDF literal-string metacharacters so parentheses/backslashes in
    # the text can't terminate or corrupt the content stream.
    escaped = text.gsub(/[\\()]/) { |c| "\\#{c}" }
    stream = "BT /F1 32 Tf 72 700 Td (#{escaped}) Tj ET"

    bodies = []
    bodies << "1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n"
    bodies << "2 0 obj\n<</Type/Pages/Kids[3 0 R]/Count 1>>\nendobj\n"
    bodies << "3 0 obj\n<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]" \
              "/Resources<</Font<</F1 5 0 R>>>>/Contents 4 0 R>>\nendobj\n"
    bodies << "4 0 obj\n<</Length #{stream.bytesize}>>\nstream\n#{stream}\nendstream\nendobj\n"
    bodies << "5 0 obj\n<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>\nendobj\n"

    assemble_pdf(bodies)
  end

  # Assembles ordered object bodies (object 1..n) into a complete PDF-1.4 byte string:
  # header, bodies, a conforming xref (with the mandatory free object 0), trailer and a
  # startxref pointing at the xref. Everything is coerced to binary so an object body may
  # carry raw bytes (e.g. a FlateDecode image stream) without an encoding clash.
  def assemble_pdf(bodies)
    header = "%PDF-1.4\n".b
    bodies = bodies.map(&:b)

    offsets = []
    pos = header.bytesize
    bodies.each do |body|
      offsets << pos
      pos += body.bytesize
    end
    xref_offset = pos

    size = bodies.size + 1 # +1 for the mandatory free object 0
    xref = "xref\n0 #{size}\n0000000000 65535 f \n"
    offsets.each { |off| xref << format("%010d 00000 n \n", off) }
    trailer = "trailer\n<</Size #{size}/Root 1 0 R>>\nstartxref\n#{xref_offset}\n%%EOF\n"

    header + bodies.join.b + xref.b + trailer.b
  end

  # Renders the glyph-mapped (uppercase + space) words of `text` into a high-contrast
  # grayscale raster and returns [bytes, width, height]. Words with no glyph-mapped
  # characters (the lowercase filler) are dropped; the remaining words are joined by a
  # single space. Bytes are row-major 8-bit gray: 0xFF (white) background, 0x00 (black) ink.
  def render_raster(text) # rubocop:disable Metrics/AbcSize
    columns = glyph_columns(text)
    width = (columns.size * PIXEL) + (2 * MARGIN)
    height = (GLYPH_H * PIXEL) + (2 * MARGIN)

    rows = Array.new(height) { ("\xFF".b) * width }
    columns.each_with_index do |bits, cx|
      bits.each_with_index do |on, cy|
        next unless on

        x0 = MARGIN + (cx * PIXEL)
        y0 = MARGIN + (cy * PIXEL)
        PIXEL.times { |dy| rows[y0 + dy][x0, PIXEL] = ("\x00".b) * PIXEL }
      end
    end

    [rows.join, width, height]
  end

  # Expands `text` into a flat list of glyph-resolution columns (each a GLYPH_H-long
  # boolean array), inserting GAP blank columns after every character.
  def glyph_columns(text)
    words = text.split.map { |w| w.chars.select { |c| GLYPHS.key?(c) }.join }.reject(&:empty?)
    columns = []
    words.join(' ').each_char do |char|
      glyph = GLYPHS.fetch(char, GLYPHS[' '])
      (0...GLYPH_W).each do |col|
        columns << (0...GLYPH_H).map { |row| glyph[row][col] == '#' }
      end
      GAP.times { columns << Array.new(GLYPH_H, false) }
    end
    columns
  end

  # Serializes a grayscale raster as a binary PGM (P5) byte string.
  def pgm_bytes(bytes, width, height)
    "P5\n#{width} #{height}\n255\n".b + bytes
  end

  # Builds a text-free "scanned" single-page PDF entirely in Ruby: the grayscale raster is
  # FlateDecode-compressed (Zlib) and embedded as a DeviceGray image XObject, drawn to fill
  # a page sized to the raster. There is NO text layer, so PdfExtractor must fall back to OCR.
  def build_scanned_pdf(text)
    bytes, width, height = render_raster(text)
    stream = Zlib::Deflate.deflate(bytes)
    content = "q #{width} 0 0 #{height} 0 0 cm /Im0 Do Q"

    bodies = []
    bodies << "1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n"
    bodies << "2 0 obj\n<</Type/Pages/Kids[3 0 R]/Count 1>>\nendobj\n"
    bodies << "3 0 obj\n<</Type/Page/Parent 2 0 R/MediaBox[0 0 #{width} #{height}]" \
              "/Resources<</XObject<</Im0 5 0 R>>>>/Contents 4 0 R>>\nendobj\n"
    bodies << "4 0 obj\n<</Length #{content.bytesize}>>\nstream\n#{content}\nendstream\nendobj\n"
    bodies << ("5 0 obj\n<</Type/XObject/Subtype/Image/Width #{width}/Height #{height}" \
               '/ColorSpace/DeviceGray/BitsPerComponent 8/Filter/FlateDecode' \
               "/Length #{stream.bytesize}>>\nstream\n".b + stream + "\nendstream\nendobj\n".b)

    assemble_pdf(bodies)
  end

  around do |example|
    skip 'Poppler/Tesseract (eng+ind) + ImageMagick not installed' unless binaries_present?
    Dir.mktmpdir('sop-smoke') do |dir|
      @dir = dir
      example.run
    end
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

  def scanned_pdf(text, tag)
    path = File.join(@dir, "#{tag}.pdf")
    File.binwrite(path, build_scanned_pdf(text))
    path
  end

  # Draws `text` into a font-free PGM, then uses ImageMagick ONLY to transcode that PGM
  # into a real PNG/JPG (a raster-to-raster conversion — no font, no PDF delegate).
  def image_fixture(text, prefix, format)
    bytes, width, height = render_raster(text)
    pgm = File.join(@dir, "#{prefix}.pgm")
    File.binwrite(pgm, pgm_bytes(bytes, width, height))

    ext = format == :jpeg ? 'jpg' : 'png'
    out = File.join(@dir, "#{prefix}.#{ext}")
    run!(imagemagick_bin, pgm, out)
    raise 'imagemagick produced no raster' unless File.file?(out)

    out
  end

  # Stage the fixture INTO the runner's private workspace and grant the dropped
  # marine_sop user read access, mirroring ExtractionService#call. Without an active
  # privilege drop grant_read is a no-op; WITH one (base+installer, running as root)
  # this is exactly what lets the su-exec'd Poppler/Tesseract open the input from the
  # group-accessible workspace — so the smoke drives the real privilege-dropped path.
  def staged_source(runner, path)
    dest = runner.workspace_path(File.basename(path))
    FileUtils.cp(path, dest)
    runner.grant_read(dest)
    dest
  end

  def extract_pdf(path)
    Marine::Documents::CommandRunner.open do |runner|
      Marine::Documents::Sop::PdfExtractor.new(path: staged_source(runner, path), runner: runner).call
    end
  end

  def extract_image(path)
    Marine::Documents::CommandRunner.open do |runner|
      Marine::Documents::Sop::ImageOcrService.new(path: staged_source(runner, path), runner: runner).call
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
    png = image_fixture(WORDS_TEXT, 'png', :png)

    result = extract_image(png)

    expect(result.processing_method).to eq('image_ocr')
    expect(result.page_count).to eq(1)
    expect(result.content.upcase).to include('BRAVO')
  end

  it 'OCRs a rendered JPG raster (image_ocr) via Tesseract' do
    jpg = image_fixture(WORDS_TEXT, 'jpg', :jpeg)

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
