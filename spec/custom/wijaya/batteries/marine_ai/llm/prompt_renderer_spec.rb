# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Llm::PromptRenderer do
  it 'interpolates variables from the context' do
    result = described_class.render('Hello {{ name }}', name: 'Marine')
    expect(result).to eq('Hello Marine')
  end

  it 'accepts symbol and string keys' do
    result = described_class.render('{{ a }}-{{ b }}', { :a => 1, 'b' => 2 })
    expect(result).to eq('1-2')
  end

  it 'returns the raw template when it is blank' do
    expect(described_class.render('')).to eq('')
    expect(described_class.render(nil)).to eq('')
  end

  it 'degrades to the raw template on a Liquid syntax error' do
    template = 'Hello {{ name'
    expect(described_class.render(template, name: 'x')).to eq(template)
  end
end
