# frozen_string_literal: true

require 'rails_helper'

# Phase 6 — the deterministic protected-fact/value checker. It is the FIRST, generic,
# fail-closed gate an untrusted natural-wording candidate must pass before any semantic
# validation: an explicit action+kind allowlist, protected display-value presence in BOTH
# the deterministic fallback and candidate, and identical numeric/currency/identifier/
# uppercase-code token inventories. It carries no product/language data and never raises.
RSpec.describe Marine::Catalog::ProductFactProtectionValidator do
  subject(:checker) { described_class.new }

  # Terse wrappers so intent (accept vs reject a given descriptor/text pair) stays legible.
  def accepts?(descriptor, fallback, candidate, action: :reply)
    checker.accepts?(action: action, descriptor: descriptor, fallback: fallback, candidate: candidate)
  end

  def eligible?(descriptor, action: :reply)
    checker.eligible?(action: action, descriptor: descriptor)
  end

  describe '#eligible? (action + descriptor-kind allowlist)' do
    it 'accepts every supported kind only under its one allowed action' do
      expect(eligible?({ kind: :parent_info, family_code: 'IMP', family_name: 'Impeller' })).to be(true)
      expect(eligible?({ kind: :variant_info, family_code: 'IMP', variant_code: 'IMP-3' })).to be(true)
      expect(eligible?({ kind: :stock_available })).to be(true)
      expect(eligible?({ kind: :stock_empty })).to be(true)
      expect(eligible?({ kind: :price_available, price_list_rate: '150000', currency: 'IDR', uom: 'pcs' })).to be(true)
      expect(eligible?({ kind: :clarify_family, candidates: [{ code: 'IMP', name: 'Impeller' }] }, action: :clarify_family)).to be(true)
      expect(eligible?({ kind: :clarify_variant, attribute_names: %w[size] }, action: :clarify_variant)).to be(true)
    end

    it 'rejects a supported kind presented under the wrong product action' do
      expect(eligible?({ kind: :parent_info, family_code: 'IMP', family_name: 'Impeller' }, action: :clarify_family)).to be(false)
      expect(eligible?({ kind: :stock_available }, action: :clarify_variant)).to be(false)
      expect(eligible?({ kind: :clarify_family, candidates: [] })).to be(false)
    end

    it 'rejects every deliberately excluded kind' do
      %i[price_unavailable price_conflict stock_unavailable catalog catalog_unavailable unsupported].each do |kind|
        expect(eligible?({ kind: kind })).to be(false)
      end
    end

    it 'rejects a non-hash / kindless / unknown-kind descriptor' do
      expect(eligible?('nope')).to be(false)
      expect(eligible?({ family_code: 'IMP' })).to be(false)
      expect(eligible?({ kind: :made_up })).to be(false)
    end
  end

  describe '#accepts? — Tier 1 non-price descriptors and clarifications' do
    it 'accepts an equivalent parent_info candidate that preserves the family display value' do
      descriptor = { kind: :parent_info, family_code: 'IMP', family_name: 'Impeller' }
      fallback = "You're asking about Impeller. Which specific variant would you like to know about?"
      candidate = 'About Impeller — which specific variant do you want to know about?'
      expect(accepts?(descriptor, fallback, candidate)).to be(true)
    end

    it 'falls back to the family CODE when the name is blank, and protects it' do
      descriptor = { kind: :parent_info, family_code: 'IMP', family_name: nil }
      fallback = "You're asking about IMP. Which specific variant would you like to know about?"
      expect(accepts?(descriptor, fallback, 'You are asking about IMP — which variant would you like?')).to be(true)
      expect(accepts?(descriptor, fallback, 'You are asking about that product — which variant?')).to be(false)
    end

    it 'rejects a parent_info candidate that omits or changes the family' do
      descriptor = { kind: :parent_info, family_code: 'IMP', family_name: 'Impeller' }
      fallback = "You're asking about Impeller. Which specific variant would you like to know about?"
      expect(accepts?(descriptor, fallback, 'Which specific variant would you like?')).to be(false)
      expect(accepts?(descriptor, fallback, 'About Propeller — which variant?')).to be(false)
    end

    it 'accepts an equivalent variant_info candidate and rejects an altered variant code' do
      descriptor = { kind: :variant_info, family_code: 'IMP', variant_code: 'AB12' }
      fallback = 'Here are the details for AB12. Would you like the price or availability?'
      expect(accepts?(descriptor, fallback, 'Details for AB12 are ready — want the price or availability?')).to be(true)
      expect(accepts?(descriptor, fallback, 'Details for AB13 are ready — want the price or availability?')).to be(false)
    end

    it 'accepts an equivalent clarify_family candidate and rejects a dropped candidate' do
      descriptor = { kind: :clarify_family, candidates: [{ code: 'IMP', name: 'Impeller' }, { code: 'PMP', name: 'Pump' }] }
      fallback = 'Could you let me know which product you mean? For example: Impeller, Pump.'
      expect(accepts?(descriptor, fallback, 'Which product do you mean — Impeller or Pump?', action: :clarify_family)).to be(true)
      expect(accepts?(descriptor, fallback, 'Which product do you mean — Impeller?', action: :clarify_family)).to be(false)
    end

    it 'rejects a clarify_family descriptor whose candidates render a duplicate (ambiguous) value' do
      descriptor = { kind: :clarify_family, candidates: [{ code: 'IMP', name: 'Impeller' }, { code: 'IMP2', name: 'Impeller' }] }
      fallback = 'Could you let me know which product you mean? For example: Impeller, Impeller.'
      expect(eligible?(descriptor, action: :clarify_family)).to be(false)
      expect(accepts?(descriptor, fallback, 'Impeller or Impeller?', action: :clarify_family)).to be(false)
    end

    it 'accepts an equivalent clarify_variant candidate and rejects a dropped attribute' do
      descriptor = { kind: :clarify_variant, attribute_names: %w[size material] }
      fallback = 'Could you specify the size, material you need?'
      expect(accepts?(descriptor, fallback, 'What size and material do you need?', action: :clarify_variant)).to be(true)
      expect(accepts?(descriptor, fallback, 'What size do you need?', action: :clarify_variant)).to be(false)
    end

    it 'rejects a clarify_variant descriptor with a blank or non-array attribute list' do
      expect(eligible?({ kind: :clarify_variant, attribute_names: ['size', ''] }, action: :clarify_variant)).to be(false)
      expect(eligible?({ kind: :clarify_variant, attribute_names: 'size' }, action: :clarify_variant)).to be(false)
    end
  end

  describe '#accepts? — Tier 2 stock outcomes (no quantity may leak)' do
    it 'accepts an equivalent stock candidate carrying no numeric quantity' do
      available = 'Good news — that item is currently in stock.'
      empty = "I'm sorry, that item is currently out of stock."
      expect(accepts?({ kind: :stock_available }, available, 'That item is in stock right now.')).to be(true)
      expect(accepts?({ kind: :stock_empty }, empty, 'That item is out of stock at the moment.')).to be(true)
    end

    it 'rejects a stock candidate that injects a quantity number' do
      fallback = 'Good news — that item is currently in stock.'
      expect(accepts?({ kind: :stock_available }, fallback, 'Good news — 5 units are in stock.')).to be(false)
    end

    it 'rejects a stock kind under an unsupported action' do
      expect(accepts?({ kind: :stock_available }, 'In stock.', 'In stock.', action: :clarify_family)).to be(false)
    end
  end

  describe '#accepts? — Tier 3 price_available (exact amount/currency/UOM + token inventory)' do
    let(:descriptor) { { kind: :price_available, price_list_rate: '150000', currency: 'IDR', uom: 'pcs' } }
    let(:fallback) { 'The price is IDR 150000 per pcs.' }

    it 'accepts an equivalent candidate preserving the exact amount, currency, and UOM' do
      expect(accepts?(descriptor, fallback, 'It costs IDR 150000 per pcs.')).to be(true)
    end

    it 'rejects an altered decimal/grouping of the amount' do
      expect(accepts?(descriptor, fallback, 'It costs IDR 150.000 per pcs.')).to be(false)
    end

    it 'rejects a changed number of digits in the amount' do
      expect(accepts?(descriptor, fallback, 'It costs IDR 15000 per pcs.')).to be(false)
    end

    it 'rejects an added price or quantity number' do
      expect(accepts?(descriptor, fallback, 'It costs IDR 150000 per pcs, with 5 in stock.')).to be(false)
    end

    it 'rejects a changed currency code' do
      expect(accepts?(descriptor, fallback, 'It costs USD 150000 per pcs.')).to be(false)
    end

    it 'rejects a changed UOM' do
      expect(accepts?(descriptor, fallback, 'It costs IDR 150000 per box.')).to be(false)
    end

    it 'rejects a nonfinite or non-numeric rate before any comparison' do
      expect(eligible?(descriptor.merge(price_list_rate: Float::INFINITY))).to be(false)
      expect(eligible?(descriptor.merge(price_list_rate: 'abc'))).to be(false)
      expect(accepts?(descriptor.merge(price_list_rate: Float::NAN), fallback, fallback)).to be(false)
    end

    it 'rejects a blank currency' do
      expect(eligible?(descriptor.merge(currency: '  '))).to be(false)
    end
  end

  describe '#accepts? — generic token inventory across any kind' do
    it 'rejects an injected Unicode currency symbol and its number' do
      descriptor = { kind: :parent_info, family_code: 'IMP', family_name: 'Impeller' }
      fallback = "You're asking about Impeller. Which variant would you like?"
      expect(accepts?(descriptor, fallback, 'About Impeller — it is €5. Which variant?')).to be(false)
    end
  end

  # Clarify-family candidates must carry the EXACT shape ReplyRenderer emits — a Hash with
  # exactly the symbol keys :code and :name, a nonblank String code, and a name that is nil or a
  # nonblank String. Any other shape is malformed and fails closed; an empty list stays allowed.
  describe '#accepts? — clarify_family requires the exact { code:, name: } candidate shape' do
    let(:fallback) { 'Could you let me know which product you mean? For example: Impeller.' }
    let(:candidate) { 'Which product do you mean — Impeller?' }

    def clarify(candidates)
      accepts?({ kind: :clarify_family, candidates: candidates }, fallback, candidate, action: :clarify_family)
    end

    it 'accepts a well-formed candidate and renders the name (or the code when the name is nil)' do
      expect(clarify([{ code: 'IMP', name: 'Impeller' }])).to be(true)
      expect(accepts?({ kind: :clarify_family, candidates: [{ code: 'IMP', name: nil }] },
                      'Could you let me know which product you mean? For example: IMP.',
                      'Which product do you mean — IMP?', action: :clarify_family)).to be(true)
    end

    it 'rejects a candidate missing the :code key' do
      expect(clarify([{ name: 'Impeller' }])).to be(false)
    end

    it 'rejects a candidate carrying an extra raw-row-like key' do
      expect(clarify([{ code: 'IMP', name: 'Impeller', price: 100 }])).to be(false)
    end

    it 'rejects string-keyed candidates (wrong key type)' do
      expect(clarify([{ 'code' => 'IMP', 'name' => 'Impeller' }])).to be(false)
    end

    it 'rejects a blank or non-string code' do
      expect(clarify([{ code: '  ', name: 'Impeller' }])).to be(false)
      expect(clarify([{ code: 123, name: 'Impeller' }])).to be(false)
    end

    it 'rejects a malformed (blank or non-string) name' do
      expect(clarify([{ code: 'IMP', name: '  ' }])).to be(false)
      expect(clarify([{ code: 'IMP', name: 42 }])).to be(false)
    end

    it 'still allows an empty candidate list (the deterministic template has a generic fallback)' do
      expect(eligible?({ kind: :clarify_family, candidates: [] }, action: :clarify_family)).to be(true)
    end
  end

  # A protected value must occur as a standalone token (no alphanumeric character immediately
  # adjacent), so a short code/value is not treated as preserved merely because it is a substring
  # of a larger alphanumeric word.
  describe '#accepts? — protected values require a standalone (alphanumeric-boundary) occurrence' do
    let(:descriptor) { { kind: :parent_info, family_code: 'IMP', family_name: 'sole' } }
    let(:fallback) { 'You are asking about sole. Which variant would you like?' }

    it 'rejects a value present only as a substring of a larger alphanumeric token' do
      # 'sole' appears only inside 'soles' — not a preserved standalone value.
      expect(accepts?(descriptor, fallback, 'You are asking about soles. Which variant would you like?')).to be(false)
    end

    it 'accepts the exact standalone value' do
      expect(accepts?(descriptor, fallback, 'About sole — which variant would you like?')).to be(true)
    end

    it 'still matches a multi-word / punctuation-bearing value exactly and generically' do
      multi = { kind: :parent_info, family_code: 'ZZ9', family_name: 'Wütender Löwe 9000' }
      base = 'Anda menanyakan tentang Wütender Löwe 9000. Varian mana?'
      expect(accepts?(multi, base, 'Untuk Wütender Löwe 9000 — varian mana?')).to be(true)
    end
  end

  describe '#accepts? — malformed shapes and texts fail closed' do
    let(:base) { { kind: :parent_info, family_code: 'IMP', family_name: 'Impeller' } }
    let(:fallback) { "You're asking about Impeller. Which variant would you like?" }
    let(:candidate) { 'About Impeller — which variant?' }

    it 'rejects an extra or missing descriptor key' do
      expect(accepts?(base.merge(extra: 1), fallback, candidate)).to be(false)
      expect(accepts?({ kind: :parent_info, family_code: 'IMP' }, fallback, candidate)).to be(false)
    end

    it 'rejects a blank / non-string / control-bearing / invalid-encoding text on either side' do
      expect(accepts?(base, fallback, '   ')).to be(false)
      expect(accepts?(base, fallback, { reply: candidate })).to be(false)
      expect(accepts?(base, fallback, "About Impeller#{0.chr}")).to be(false)
      expect(accepts?(base, (+"\xff\xfe").force_encoding('UTF-8'), candidate)).to be(false)
    end
  end

  describe 'genericity — no hardcoded product or language data' do
    it 'accepts an equivalent candidate for an arbitrary non-English family and code' do
      descriptor = { kind: :parent_info, family_code: 'ZZ9', family_name: 'Wütender Löwe 9000' }
      fallback = 'Anda menanyakan tentang Wütender Löwe 9000. Varian mana yang Anda inginkan?'
      candidate = 'Untuk Wütender Löwe 9000 — varian mana yang Anda inginkan?'
      expect(accepts?(descriptor, fallback, candidate)).to be(true)
    end
  end
end
