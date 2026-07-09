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
      source = File.read(Rails.root.join('custom/wijaya/marine/app/models/marine/scenario.rb'))
      expect(source).not_to match(/Captain|ChatwootHub|pricing_plan|CAPTAIN/)
    end
  end

  describe 'tool validation and population' do
    let(:account) { create(:account) }
    let(:assistant) { create(:marine_assistant, account: account) }

    describe 'validate_instruction_tools' do
      it 'is valid with valid custom tool references' do
        create(:marine_custom_tool, account: account, slug: 'custom_fetch-order')
        scenario = build(:marine_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Fetch Order](tool://custom_fetch-order) to get order details')

        expect(scenario).to be_valid
      end

      it 'is invalid with unknown tool references' do
        scenario = build(:marine_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Invalid Tool](tool://invalid_tool) to process')

        expect(scenario).not_to be_valid
        expect(scenario.errors[:instruction]).to include('contains invalid tools: invalid_tool')
      end

      it 'is invalid with multiple invalid tools' do
        scenario = build(:marine_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Invalid](tool://invalid_tool) and [@Another](tool://another_invalid)')

        expect(scenario).not_to be_valid
        expect(scenario.errors[:instruction]).to include('contains invalid tools: invalid_tool, another_invalid')
      end

      it 'is valid with no tool references' do
        scenario = build(:marine_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Just respond politely to the customer')

        expect(scenario).to be_valid
      end

      it 'is invalid with a custom tool from a different account' do
        other_account = create(:account)
        create(:marine_custom_tool, account: other_account, slug: 'custom_fetch-order')
        scenario = build(:marine_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Fetch Order](tool://custom_fetch-order) to get order details')

        expect(scenario).not_to be_valid
        expect(scenario.errors[:instruction]).to include('contains invalid tools: custom_fetch-order')
      end

      it 'is invalid with a disabled custom tool' do
        create(:marine_custom_tool, account: account, slug: 'custom_fetch-order', enabled: false)
        scenario = build(:marine_scenario,
                         assistant: assistant,
                         account: account,
                         instruction: 'Use [@Fetch Order](tool://custom_fetch-order) to get order details')

        expect(scenario).not_to be_valid
        expect(scenario.errors[:instruction]).to include('contains invalid tools: custom_fetch-order')
      end
    end

    describe 'resolve_tool_references' do
      before { create(:marine_custom_tool, account: account, slug: 'custom_fetch-order') }

      it 'populates tools array with referenced tool IDs' do
        create(:marine_custom_tool, account: account, slug: 'custom_add-note')
        scenario = create(:marine_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'First [@Fetch Order](tool://custom_fetch-order) then [@Add Note](tool://custom_add-note)')

        expect(scenario.tools).to eq(%w[custom_fetch-order custom_add-note])
      end

      it 'sets tools to nil when no tools are referenced' do
        scenario = create(:marine_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Just respond politely to the customer')

        expect(scenario.tools).to be_nil
      end

      it 'handles duplicate tool references' do
        scenario = create(:marine_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Fetch Order](tool://custom_fetch-order) and [@Fetch Order](tool://custom_fetch-order) again')

        expect(scenario.tools).to eq(['custom_fetch-order'])
      end

      it 'updates tools when instruction changes' do
        create(:marine_custom_tool, account: account, slug: 'custom_add-note')
        scenario = create(:marine_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Fetch Order](tool://custom_fetch-order)')

        expect(scenario.tools).to eq(['custom_fetch-order'])

        scenario.update!(instruction: 'Use [@Add Note](tool://custom_add-note) instead')
        expect(scenario.tools).to eq(['custom_add-note'])
      end
    end
  end

  describe 'custom tool integration' do
    let(:account) { create(:account) }
    let(:assistant) { create(:marine_assistant, account: account) }

    describe '#resolved_tools' do
      it 'includes custom tool metadata' do
        create(:marine_custom_tool, account: account, slug: 'custom_fetch-order',
                                    title: 'Fetch Order', description: 'Gets order details')
        scenario = create(:marine_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Fetch Order](tool://custom_fetch-order)')

        resolved = scenario.resolved_tools
        expect(resolved.length).to eq(1)
        expect(resolved.first[:id]).to eq('custom_fetch-order')
        expect(resolved.first[:title]).to eq('Fetch Order')
      end

      it 'excludes disabled custom tools' do
        custom_tool = create(:marine_custom_tool, account: account, slug: 'custom_fetch-order', enabled: true)
        scenario = create(:marine_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Fetch Order](tool://custom_fetch-order)')

        custom_tool.update!(enabled: false)

        expect(scenario.resolved_tools).to be_empty
      end
    end

    describe '#agent_tools' do
      it 'returns HttpTool instances for referenced custom tools' do
        create(:marine_custom_tool, account: account, slug: 'custom_fetch-order')
        scenario = create(:marine_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Fetch Order](tool://custom_fetch-order)')

        tools = scenario.agent_tools
        expect(tools.length).to eq(1)
        expect(tools.first).to be_a(Marine::Tools::HttpTool)
      end

      it 'excludes disabled custom tools from execution' do
        custom_tool = create(:marine_custom_tool, account: account, slug: 'custom_fetch-order', enabled: true)
        scenario = create(:marine_scenario,
                          assistant: assistant,
                          account: account,
                          instruction: 'Use [@Fetch Order](tool://custom_fetch-order)')

        custom_tool.update!(enabled: false)

        expect(scenario.agent_tools).to be_empty
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
