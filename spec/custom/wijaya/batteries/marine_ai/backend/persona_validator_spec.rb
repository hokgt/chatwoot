# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-1 (isolated / mock-only) — persona / self-deflection gate. Marine answers AS the
# assistant; it must not deflect the customer to "contact the sales team".
RSpec.describe Marine::Backend::PersonaValidator do
  subject(:validator) { described_class.new }

  it 'accepts an in-persona reply' do
    expect(validator.call(candidate: 'BD-4 saat ini tersedia, ada yang bisa saya bantu lagi?').ok?).to be(true)
  end

  it 'accepts the approved forward-to-team handoff wording (not a self-deflection)' do
    expect(validator.call(candidate: 'Baik, saya akan meneruskan ini ke tim kami ya.').ok?).to be(true)
  end

  it 'rejects an Indonesian sales-team self-deflection' do
    expect(validator.call(candidate: 'Silakan hubungi tim sales kami untuk info lebih lanjut.').reason).to eq(:self_deflection)
  end

  it 'rejects an English sales-team self-deflection' do
    expect(validator.call(candidate: 'Please contact our sales team for pricing.').reason).to eq(:self_deflection)
  end

  it 'rejects an explicit non-Marine / model identity override' do
    [
      'Sebenarnya saya adalah ChatGPT dari OpenAI.',
      'I am a large language model, so I cannot be sure.',
      "Actually I'm an AI developed by OpenAI.",
      'Maaf, saya bukan Marine.'
    ].each do |candidate|
      expect(validator.call(candidate: candidate).reason).to eq(:identity_override)
    end
  end

  it 'does not flag a normal in-persona reply as an identity override' do
    expect(validator.call(candidate: 'Halo, saya Marine. BD-4 tersedia ya.').ok?).to be(true)
  end

  it 'rejects a malformed candidate' do
    expect(validator.call(candidate: nil).reason).to eq(:malformed_candidate)
  end
end
