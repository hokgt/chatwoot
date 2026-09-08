# frozen_string_literal: true

require 'rails_helper'

# The opaque signed ephemeral state transport for the source-less Playground preview: it must
# round-trip a normalized snapshot, and fail CLOSED (nil) on tamper, expiry, an assistant switch, an
# account mismatch, or a blank/garbage/oversized token. It is never persisted and never logged.
RSpec.describe Marine::Catalog::PlaygroundStateToken do
  subject(:signer) { described_class.new(account: account, assistant: assistant) }

  let(:account) { double('account', id: 7) }
  let(:assistant) { double('assistant', id: 11) }
  let(:snapshot) do
    { 'version' => 2, 'flow_id' => 'f-1', 'status' => 'active',
      'validated_family' => 'BD', 'catalog_sent' => true, 'clarification_count' => 1 }
  end

  it 'round-trips a snapshot through a signed token' do
    encoded = signer.encode(snapshot)

    expect(encoded).to be_present
    expect(signer.decode(encoded)).to eq(snapshot)
  end

  it 'returns nil (no token) for a blank snapshot' do
    expect(signer.encode(nil)).to be_nil
    expect(signer.encode({})).to be_nil
  end

  it 'fails closed on a tampered token' do
    encoded = signer.encode(snapshot)
    tampered = encoded[0..-3] + (encoded[-1] == 'a' ? 'bb' : 'aa')

    expect(signer.decode(tampered)).to be_nil
  end

  it 'fails closed for a token minted for a different assistant (assistant switch)' do
    encoded = signer.encode(snapshot)
    switched = described_class.new(account: account, assistant: double('assistant', id: 12))

    expect(switched.decode(encoded)).to be_nil
  end

  it 'fails closed for a token minted for a different account' do
    encoded = signer.encode(snapshot)
    other = described_class.new(account: double('account', id: 99), assistant: assistant)

    expect(other.decode(encoded)).to be_nil
  end

  it 'fails closed on an expired token' do
    encoded = signer.encode(snapshot)

    travel_to(Time.current + described_class::TTL_SECONDS + 60) do
      expect(signer.decode(encoded)).to be_nil
    end
  end

  it 'returns nil for a blank or garbage token' do
    expect(signer.decode(nil)).to be_nil
    expect(signer.decode('')).to be_nil
    expect(signer.decode('not-a-real-token')).to be_nil
  end

  it 'rejects an oversized token without verifying it' do
    expect(signer.decode('x' * (described_class::MAX_TOKEN_BYTES + 1))).to be_nil
  end
end
