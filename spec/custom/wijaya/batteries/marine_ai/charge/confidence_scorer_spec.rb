# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Charge::ConfidenceScorer do
  let(:response) { double('response', question: 'What are your opening hours?', answer: 'We are open from 9 to 5.') }

  it 'returns 1.0 on an exact question match' do
    expect(described_class.score(query: 'What are your opening hours?', response: response)).to eq(1.0)
  end

  it 'returns 0.0 for a blank query' do
    expect(described_class.score(query: '', response: response)).to eq(0.0)
  end

  it 'returns 0.0 when the response is nil' do
    expect(described_class.score(query: 'hours', response: nil)).to eq(0.0)
  end

  it 'scores partial token overlap within the 0..1 range' do
    score = described_class.score(query: 'opening hours', response: response)
    expect(score).to be > 0.0
    expect(score).to be <= 1.0
  end

  it 'blends and clamps vector distance when provided' do
    score = described_class.score(query: 'totally unrelated question', response: response, distance: 0.2)
    expect(score).to be_between(0.0, 1.0)
  end
end
