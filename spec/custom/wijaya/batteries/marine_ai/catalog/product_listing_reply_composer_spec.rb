# frozen_string_literal: true

require 'rails_helper'

# WIJAYA_CUSTOM_START: dynamic-listing-wording
RSpec.describe 'Marine product-listing dynamic wording' do
  let(:descriptor) do
    {
      kind: :product_listing,
      products: [{ code: 'AAA', name: 'Alpha' }, { code: 'BBB', name: 'Bravo' }],
      returned_count: 2,
      total_count: 2,
      complete: true,
      has_more: false
    }.freeze
  end
  let(:fallback) do
    'Here are the products we currently offer: Alpha, Bravo.' \
      "#{Marine::Catalog::ReplyPresenter::PRODUCT_LISTING_NEEDS_QUESTION}"
  end
  let(:natural_candidate) do
    'Pilihan kami mencakup Alpha dan Bravo. Produk ini akan digunakan untuk kebutuhan apa ' \
      'agar saya dapat membantu merekomendasikan yang sesuai?'
  end
  let(:generator) { ->(**) { natural_candidate } }
  let(:fact_verifier) { ->(**) { true } }

  def composer(**overrides)
    klass = Marine::Catalog.const_get(:ProductListingReplyComposer)
    klass.new(account: nil, generator: generator, fact_verifier: fact_verifier, **overrides)
  end

  it 'accepts provider-generated natural wording that differs from the deterministic fixed CTA' do
    text = composer.compose(descriptor: descriptor, fallback: fallback, reply_language: 'id')

    expect(text).to eq(natural_candidate)
    expect(text).not_to eq(fallback)
    expect(text).not_to include(Marine::Catalog::ReplyPresenter::PRODUCT_LISTING_NEEDS_QUESTION.strip)
  end

  it 'rejects internal objective identifiers before an accepting semantic verifier can authorize them' do
    verifier = ->(**) { true }

    %w[response_objective ask_customer_intended_need_for_product_recommendation].each do |identifier|
      candidate = "#{natural_candidate} #{identifier}"
      text = composer(generator: ->(**) { candidate }, fact_verifier: verifier).compose(
        descriptor: descriptor, fallback: fallback, reply_language: 'id'
      )

      expect(text).to eq(fallback)
    end
  end

  it 'passes only bounded structured listing facts, target language, and the closed needs objective to generation' do
    captured = {}
    generating = lambda do |**input|
      captured.replace(input)
      natural_candidate
    end

    composer(generator: generating).compose(descriptor: descriptor, fallback: fallback, reply_language: 'id')

    expect(captured).to include(:system, :messages)
    prompt = captured.fetch(:messages).fetch(0).fetch(:content)
    expect(prompt).to include('Alpha', 'Bravo', 'returned_count', 'total_count', 'complete', 'has_more',
                              'target_language', 'ask_customer_intended_need')
    expect(prompt).not_to include('AAA', 'BBB')
    expect(prompt).not_to include('SELECT', 'warehouse', 'credential', fallback)
  end

  it 'requires every product name exactly once and rejects internal item codes' do
    invalid = [
      natural_candidate.sub(' dan Bravo', ''),
      natural_candidate.sub('Bravo', 'Bravo dan Bravo'),
      natural_candidate.sub('Bravo', 'Charlie'),
      natural_candidate.sub('Alpha', 'Bravo'),
      natural_candidate.sub('Alpha', 'Alpha (AAA)')
    ]

    invalid.each do |candidate|
      text = composer(generator: ->(**) { candidate }).compose(
        descriptor: descriptor, fallback: fallback, reply_language: 'id'
      )
      expect(text).to eq(fallback)
    end
  end

  it 'preserves incomplete counts and rejects a false completeness claim through the semantic verifier' do
    incomplete = descriptor.merge(total_count: 9, complete: false, has_more: true).freeze
    valid = 'Berikut 2 dari 9 produk: Alpha dan Bravo. Akan digunakan untuk kebutuhan apa agar saya dapat merekomendasikan yang sesuai?'
    captured_packet = nil
    verifier = lambda do |packet:, **|
      captured_packet = packet
      true
    end

    expect(composer(generator: ->(**) { valid }, fact_verifier: verifier).compose(
             descriptor: incomplete, fallback: fallback, reply_language: 'id'
           )).to eq(valid)
    expect(captured_packet.dig(:facts, :product_listing)).to include(
      returned_count: 2, total_count: 9, complete: false, has_more: true
    )

    false_more = 'Alpha dan Bravo adalah sebagian dari lebih banyak produk. Akan digunakan untuk kebutuhan apa?'
    rejected = composer(generator: ->(**) { false_more }, fact_verifier: ->(**) { false }).compose(
      descriptor: descriptor, fallback: fallback, reply_language: 'id'
    )
    expect(rejected).to eq(fallback)
  end

  it 'fails closed on forbidden price, stock quantity, location, delivery, and additional-product claims' do
    candidates = [
      "#{natural_candidate} Harganya 100.",
      "#{natural_candidate} Stoknya 50 unit.",
      "#{natural_candidate} Tersedia di gudang Jakarta.",
      "#{natural_candidate} Pengiriman besok.",
      natural_candidate.sub('Bravo', 'Bravo dan Charlie')
    ]

    candidates.each do |candidate|
      semantic = ->(**) { !candidate.match?(/gudang|Pengiriman|Charlie/) }
      expect(composer(generator: ->(**) { candidate }, fact_verifier: semantic).compose(
               descriptor: descriptor, fallback: fallback, reply_language: 'id'
             )).to eq(fallback)
    end
  end

  it 'uses the exact deterministic fallback for unsupported/wrong language, provider failure or blank, and validator rejection' do
    unsupported_generator = ->(**) { natural_candidate }
    expect(unsupported_generator).not_to receive(:call)
    expect(composer(generator: unsupported_generator).compose(
             descriptor: descriptor, fallback: fallback, reply_language: 'fr'
           )).to eq(fallback)

    [nil, '   '].each do |generated|
      expect(composer(generator: ->(**) { generated }).compose(
               descriptor: descriptor, fallback: fallback, reply_language: 'id'
             )).to eq(fallback)
    end

    expect(composer(fact_verifier: ->(**) { false }).compose(
             descriptor: descriptor, fallback: fallback, reply_language: 'id'
           )).to eq(fallback)
  end

  it 'does not generate for an empty listing and preserves the existing no-CTA fallback' do
    empty = descriptor.merge(products: [], returned_count: 0, total_count: 0).freeze
    no_cta = Marine::Catalog::ReplyPresenter::PRODUCT_LISTING_EMPTY_TEXT
    expect(generator).not_to receive(:call)

    expect(composer.compose(descriptor: empty, fallback: no_cta, reply_language: 'id')).to eq(no_cta)
  end
end
# WIJAYA_CUSTOM_END: dynamic-listing-wording
