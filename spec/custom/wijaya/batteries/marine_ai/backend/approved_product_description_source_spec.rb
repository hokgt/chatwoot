# frozen_string_literal: true

require 'rails_helper'

# Phase 3 — the approved-only, assistant-scoped product-description evidence source. It binds a RAG
# description to an ALREADY catalog-authorized listing page by extracting the approved chunk(s) that name
# the product's EXACT normalized code/name at Unicode alphanumeric boundaries. It never adds a product,
# loads the approved candidate corpus in ONE bounded query, rejects chunks that name a second authorized
# product (cross-contamination), and fails closed on a missing assistant / malformed page / ambiguous or
# conflicting evidence. The knowledge base is injected so no DB is touched; records are lightweight
# question/answer doubles.
RSpec.describe Marine::Backend::ApprovedProductDescriptionSource do
  subject(:source) { described_class.new(assistant: assistant, knowledge_base: knowledge_base) }

  let(:assistant) { double('assistant', id: 1) }
  let(:knowledge_base) { instance_double(Marine::Cell::KnowledgeBaseService) }
  let(:page) { [{ code: 'AAA', name: 'Alpha' }, { code: 'BBB', name: 'Bravo' }] }

  def record(question, answer)
    double('AssistantResponse', question: question, answer: answer)
  end

  def stub_corpus(records)
    allow(knowledge_base).to receive(:approved_mentioning).and_return(records)
  end

  it 'binds a description from the ANSWER chunk that names the product by exact code' do
    stub_corpus([record('Tell me about it', 'AAA is a soft cotton tee.')])
    expect(source.call(page)).to eq('AAA' => 'AAA is a soft cotton tee.')
  end

  it 'binds a description from a QUESTION chunk that names the product by exact code' do
    stub_corpus([record('What material is AAA made of?', 'Various fabrics are used.')])
    expect(source.call(page)).to eq('AAA' => 'What material is AAA made of?')
  end

  it 'binds by exact normalized NAME (case/space-insensitive) too' do
    stub_corpus([record('Catalog', '  The Bravo is a durable canvas bag. ')])
    expect(source.call(page)).to eq('BBB' => 'The Bravo is a durable canvas bag.')
  end

  it 'extracts ONLY the product-specific chunk from a multi-product answer (no whole-response attach)' do
    stub_corpus([record('Catalog', 'AAA is a soft cotton tee. Bravo is a durable canvas bag.')])
    expect(source.call(page)).to eq('AAA' => 'AAA is a soft cotton tee.', 'BBB' => 'Bravo is a durable canvas bag.')
  end

  it 'rejects a partial substring match (AAA must not bind from AAAB)' do
    stub_corpus([record('Catalog', 'AAAB is an unrelated internal code.')])
    expect(source.call(page)).to eq({})
  end

  it 'rejects a chunk that names TWO authorized products rather than cross-contaminating' do
    stub_corpus([record('Catalog', 'AAA and Bravo ship together as a bundle.')])
    expect(source.call(page)).to eq({})
  end

  it 'loads the approved corpus in ONE bounded query over the page code/name keys (no N+1)' do
    stub_corpus([])
    source.call(page)
    expect(knowledge_base).to have_received(:approved_mentioning).once.with(%w[AAA Alpha BBB Bravo])
  end

  it 'NEVER adds a product: a chunk naming only an off-page product is ignored' do
    stub_corpus([record('Catalog', 'CCC is not on the page.'), record('Catalog', 'AAA is here.')])
    result = source.call(page)
    expect(result.keys).to contain_exactly('AAA')
    expect(result).not_to have_key('CCC')
  end

  it 'fails closed (skips the product) on CONFLICTING approved snippets across rows for the same product' do
    stub_corpus([record('q1', 'AAA is red.'), record('q2', 'AAA is blue.')])
    expect(source.call(page)).to eq({})
  end

  it 'binds once when two rows agree verbatim on the same product snippet' do
    stub_corpus([record('q1', 'AAA is a soft cotton tee.'), record('q2', 'AAA is a soft cotton tee.')])
    expect(source.call(page)).to eq('AAA' => 'AAA is a soft cotton tee.')
  end

  it 'byte-bounds an oversized snippet rather than passing unbounded prose' do
    stub_corpus([record('AAA', "#{'x' * 1000} AAA")])
    bound = source.call(page)['AAA']
    expect(bound.bytesize).to eq(described_class::MAX_DESCRIPTION_BYTES)
  end

  it 'ignores a record whose chunks name no authorized product' do
    stub_corpus([record('Hours', 'We are open nine to five.')])
    expect(source.call(page)).to eq({})
  end

  it 'returns {} without querying when the assistant is missing' do
    kb = instance_double(Marine::Cell::KnowledgeBaseService)
    expect(described_class.new(assistant: nil, knowledge_base: kb).call(page)).to eq({})
    expect(kb).not_to have_received(:approved_mentioning) if kb.respond_to?(:approved_mentioning)
  end

  it 'returns {} on a malformed product page (fail closed)' do
    expect(source.call(nil)).to eq({})
    expect(source.call([])).to eq({})
    expect(source.call([{ name: 'no code' }])).to eq({})
  end

  it 'returns {} (never raises) when the knowledge base errors' do
    allow(knowledge_base).to receive(:approved_mentioning).and_raise(StandardError, 'boom')
    expect(source.call(page)).to eq({})
  end
end
