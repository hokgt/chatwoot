# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/custom_roles/follow_up_provenance')

RSpec.describe Wijaya::Batteries::CustomRoles::FollowUpProvenance do
  let(:account_id) { 101 }
  let(:context) { { event_name: 'improve', original_context: 'raw', conversation_history: [] } }

  describe '.attach_token' do
    it 'returns the context with an opaque token' do
      stored = described_class.attach_token(context, account_id: account_id, conversation_display_id: 5)

      expect(stored['event_name']).to eq('improve')
      expect(stored['token']).to be_a(String)
      expect(stored['token']).to be_present
    end

    it 'issues a bounded compact token carrying no raw context payload' do
      sensitive = "SECRET-TRANSCRIPT-#{'a' * 400_000}"
      large = { event_name: 'reply_suggestion', original_context: sensitive, last_response: 'ok', conversation_history: [] }

      token = described_class.attach_token(large, account_id: account_id, conversation_display_id: 5)['token']

      expect(token.bytesize).to be < 1024
      expect(token).not_to include('SECRET-TRANSCRIPT')

      payload = Rails.application.message_verifier(described_class::VERIFIER_NAME)
                     .verified(token, purpose: described_class.send(:purpose, account_id, 5))

      expect(payload).to include('digest')
      expect(payload.keys).not_to include('context')
      expect(payload.inspect).not_to include('SECRET-TRANSCRIPT')
    end
  end

  describe '.verify_follow_up_context' do
    it 'returns the canonical client context for the same account and conversation' do
      stored = described_class.attach_token(context, account_id: account_id, conversation_display_id: 5)

      verified = described_class.verify_follow_up_context(stored, account_id: account_id, conversation_display_id: 5)

      expect(verified).to eq('event_name' => 'improve', 'original_context' => 'raw', 'conversation_history' => [])
    end

    it 'returns nil when any client field changes after issuance' do
      stored = described_class.attach_token(context, account_id: account_id, conversation_display_id: 5)
      tampered = stored.merge('original_context' => 'EVIL')

      expect(described_class.verify_follow_up_context(tampered, account_id: account_id, conversation_display_id: 5)).to be_nil
    end

    it 'returns nil for a token bound to another conversation' do
      stored = described_class.attach_token(context, account_id: account_id, conversation_display_id: 5)

      expect(described_class.verify_follow_up_context(stored, account_id: account_id, conversation_display_id: 6)).to be_nil
    end

    it 'returns nil for a token issued for another account' do
      stored = described_class.attach_token(context, account_id: account_id, conversation_display_id: 5)

      expect(described_class.verify_follow_up_context(stored, account_id: 202, conversation_display_id: 5)).to be_nil
    end

    it 'returns nil for a missing or tampered token' do
      expect(described_class.verify_follow_up_context({}, account_id: account_id, conversation_display_id: 5)).to be_nil

      stored = described_class.attach_token(context, account_id: account_id, conversation_display_id: 5)
      tampered = stored.merge('token' => "#{stored['token'].next}x")

      expect(described_class.verify_follow_up_context(tampered, account_id: account_id, conversation_display_id: 5)).to be_nil
    end

    it 'returns nil for a blank client context' do
      expect(described_class.verify_follow_up_context(nil, account_id: account_id, conversation_display_id: 5)).to be_nil
    end

    it 'accepts a context-free token for any conversation in the same account' do
      free = described_class.attach_token(context, account_id: account_id, conversation_display_id: nil)

      verified = described_class.verify_follow_up_context(free, account_id: account_id, conversation_display_id: 9)

      expect(verified).to eq('event_name' => 'improve', 'original_context' => 'raw', 'conversation_history' => [])
    end

    it 'fails closed without raising for non-object raw follow_up_context values' do
      ['just a string', %w[an array], 42, true, false, nil].each do |raw|
        expect(described_class.verify_follow_up_context(raw, account_id: account_id, conversation_display_id: 5)).to be_nil
      end
    end

    it 'accepts raw ActionController::Parameters input' do
      stored = described_class.attach_token(context, account_id: account_id, conversation_display_id: 5)

      verified = described_class.verify_follow_up_context(
        ActionController::Parameters.new(stored), account_id: account_id, conversation_display_id: 5
      )

      expect(verified).to eq('event_name' => 'improve', 'original_context' => 'raw', 'conversation_history' => [])
    end

    it 'rejects impostor objects exposing to_unsafe_h' do
      stored = described_class.attach_token(context, account_id: account_id, conversation_display_id: 5)
      impostor = Class.new do
        def initialize(token)
          @token = token
        end

        def to_unsafe_h
          { 'event_name' => 'improve', 'original_context' => 'raw', 'conversation_history' => [], 'token' => @token }
        end
      end.new(stored['token'])

      expect(described_class.verify_follow_up_context(impostor, account_id: account_id, conversation_display_id: 5)).to be_nil
    end
  end
end
