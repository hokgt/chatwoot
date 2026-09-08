# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Catalog::ReplyPresenter do
  subject(:presenter) { described_class.new }

  let(:renderer) { Marine::Catalog::ReplyRenderer.new }

  def plan(action:, reply: nil, changes: {})
    { action: action, reply: reply, state: { operation: :none, changes: changes } }
  end

  describe '#reply_text' do
    it 'renders a direct catalog caption from the row-derived family' do
      descriptor = renderer.catalog(code: 'BD', name: 'Baby Doll')
      expect(presenter.reply_text(plan(action: :send_catalog, reply: descriptor)))
        .to eq('Here is the product catalog for Baby Doll.')
    end

    it 'renders parent info' do
      descriptor = renderer.parent_info(code: 'BD', name: 'Baby Doll')
      expect(presenter.reply_text(plan(action: :reply, reply: descriptor)))
        .to eq("You're asking about Baby Doll. Which specific variant would you like to know about?")
    end

    it 'renders variant info' do
      descriptor = renderer.variant_info({ code: 'BD', name: 'Baby Doll' }, 'BD-RED')
      expect(presenter.reply_text(plan(action: :reply, reply: descriptor)))
        .to eq('Here are the details for BD-RED. Would you like the price or availability?')
    end

    it 'renders an available price from ONLY the three approved fields plus the variant code' do
      descriptor = renderer.price_available({ price_list_rate: '125.50', currency: 'USD', uom: 'Nos' }, 'BD-RED')
      expect(presenter.reply_text(plan(action: :reply, reply: descriptor)))
        .to eq('The price for BD-RED is USD 125.50 per Nos.')
    end

    it 'renders the static price_unavailable template' do
      expect(presenter.reply_text(plan(action: :reply, reply: renderer.price_unavailable)))
        .to eq("I'm sorry, I don't have the price for that item right now.")
    end

    it 'names the validated variant code in the binary stock templates' do
      # The available line leads with the code and a plain definite statement (no fixed upbeat opener)
      # so ordinary availability replies stop reading as one canned "Good news — ..." sentence.
      expect(presenter.reply_text(plan(action: :reply, reply: renderer.stock_available('BD-RED'))))
        .to eq('BD-RED is currently in stock.')
      expect(presenter.reply_text(plan(action: :reply, reply: renderer.stock_empty('BD-RED'))))
        .to eq("I'm sorry, BD-RED is currently out of stock.")
    end

    it 'falls back to the product-agnostic stock line when no usable code is present' do
      expect(presenter.reply_text(plan(action: :reply, reply: { kind: :stock_available, variant_code: nil })))
        .to eq('Good news — that item is currently in stock.')
      expect(presenter.reply_text(plan(action: :reply, reply: { kind: :stock_empty, variant_code: '  ' })))
        .to eq("I'm sorry, that item is currently out of stock.")
    end

    it 'renders family clarification with candidates and an empty fallback' do
      descriptor = renderer.clarify_family([{ code: 'BD', name: 'Baby Doll' }, { code: 'BP', name: 'Baby Doll Printing' }])
      expect(presenter.reply_text(plan(action: :clarify_family, reply: descriptor)))
        .to eq('Could you let me know which product you mean? For example: Baby Doll, Baby Doll Printing.')

      expect(presenter.reply_text(plan(action: :clarify_family, reply: renderer.clarify_family([]))))
        .to eq('Could you tell me which product you are interested in?')
    end

    it 'renders variant clarification with attribute names and an empty fallback' do
      descriptor = renderer.clarify_variant(%w[size material])
      expect(presenter.reply_text(plan(action: :clarify_variant, reply: descriptor)))
        .to eq('Could you specify the size, material you need?')

      expect(presenter.reply_text(plan(action: :clarify_variant, reply: renderer.clarify_variant([]))))
        .to eq('Could you specify which variant you are interested in?')
    end

    it 'renders a catalog-ASSISTED send_catalog (reply nil) as the variant clarification from expected_attributes' do
      built = plan(action: :send_catalog, reply: nil, changes: { 'expected_attributes' => %w[size color] })
      expect(presenter.reply_text(built)).to eq('Could you specify the size, color you need?')
    end

    it 'falls back to the generic product prompt for an unknown descriptor' do
      expect(presenter.reply_text(plan(action: :reply, reply: { kind: :something_new })))
        .to eq('Could you share a little more detail about the product you need?')
    end
  end

  describe '#direct_catalog_request?' do
    it 'is true only for a :catalog reply descriptor' do
      expect(presenter.direct_catalog_request?(plan(action: :send_catalog, reply: renderer.catalog(code: 'BD', name: 'Baby Doll')))).to be(true)
      expect(presenter.direct_catalog_request?(plan(action: :send_catalog, reply: nil))).to be(false)
      expect(presenter.direct_catalog_request?(plan(action: :reply, reply: renderer.parent_info(code: 'BD', name: 'Baby Doll')))).to be(false)
    end
  end

  describe '#direct_catalog_fallback_text' do
    it 'states no catalog is available when none was sent' do
      expect(presenter.direct_catalog_fallback_text({ family_code: 'BD', family_name: 'Baby Doll' }, already_sent: false))
        .to eq("I'm sorry, I don't have a catalog available for Baby Doll right now.")
    end

    it 'says it was already shared when already sent' do
      expect(presenter.direct_catalog_fallback_text({ family_code: 'BD', family_name: 'Baby Doll' }, already_sent: true))
        .to eq("I've already shared the Baby Doll catalog with you above.")
    end

    it 'falls back to a generic family label when no name/code is present' do
      expect(presenter.direct_catalog_fallback_text({}, already_sent: false))
        .to eq("I'm sorry, I don't have a catalog available for that product right now.")
    end
  end

  describe 'Playground catalog preview lines (never claim a file was delivered)' do
    it 'states the catalog is available and would be shared, for a first preview' do
      expect(presenter.catalog_preview_available_text({ family_code: 'BD', family_name: 'Baby Doll' }))
        .to eq('The Baby Doll catalog is available and would be shared with the customer in a full conversation.')
    end

    it 'states the preview is already shown (NOT "already shared a file") on a repeat' do
      text = presenter.catalog_preview_already_shown_text({ family_code: 'BD', family_name: 'Baby Doll' })
      expect(text).to eq(
        'The Baby Doll catalog preview is already shown above; the file would be shared in a full conversation.'
      )
      expect(text).not_to include('already shared')
    end

    it 'falls back to a generic family label when no name/code is present' do
      expect(presenter.catalog_preview_already_shown_text({}))
        .to eq('The that product catalog preview is already shown above; the file would be shared in a full conversation.')
    end
  end

  describe '#handoff_ack_text' do
    it 'returns the category-aware factless line for a known category' do
      expect(presenter.handoff_ack_text('exact_quantity'))
        .to eq("I'm sorry, I can't confirm the exact quantity available for you directly. Let me bring in a colleague to help with this.")
    end

    it 'falls closed to the fully generic line for an unknown/missing category' do
      expect(presenter.handoff_ack_text('other')).to eq(described_class::HANDOFF_ACK_TEXT)
      expect(presenter.handoff_ack_text(nil)).to eq(described_class::HANDOFF_ACK_TEXT)
    end
  end
end
