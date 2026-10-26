# frozen_string_literal: true

require 'rails_helper'

# Langkah 3 observability — the PRIVACY-SAFE projection of a Model 2 shadow Result to the two
# aggregate-safe codes (status, reason). It trusts ONLY a genuine Model2ShadowExecution::Result
# whose (status, reason) pair the execution can genuinely emit, reusing the execution's OWN
# constants; anything else fails closed with Invalid so the caller records nothing.
RSpec.describe Marine::Backend::Model2ShadowObservation do
  exec = Marine::Backend::Model2ShadowExecution

  def result(status, reason)
    Marine::Backend::Model2ShadowExecution::Result.new(status: status, reason: reason).freeze
  end

  describe 'every real required pair projects to exactly its status/reason' do
    {
      'accepted + deliverable_wording' => [exec::STATUS_ACCEPTED, exec::REASON_DELIVERABLE_WORDING],
      'rejected + fact_rejected' => [exec::STATUS_REJECTED, :fact_rejected],
      'rejected + fact_unverified' => [exec::STATUS_REJECTED, :fact_unverified],
      'rejected + generation_failed' => [exec::STATUS_REJECTED, :generation_failed],
      'skipped + not_exact_price' => [exec::STATUS_SKIPPED, exec::REASON_NOT_EXACT_PRICE],
      'skipped + invalid_packet' => [exec::STATUS_SKIPPED, exec::REASON_INVALID_PACKET]
    }.each do |label, (status, reason)|
      it "projects #{label}" do
        obs = described_class.build(result: result(status, reason))
        expect(obs.status).to eq(status)
        expect(obs.reason).to eq(reason)
        expect(obs).to be_frozen
      end
    end
  end

  it 'accepts every other currently valid existing status/reason pair (closed enum)' do
    described_class::ALLOWED_PAIRS.each do |status, reasons|
      reasons.each do |reason|
        obs = described_class.build(result: result(status, reason))
        expect(obs.status).to eq(status)
        expect(obs.reason).to eq(reason)
      end
    end
  end

  it 'exposes ONLY status and reason — no text / packet / id accessor' do
    obs = described_class.build(result: result(exec::STATUS_ACCEPTED, exec::REASON_DELIVERABLE_WORDING))
    %i[text to_h packet account_id assistant_id conversation_id message_id].each do |forbidden|
      expect(obs.respond_to?(forbidden)).to be(false)
    end
  end

  describe 'fail-closed on malformed / unknown / broad input' do
    it 'rejects a non-Result broad payload (a Hash carrying the generated text)' do
      expect { described_class.build(result: { status: :accepted, reason: :deliverable_wording, text: 'Rp 12.500' }) }
        .to raise_error(described_class::Invalid)
    end

    it 'rejects a look-alike object exposing status/reason but not a genuine Result' do
      expect { described_class.build(result: double('fake', status: :accepted, reason: :deliverable_wording)) }
        .to raise_error(described_class::Invalid)
    end

    it 'rejects nil, a String, and the raw generated text' do
      [nil, 'accepted', 'Halo! Harga BD-4 adalah Rp 12.500 per yard.'].each do |bad|
        expect { described_class.build(result: bad) }.to raise_error(described_class::Invalid)
      end
    end

    it 'rejects an unknown status' do
      expect { described_class.build(result: result(:delivered, exec::REASON_DELIVERABLE_WORDING)) }
        .to raise_error(described_class::Invalid)
    end

    it 'rejects an out-of-contract reason for a known status' do
      expect { described_class.build(result: result(exec::STATUS_SKIPPED, :teleported)) }
        .to raise_error(described_class::Invalid)
    end

    it 'rejects an impossible (but individually valid) status/reason pair' do
      # deliverable_wording is only ever an ACCEPTED reason; it can never pair with skipped.
      expect { described_class.build(result: result(exec::STATUS_SKIPPED, exec::REASON_DELIVERABLE_WORDING)) }
        .to raise_error(described_class::Invalid)
      # not_exact_price is only a SKIPPED reason; it can never pair with accepted.
      expect { described_class.build(result: result(exec::STATUS_ACCEPTED, exec::REASON_NOT_EXACT_PRICE)) }
        .to raise_error(described_class::Invalid)
    end
  end
end
