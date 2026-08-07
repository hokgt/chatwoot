# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marine::Scenario, type: :model do
  describe 'associations' do
    it { is_expected.to belong_to(:assistant).class_name('Marine::Assistant') }
    it { is_expected.to belong_to(:account) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_presence_of(:description) }
    it { is_expected.to validate_presence_of(:instruction) }
    it { is_expected.to validate_presence_of(:assistant_id) }
    it { is_expected.to validate_presence_of(:account_id) }
  end

  describe 'scopes' do
    let(:account) { create(:account) }
    let(:assistant) { create(:marine_assistant, account: account) }

    describe '.enabled' do
      it 'returns only enabled scenarios' do
        enabled_scenario = create(:marine_scenario, assistant: assistant, account: account, enabled: true)
        disabled_scenario = create(:marine_scenario, assistant: assistant, account: account, enabled: false)

        expect(described_class.enabled.pluck(:id)).to include(enabled_scenario.id)
        expect(described_class.enabled.pluck(:id)).not_to include(disabled_scenario.id)
      end
    end
  end

  describe 'callbacks' do
    let(:account) { create(:account) }
    let(:assistant) { create(:marine_assistant, account: account) }

    describe 'before_save :resolve_tool_references' do
      it 'calls resolve_tool_references before saving' do
        scenario = build(:marine_scenario, assistant: assistant, account: account)
        expect(scenario).to receive(:resolve_tool_references)
        scenario.save
      end
    end
  end

  describe 'independence from Captain premium gates' do
    it 'does not reference any Captain runtime dependency in the model source' do
      source = File.read(Rails.root.join('custom/wijaya/batteries/marine_ai/app/models/marine/scenario.rb'))
      expect(source).not_to match(/Captain|ChatwootHub|pricing_plan|CAPTAIN/)
    end
  end

  # Custom HTTP tools have been removed to eliminate all direct outbound
  # connectivity between Marine AI and ERP; scenarios no longer resolve, expose,
  # validate, or persist any tool references.
  describe 'tool references (disabled)' do
    let(:account) { create(:account) }
    let(:assistant) { create(:marine_assistant, account: account) }

    describe 'validate_instruction_tools (no-op)' do
      it 'is valid even with tool references in the instruction' do
        scenario = build(:marine_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Fetch Order](tool://custom_fetch-order) to get order details')

        expect(scenario).to be_valid
      end

      it 'is valid even with unknown tool references' do
        scenario = build(:marine_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Invalid Tool](tool://invalid_tool) to process')

        expect(scenario).to be_valid
      end

      it 'is valid with no tool references' do
        scenario = build(:marine_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Just respond politely to the customer')

        expect(scenario).to be_valid
      end
    end

    describe 'resolve_tool_references (no-op)' do
      it 'sets tools to nil even when tool references are present' do
        scenario = create(:marine_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'First [@Fetch Order](tool://custom_fetch-order) then [@Add Note](tool://custom_add-note)')

        expect(scenario.tools).to be_nil
      end

      it 'sets tools to nil when no tools are referenced' do
        scenario = create(:marine_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Just respond politely to the customer')

        expect(scenario.tools).to be_nil
      end
    end

    describe '#resolved_tools' do
      it 'returns an empty array' do
        scenario = create(:marine_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Fetch Order](tool://custom_fetch-order)')

        expect(scenario.resolved_tools).to eq([])
      end
    end

    describe '#agent_tools' do
      it 'returns an empty array' do
        scenario = create(:marine_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Fetch Order](tool://custom_fetch-order)')

        expect(scenario.agent_tools).to eq([])
      end
    end
  end

  describe 'factory' do
    it 'creates a valid scenario with associations' do
      account = create(:account)
      assistant = create(:marine_assistant, account: account)
      scenario = build(:marine_scenario, assistant: assistant, account: account)
      expect(scenario).to be_valid
    end

    it 'creates a scenario with all required attributes' do
      scenario = create(:marine_scenario)
      expect(scenario.title).to be_present
      expect(scenario.description).to be_present
      expect(scenario.instruction).to be_present
      expect(scenario.enabled).to be true
      expect(scenario.assistant).to be_present
      expect(scenario.account).to be_present
    end
  end
end
