# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Agent::ScenarioSelector do
  let(:account) { create(:account) }
  let(:assistant) { create(:marine_assistant, account: account) }
  let(:selector) { described_class.new(assistant: assistant) }

  describe '#select' do
    it 'returns the enabled scenario whose keywords best match the query' do
      order_scenario = create(:marine_scenario, assistant: assistant, account: account,
                                                title: 'Order status', description: 'Track a delivery',
                                                instruction: 'Help the customer track their order shipment')
      create(:marine_scenario, assistant: assistant, account: account,
                               title: 'Refunds', description: 'Money back policy',
                               instruction: 'Explain how refunds are processed')

      expect(selector.select('where is my order shipment')).to eq(order_scenario)
    end

    it 'ignores disabled scenarios' do
      create(:marine_scenario, assistant: assistant, account: account, enabled: false,
                               title: 'Order status', description: 'Track a delivery',
                               instruction: 'Help the customer track their order shipment')

      expect(selector.select('where is my order shipment')).to be_nil
    end

    it 'returns nil when no scenario clears the minimum overlap' do
      create(:marine_scenario, assistant: assistant, account: account,
                               title: 'Refunds', description: 'Money back policy',
                               instruction: 'Explain how refunds are processed')

      expect(selector.select('completely unrelated astronomy question')).to be_nil
    end

    it 'returns nil for a blank query' do
      create(:marine_scenario, assistant: assistant, account: account)

      expect(selector.select('   ')).to be_nil
    end

    it 'is deterministic across repeated calls' do
      create(:marine_scenario, assistant: assistant, account: account,
                               title: 'Order status', description: 'Track a delivery',
                               instruction: 'Help the customer track their order shipment')

      first = selector.select('order shipment tracking')
      second = selector.select('order shipment tracking')
      expect(first).to eq(second)
    end
  end

  describe 'independence from Captain premium gates' do
    it 'does not reference any Captain runtime dependency in the source' do
      source = File.read(Rails.root.join('custom/wijaya/marine/app/services/marine/agent/scenario_selector.rb'))
      expect(source).not_to match(/Captain::|ChatwootHub|pricing_plan|CAPTAIN_CLOUD_PLAN_LIMITS|FEATURE_FLAGS\.CAPTAIN|captain_integration/)
    end
  end
end
