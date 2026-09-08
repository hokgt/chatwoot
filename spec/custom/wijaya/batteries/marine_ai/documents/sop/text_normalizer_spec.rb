# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Documents::Sop::TextNormalizer do
  def normalize(text) = described_class.new(text).call

  it 'returns valid UTF-8 and scrubs invalid byte sequences' do
    result = normalize("valid \xFF\xFE text".b)
    expect(result.encoding).to eq(Encoding::UTF_8)
    expect(result).to be_valid_encoding
    expect(result).to include('valid')
    expect(result).to include('text')
  end

  it 'removes NUL and other ASCII control characters but keeps newline and tab content' do
    result = normalize("a\x00b\x07c\nsecond line")
    expect(result).not_to include("\x00")
    expect(result).not_to include("\x07")
    expect(result).to eq("abc\nsecond line")
  end

  it 'normalizes CRLF and CR line endings to LF' do
    expect(normalize("one\r\ntwo\rthree")).to eq("one\ntwo\nthree")
  end

  it 'collapses runs of horizontal whitespace (spaces, tabs, NBSP) to a single space' do
    expect(normalize("a\t\t b\u00A0\u00A0c")).to eq('a b c')
  end

  it 'trims horizontal whitespace around line breaks' do
    expect(normalize("line one   \n   line two")).to eq("line one\nline two")
  end

  it 'preserves paragraphs while collapsing excess blank lines (and drops empty regions)' do
    expect(normalize("para one\n\n\n\n\npara two")).to eq("para one\n\npara two")
  end

  it 'strips leading and trailing whitespace overall' do
    expect(normalize("\n\n  hello  \n\n")).to eq('hello')
  end

  it 'hard-caps the output at 200,000 characters' do
    result = normalize('x' * 250_000)
    expect(result.length).to eq(200_000)
  end

  it 'returns an empty string for blank or control-only input' do
    expect(normalize("\x00\x00\n   \n")).to eq('')
    expect(normalize(nil)).to eq('')
  end
end
