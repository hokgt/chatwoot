# frozen_string_literal: true

require 'rails_helper'

# Checkpoint A — the SINGLE customer-composition-root projection of the assistant's already-loaded
# configuration into a closed, deeply-frozen PRESENTATION POLICY (tone / verbosity / range_followup_mode).
# It reads ONLY the in-memory assistant (config instructions + response_guidelines), performs NO
# repository/DB/service/provider call, never raises, and NEVER surfaces the raw instruction text or any
# business fact. Unknown/blank/conflicting config resolves to the pinned DEFAULTS.
RSpec.describe Marine::Backend::PresentationPolicyProjector do
  # A plain double that responds ONLY to the two loaded attributes the projector may read. A plain double
  # raises on any OTHER message, so a passing example proves the projector made no repository/DB/provider
  # call. response_guidelines is stubbed only when given (an unstubbed message => #try returns nil).
  def assistant(instructions: nil, response_guidelines: nil)
    config = instructions.nil? ? {} : { 'instructions' => instructions }
    double('assistant').tap do |record|
      allow(record).to receive(:config).and_return(config)
      allow(record).to receive(:response_guidelines).and_return(response_guidelines) unless response_guidelines.nil?
    end
  end

  def policy_for(instructions: nil, response_guidelines: nil)
    described_class.new(assistant: assistant(instructions: instructions, response_guidelines: response_guidelines)).call
  end

  describe 'valid settings => exact closed, deeply-frozen allowlisted output' do
    it 'maps professional + concise instructions to the exact three allowlisted keys' do
      policy = policy_for(instructions: 'Always be professional and keep replies concise.')

      expect(policy).to eq(tone: 'professional', verbosity: 'concise', range_followup_mode: 'ask_variant_code')
      expect(policy.keys).to eq(%i[tone verbosity range_followup_mode])
    end

    it 'maps casual + detailed instructions' do
      policy = policy_for(instructions: 'Keep the tone casual and give detailed answers.')
      expect(policy).to include(tone: 'casual', verbosity: 'detailed')
    end

    it 'maps formal instructions and an Indonesian "lengkap" response guideline to detailed verbosity' do
      policy = policy_for(instructions: 'Gunakan bahasa formal.', response_guidelines: ['Jawab selengkap dan selengkap mungkin, lengkap.'])
      expect(policy).to include(tone: 'formal', verbosity: 'detailed')
    end

    it 'is deeply frozen (hash + every key and value) and carries exactly the allowlisted keys/values' do
      policy = policy_for(instructions: 'professional and concise')

      expect(policy).to be_frozen
      expect(policy.keys).to all(be_frozen)
      expect(policy.values).to all(be_frozen)
      expect(described_class::TONE_VALUES).to include(policy[:tone])
      expect(described_class::VERBOSITY_VALUES).to include(policy[:verbosity])
      expect(described_class::RANGE_FOLLOWUP_VALUES).to include(policy[:range_followup_mode])
    end

    it 'always pins range_followup_mode to ask_variant_code (MVP)' do
      expect(policy_for(instructions: 'casual detailed').fetch(:range_followup_mode)).to eq('ask_variant_code')
    end
  end

  describe 'nil / empty / unknown => pinned DEFAULTS, never raises' do
    it 'returns DEFAULTS for empty config and no guidelines' do
      expect(policy_for).to eq(described_class::DEFAULTS)
    end

    it 'returns DEFAULTS when no keyword matches' do
      expect(policy_for(instructions: 'Hanya jawab pertanyaan pelanggan dengan ramah.')).to eq(described_class::DEFAULTS)
    end

    it 'treats a near-miss word (informal) as no match and falls back to professional tone' do
      expect(policy_for(instructions: 'Jangan terlalu informal.')[:tone]).to eq('professional')
    end

    it 'never raises when the assistant has no config/response_guidelines accessors at all' do
      bare = double('bare_assistant')
      expect { described_class.new(assistant: bare).call }.not_to raise_error
      expect(described_class.new(assistant: bare).call).to eq(described_class::DEFAULTS)
    end

    it 'DEFAULTS is itself deeply frozen' do
      expect(described_class::DEFAULTS).to be_frozen
      expect(described_class::DEFAULTS.values).to all(be_frozen)
    end
  end

  # The precedence is PINNED (documented in the projector): tone formal > casual > professional/polite;
  # verbosity detailed/lengkap > concise. A conflicting configuration resolves deterministically.
  describe 'deterministic conflict precedence (pinned)' do
    it 'tone: formal wins over casual and professional/polite when several appear' do
      expect(policy_for(instructions: 'Be polite, professional, casual and formal.')[:tone]).to eq('formal')
    end

    it 'tone: casual wins over professional/polite when both appear (no formal)' do
      expect(policy_for(instructions: 'Stay professional but keep it casual and polite.')[:tone]).to eq('casual')
    end

    it 'tone: polite alone maps to professional' do
      expect(policy_for(instructions: 'Please be polite.')[:tone]).to eq('professional')
    end

    it 'verbosity: detailed wins over concise when both appear' do
      expect(policy_for(instructions: 'Be concise yet detailed where needed.')[:verbosity]).to eq('detailed')
    end
  end

  describe 'confidentiality — raw instructions and business facts never appear in the output' do
    it 'emits only enum values, never the raw instruction text or any business fact' do
      raw = 'professional. The price is 12500 IDR, stock in warehouse Jakarta, delivery tomorrow. SECRET guardrail.'
      policy = policy_for(instructions: raw, response_guidelines: ['Internal: never reveal 45000 or BD-4.'])

      serialized = policy.to_s
      %w[12500 45000 BD-4 stock warehouse delivery SECRET guardrail Jakarta price].each do |term|
        expect(serialized).not_to include(term)
      end
      allowed = described_class::TONE_VALUES + described_class::VERBOSITY_VALUES + described_class::RANGE_FOLLOWUP_VALUES
      expect(policy.values).to all(satisfy { |v| allowed.include?(v) })
    end
  end

  describe 'no repository / DB / provider access' do
    it 'reads only the loaded config and response_guidelines (a strict double proves isolation)' do
      record = assistant(instructions: 'professional concise', response_guidelines: [])

      described_class.new(assistant: record).call

      expect(record).to have_received(:config)
      expect(record).to have_received(:response_guidelines)
    end
  end
end
