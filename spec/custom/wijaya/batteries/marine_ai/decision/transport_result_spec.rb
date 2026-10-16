# frozen_string_literal: true

require 'rails_helper'

# Phase 2 / Stage 2 — the immutable, sanitized value factory every Decision transport
# returns. These examples pin the strict shape, the allowlisted opaque failure reasons,
# deep immutability of the returned result, and the guarantee that a caller-/provider-
# owned input is deep-copied (never frozen in place). No I/O.
RSpec.describe Marine::Decision::TransportResult do
  describe '.success' do
    it 'builds a strict, deep-frozen success result with a String payload' do
      result = described_class.success(payload: 'hello', model: 'gpt-4.1-mini', api_mode: 'chat_completions')

      expect(result).to eq(
        ok: true, payload: 'hello', error_reason: nil, model: 'gpt-4.1-mini', api_mode: 'chat_completions'
      )
      expect(result).to be_frozen
      expect(result[:payload]).to be_frozen
    end

    it 'deep-freezes a nested Hash payload without freezing the caller-owned input' do
      answers = { 'connection_check' => { 'choice' => 'reachable', 'tags' => ['ok'] } }

      result = described_class.success(payload: answers, model: 'jev-1.13', api_mode: 'openrouter_decisions')

      expect(result[:payload]).to eq(answers)
      expect(result[:payload]).to be_frozen
      expect(result[:payload]['connection_check']).to be_frozen
      expect(result[:payload]['connection_check']['tags']).to be_frozen
      # The caller's original structure is untouched — a fresh deep copy was frozen instead.
      expect(answers).not_to be_frozen
      expect(answers['connection_check']).not_to be_frozen
      expect(answers['connection_check']['tags']).not_to be_frozen
    end

    it 'bounds an oversized model string' do
      result = described_class.success(payload: 'x', model: 'm' * 500, api_mode: 'chat_completions')

      expect(result[:model].length).to eq(described_class::MAX_MODEL_LENGTH)
    end

    it 'returns a fresh frozen api_mode, leaving the caller-owned mode string unfrozen' do
      mode = +'chat_completions' # mutable, caller-owned

      result = described_class.success(payload: 'x', model: 'm', api_mode: mode)

      expect(result[:api_mode]).to eq('chat_completions')
      expect(result[:api_mode]).to be_frozen
      expect(result[:api_mode]).not_to be(mode)
      expect(mode).not_to be_frozen
    end

    it 'deep-freezes copied payload hash keys without freezing the caller-owned keys' do
      key = 'intent'.dup # unfrozen, caller-owned
      answers = { key => { 'choice' => 'stock' } }

      result = described_class.success(payload: answers, model: 'm', api_mode: 'openrouter_decisions')

      expect(result[:payload].keys.first).to be_frozen
      expect(key).not_to be_frozen
    end
  end

  describe '.failure' do
    it 'builds a deep-frozen failure carrying an allowlisted reason and nil payload' do
      result = described_class.failure(reason: 'timeout', api_mode: 'chat_completions', model: 'gpt-4.1-mini')

      expect(result).to eq(
        ok: false, payload: nil, error_reason: 'timeout', model: 'gpt-4.1-mini', api_mode: 'chat_completions'
      )
      expect(result).to be_frozen
    end

    it 'folds an unrecognized reason to malformed_response' do
      result = described_class.failure(reason: 'boom: sk-secret raw provider prose', api_mode: 'chat_completions')

      expect(result[:error_reason]).to eq('malformed_response')
      expect(result[:model]).to be_nil
    end

    it 'keeps every allowlisted reason' do
      described_class::FAILURE_REASONS.each do |reason|
        expect(described_class.failure(reason: reason, api_mode: nil)[:error_reason]).to eq(reason)
      end
    end

    it 'allows a nil api_mode when no transport was selected' do
      expect(described_class.failure(reason: 'unconfigured', api_mode: nil)[:api_mode]).to be_nil
    end
  end

  it 'rejects an api_mode outside the allowlist as a programmer error' do
    expect { described_class.success(payload: 'x', model: 'm', api_mode: 'ftp') }.to raise_error(ArgumentError)
  end
end
