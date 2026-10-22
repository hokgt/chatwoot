# frozen_string_literal: true

require 'rails_helper'

# Local, model-free numeric-grounding backstop: a generated RAG reply may state a MATERIAL number
# only when that number appears in the approved Knowledge Base context it was grounded on. An
# invented (ungrounded) material number — a fabricated price/amount, MOQ, date, contact — is
# rejected; grounded numbers (dates, product/variant codes, telephone numbers, addresses, approved
# quantities) and trivial 1-2 digit numbers pass. No currency token or per-language phrase is used.
RSpec.describe Marine::Charge::NumericGroundingInspector do
  subject(:inspector) { described_class.new }

  describe '#ungrounded_numeric_claim?' do
    context 'with an invented (ungrounded) material number' do
      it 'rejects a bare invented amount absent from the grounding (no currency token, no rate unit)' do
        expect(inspector.ungrounded_numeric_claim?(reply: 'Harganya 28500', grounding: '')).to be(true)
      end

      it 'rejects an invented MOQ absent from the grounding' do
        grounding = "Q: MOQ\nA: The minimum order is 50 yard per color."
        expect(inspector.ungrounded_numeric_claim?(reply: 'Minimum order adalah 5000 yard.', grounding: grounding)).to be(true)
      end

      it 'rejects an invented contact number absent from the grounding' do
        grounding = "Q: Contact\nA: Call +62 812 3456 7890."
        expect(inspector.ungrounded_numeric_claim?(reply: 'Hubungi +62 899 0000 1111.', grounding: grounding)).to be(true)
      end

      it 'rejects an invented date absent from the grounding' do
        grounding = "Q: Reopen\nA: We reopen on 22 September 2026."
        expect(inspector.ungrounded_numeric_claim?(reply: 'Kami buka lagi 15 Januari 2027.', grounding: grounding)).to be(true)
      end
    end

    context 'with grounded numeric facts (preserved)' do
      it 'allows an address number present in the grounding regardless of grouping' do
        grounding = "Q: Contact\nA: Office: Jl. Real Address 123, Bandung."
        expect(inspector.ungrounded_numeric_claim?(reply: 'Our office is at Jl. Real Address 123, Bandung.', grounding: grounding)).to be(false)
      end

      it 'allows a grounded phone and date' do
        grounding = 'A: Alamat Jl. Sudirman No. 28. Telepon +62 812 3456 7890. Diperbarui 22 September 2026.'
        reply = 'Kantor kami di Jl. Sudirman No. 28. Telp +62 812 3456 7890. Buka lagi 22 September 2026.'
        expect(inspector.ungrounded_numeric_claim?(reply: reply, grounding: grounding)).to be(false)
      end

      it 'matches a grounded amount across display grouping (28.500 grounded as 28500)' do
        grounding = 'A: The rate is 28500.'
        expect(inspector.ungrounded_numeric_claim?(reply: 'Sekitar 28.500.', grounding: grounding)).to be(false)
      end
    end

    context 'with only trivial (non-material) numbers' do
      it 'allows 1-2 digit numbers even with empty grounding' do
        reply = 'Minimum order untuk kain ini adalah 50 yard per warna, kode variannya PL-6.'
        expect(inspector.ungrounded_numeric_claim?(reply: reply, grounding: '')).to be(false)
      end

      it 'is false for a blank reply' do
        expect(inspector.ungrounded_numeric_claim?(reply: '', grounding: 'A: 12345')).to be(false)
        expect(inspector.ungrounded_numeric_claim?(reply: nil, grounding: 'A: 12345')).to be(false)
      end
    end
  end
end
