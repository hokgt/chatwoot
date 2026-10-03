# frozen_string_literal: true

require 'rails_helper'

# Fase 3A-2b — the two REAL-intake projection adapters. ConversationIntake validates a synthetic
# envelope through the PUBLIC Marine::Decision::InputContract.build (fail-closed REJECT); PlaygroundIntake
# bounds its query/history against the PUBLIC Marine::Catalog::PlaygroundPreview constants (TRUNCATE),
# and its bounded_history mirror is proven equivalent to the live private bounded_history.
RSpec.describe 'Marine::ProductAuthority::Parity::IntakeAdapters' do
  # Touch the cohesive intake_adapters.rb (which also defines the sibling Runtime) before referencing
  # its constants — Zeitwerk maps the file to IntakeAdapters only.
  adapters = Marine::ProductAuthority::Parity::IntakeAdapters
  conversation = adapters::ConversationIntake
  playground = adapters::PlaygroundIntake

  # A minimal, structurally-valid corpus-shaped case (string-keyed plan, symbol-keyed case).
  let(:kase) do
    {
      id: 'syn_case_1', scenario_key: 'scenario_1',
      capabilities: { 'scenario_1' => %w[price stock] },
      plan: {
        'schema_version' => 'marine_decision_v1',
        'intents' => ['price'],
        'slot_operations' => [
          { 'operation' => 'set', 'slot' => 'product', 'value' => { 'raw_candidate' => 'SYN-FAM-ALPHA', 'candidate_type' => 'family_code' } }
        ]
      },
      label: { status: 'product', intents: ['price'], slot_ops: %w[product], response_goals: ['answer_price'] }
    }
  end

  describe conversation do
    it 'accepts a valid case, preserves the scenario key, and rides the plan payload UNCHANGED' do
      result = conversation.adapt(kase)

      expect(result[:ok]).to be(true)
      expect(result[:surface]).to eq('conversation')
      expect(result[:input][:scenario_key]).to eq('scenario_1')
      expect(result[:input][:capabilities]).to equal(kase[:capabilities])
      expect(result[:input][:plan]).to equal(kase[:plan]) # same object — no conversion
    end

    it 'builds a deterministic, control-clean, bounded synthetic message' do
      message = conversation.synthetic_message(kase)

      expect(message).to start_with('SYN-PARITY syn_case_1 intents=price slots=set:product')
      expect(message.length).to be <= Marine::Decision::InputContract::MAX_MESSAGE_CHARS
    end

    it 'fails closed (bounded reason) when the REAL contract rejects an oversize message' do
      allow(conversation).to receive(:synthetic_message).and_return('x' * (Marine::Decision::InputContract::MAX_MESSAGE_CHARS + 1))

      result = conversation.adapt(kase)

      expect(result).to eq(ok: false, surface: 'conversation', reason: 'intake_rejected')
    end

    it 'fails closed when the REAL contract rejects a control-heavy message' do
      allow(conversation).to receive(:synthetic_message).and_return("SYN-PARITY\x00bad")

      expect(conversation.adapt(kase)[:ok]).to be(false)
    end

    it 'fails closed when the REAL contract rejects a bad state key' do
      allow(conversation).to receive(:state).and_return('not_a_state_key' => 'x')

      result = conversation.adapt(kase)

      expect(result[:ok]).to be(false)
      expect(result[:reason]).to eq('intake_rejected')
    end

    it 'fails closed when the REAL contract rejects an unknown context role' do
      allow(conversation).to receive(:context).and_return([{ 'role' => 'system', 'content' => 'hi' }])

      expect(conversation.adapt(kase)[:ok]).to be(false)
    end

    it 'proves it drives the REAL InputContract (its Invalid is what fails the adapter closed)' do
      allow(Marine::Decision::InputContract).to receive(:build).and_raise(Marine::Decision::InputContract::Invalid)

      expect(conversation.adapt(kase)).to eq(ok: false, surface: 'conversation', reason: 'intake_rejected')
    end

    it 'fails closed when the contract does not accept the case scenario key' do
      allow(Marine::Decision::InputContract).to receive(:build).and_return(scenario_keys: ['other_scenario'])

      expect(conversation.adapt(kase)[:ok]).to be(false)
    end
  end

  describe playground do
    it 'accepts a valid case with the shared synthetic query and rides the plan UNCHANGED' do
      result = playground.adapt(kase)

      expect(result[:ok]).to be(true)
      expect(result[:surface]).to eq('playground')
      expect(result[:input][:plan]).to equal(kase[:plan])
    end

    it 'fails closed (bounded reason) on a blank query' do
      allow(conversation).to receive(:synthetic_message).and_return('   ')

      expect(playground.adapt(kase)).to eq(ok: false, surface: 'playground', reason: 'intake_rejected')
    end

    it 'fails closed on a non-String query' do
      allow(conversation).to receive(:synthetic_message).and_return(:not_a_string)

      expect(playground.adapt(kase)[:ok]).to be(false)
    end

    describe '.bounded_history' do
      it 'truncates content longer than MAX_TURN_CHARS to exactly 500 characters' do
        bounded = playground.bounded_history([{ role: 'user', content: 'a' * 600 }])

        expect(bounded.first[:content].length).to eq(500)
      end

      it 'keeps only the last MAX_HISTORY_TURNS turns' do
        turns = Array.new(15) { |i| { role: 'user', content: "turn-#{i}" } }

        bounded = playground.bounded_history(turns)

        expect(bounded.length).to eq(10)
        expect(bounded.last[:content]).to eq('turn-14')
      end

      it 'filters a role outside HISTORY_ROLES' do
        bounded = playground.bounded_history([{ role: 'system', content: 'hi' }, { role: 'user', content: 'ok' }])

        expect(bounded).to eq([{ role: 'user', content: 'ok' }])
      end

      it 'filters a blank-content turn' do
        bounded = playground.bounded_history([{ role: 'user', content: '   ' }, { role: 'assistant', content: 'a' }])

        expect(bounded).to eq([{ role: 'assistant', content: 'a' }])
      end
    end
  end

  # MIRROR EQUIVALENCE — the adapter's public bounded_history must be byte-identical to the live
  # Marine::Catalog::PlaygroundPreview private bounded_history (spec-only send) across varied inputs,
  # so a future change to the live method surfaces here as a red test.
  describe 'bounded_history mirror equivalence with Marine::Catalog::PlaygroundPreview' do
    live = Marine::Catalog::PlaygroundPreview.new(assistant: nil, account: nil)

    histories = {
      'normal' => [{ role: 'user', content: 'hello' }, { role: 'assistant', content: 'hi' }],
      'oversize content' => [{ role: 'user', content: 'z' * 777 }],
      'more than ten entries' => Array.new(13) { |i| { role: 'user', content: "m#{i}" } },
      'unknown roles' => [{ role: 'system', content: 'x' }, { role: 'user', content: 'y' }],
      'blank contents' => [{ role: 'user', content: '  ' }, { role: 'assistant', content: 'kept' }],
      'string keys' => [{ 'role' => 'user', 'content' => 'strkeys' }]
    }

    histories.each do |label, history|
      it "matches the live private bounded_history for: #{label}" do
        expect(playground.bounded_history(history)).to eq(live.send(:bounded_history, history))
      end
    end
  end
end
