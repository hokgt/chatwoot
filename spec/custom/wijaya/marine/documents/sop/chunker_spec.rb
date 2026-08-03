# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Documents::Sop::Chunker do
  def chunks(text, **options)
    described_class.new(text, **options).call
  end

  it 'returns no chunks for nil or whitespace-only input' do
    expect(chunks(nil)).to eq([])
    expect(chunks(%Q( \t\n\n ))).to eq([])
  end

  it 'keeps short text in one chunk and normalizes only horizontal whitespace' do
    expect(chunks(%Q(  First\tstep.\n\nSecond   step.  ))).to eq(['First step. Second step.'])
  end

  it 'prefers sentence boundaries before hard splitting oversized text' do
    result = chunks('First sentence. Second sentence. Third.', max_chars: 22, overlap: 0)
    expect(result).to eq(['First sentence.', 'Second sentence.', 'Third.'])
    expect(result).to all(satisfy { |value| value.scan(/\X/).length <= 22 })
  end

  it 'hard-splits oversized sentences on Unicode grapheme boundaries' do
    text = '👩🏽‍💻' * 13
    result = chunks(text, max_chars: 5, overlap: 0)
    expect(result.map { |value| value.scan(/\X/).length }).to all(be <= 5)
    expect(result.join).to eq(text)
    expect(result).to all(satisfy(&:valid_encoding?))
  end

  it 'adds deterministic bounded overlap while preserving order' do
    text = 'abcdefghij. klmnopqrst. uvwxyz.'
    first = chunks(text, max_chars: 15, overlap: 3)
    second = chunks(text, max_chars: 15, overlap: 3)

    expect(second).to eq(first)
    expect(first.length).to be > 1
    expect(first[1]).to start_with("#{first[0].scan(/\X/).last(3).join} ")
    expect(first).to all(satisfy { |value| value.scan(/\X/).length <= 15 })
  end

  it 'caps input and emitted chunk count without looping' do
    expect(chunks('abcdefghijk', max_chars: 50, overlap: 0, max_input_chars: 7)).to eq(['abcdefg'])
    result = chunks('a' * 100, max_chars: 5, overlap: 0, max_chunks: 3)
    expect(result.length).to eq(3)
  end

  it 'uses bounds compatible with the Marine document content limit' do
    expect(described_class::MAX_INPUT_CHARS).to eq(Marine::Document::MAX_CONTENT_CHARS)
    expect(described_class::MAX_CHUNKS).to be_positive
    expect(described_class::OVERLAP_CHARS).to be < described_class::MAX_CHARS
  end
end
