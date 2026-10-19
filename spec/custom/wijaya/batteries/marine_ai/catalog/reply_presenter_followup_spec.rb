# frozen_string_literal: true

require 'rails_helper'

# MVP dynamic follow-up (needs question) on the deterministic legacy product-listing reply.
# After enumerating the DB-derived template rows, the reply ALWAYS ends with a factless,
# question-only needs follow-up so the assistant can recommend: it names no product, price,
# stock, quantity, or brand, and adds no completeness claim (the has_more suffix stays the
# ONLY completeness wording). It appears for BOTH the scoped and the broad listing intro, and
# on both the complete and the has_more page shapes.
RSpec.describe Marine::Catalog::ReplyPresenter do
  describe 'product_listing follow-up question' do
    let(:scoped_plan) do
      { action: :reply, reply: { kind: :product_listing, item_group: 'Kain',
                                 products: [{ code: 'KAIN-01', name: 'Katun' }, { code: 'KAIN-02', name: 'Denim' }],
                                 has_more: false, total_count: 2 } }
    end

    it 'appends the needs question after a complete scoped listing' do
      text = described_class.new.reply_text(scoped_plan)

      expect(text).to start_with('Here are the Kain products we currently offer:')
      expect(text).to include('Katun', 'Denim')
      expect(text).not_to include('KAIN-01', 'KAIN-02')
      expect(text).to end_with(described_class::PRODUCT_LISTING_NEEDS_QUESTION)
    end

    it 'keeps the has_more suffix BEFORE the needs question so completeness wording stays first' do
      plan = scoped_plan.merge(reply: scoped_plan[:reply].merge(has_more: true, total_count: 20))

      text = described_class.new.reply_text(plan)

      expect(text).to include(described_class::PRODUCT_LISTING_MORE_SUFFIX)
      expect(text).to end_with(described_class::PRODUCT_LISTING_NEEDS_QUESTION)
      expect(text.index(described_class::PRODUCT_LISTING_MORE_SUFFIX))
        .to be < text.index(described_class::PRODUCT_LISTING_NEEDS_QUESTION)
    end

    it 'appends the same question after the broad (unscoped) listing intro' do
      plan = scoped_plan.merge(reply: scoped_plan[:reply].merge(item_group: nil))

      text = described_class.new.reply_text(plan)

      expect(text).to start_with('Here are the products we currently offer:')
      expect(text).to end_with(described_class::PRODUCT_LISTING_NEEDS_QUESTION)
    end

    it 'does NOT add the needs question to the empty-listing line (nothing to follow up on)' do
      plan = { action: :reply, reply: { kind: :product_listing, item_group: nil, products: [], has_more: false } }

      text = described_class.new.reply_text(plan)

      expect(text).to eq(described_class::PRODUCT_LISTING_EMPTY_TEXT)
    end
  end
end
