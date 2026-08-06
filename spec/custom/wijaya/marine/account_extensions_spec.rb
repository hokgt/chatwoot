# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Marine::AccountExtensions do
  describe '#marine_preferences' do
    let(:account) { create(:account) }

    it 'includes non-secret Marine LLM metadata' do
      allow(::Marine::Llm::Config).to receive(:configured?).and_return(true)
      allow(::Marine::Llm::Config).to receive(:model).and_return('marine-model')
      allow(::Marine::Llm::Config).to receive(:embedding_model).and_return('marine-embedding')

      preferences = account.marine_preferences

      expect(preferences[:llm]).to eq(
        {
          configured: true,
          default_model: 'marine-model',
          embedding_model: 'marine-embedding'
        }.with_indifferent_access
      )
      expect(preferences.to_s).not_to include('MARINE_OPEN_AI_API_KEY')
    end
  end
end
