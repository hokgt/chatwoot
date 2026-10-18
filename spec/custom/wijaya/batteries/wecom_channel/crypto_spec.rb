# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Wijaya::Batteries::WecomChannel::Crypto do
  # Inert, randomly generated key material — no real WeCom credentials. A WeCom
  # EncodingAESKey is a 43-char Base64 string decoding to 32 bytes.
  let(:encoding_aes_key) { Base64.strict_encode64(SecureRandom.random_bytes(32))[0, 43] }
  let(:token) { 'inert_token' }
  let(:corp_id) { 'ww_inert_corp' }

  subject(:crypto) { described_class.new(token: token, encoding_aes_key: encoding_aes_key, receive_id: corp_id) }

  describe 'round-trip encrypt/decrypt' do
    it 'recovers the original plaintext' do
      plaintext = '<xml><Event><![CDATA[kf_msg_or_event]]></Event></xml>'
      encrypted = crypto.encrypt(plaintext)
      expect(crypto.decrypt(encrypted)).to eq(plaintext)
    end

    it 'handles multibyte (UTF-8) content and returns UTF-8' do
      plaintext = '客户消息 🙂'
      decrypted = crypto.decrypt(crypto.encrypt(plaintext))
      expect(decrypted).to eq(plaintext)
      expect(decrypted.encoding).to eq(Encoding::UTF_8)
    end
  end

  describe '#decrypt_message signature verification' do
    let(:plaintext) { 'hello-wecom' }
    let(:encrypt) { crypto.encrypt(plaintext) }
    let(:timestamp) { '1700000000' }
    let(:nonce) { 'abc123' }
    let(:good_sig) { crypto.signature(timestamp, nonce, encrypt) }

    it 'decrypts when the signature matches' do
      expect(crypto.decrypt_message(msg_signature: good_sig, timestamp: timestamp, nonce: nonce, encrypt: encrypt)).to eq(plaintext)
    end

    it 'raises SignatureError on a tampered signature' do
      expect do
        crypto.decrypt_message(msg_signature: 'deadbeef', timestamp: timestamp, nonce: nonce, encrypt: encrypt)
      end.to raise_error(described_class::SignatureError)
    end

    it 'raises SignatureError when the encrypt payload is altered after signing' do
      expect do
        crypto.decrypt_message(msg_signature: good_sig, timestamp: timestamp, nonce: nonce, encrypt: "#{encrypt}x")
      end.to raise_error(described_class::SignatureError)
    end
  end

  describe 'receive_id isolation' do
    it 'rejects a payload encrypted for a different corp' do
      other = described_class.new(token: token, encoding_aes_key: encoding_aes_key, receive_id: 'different_corp')
      encrypted = other.encrypt('cross-corp')
      expect { crypto.decrypt(encrypted) }.to raise_error(described_class::DecryptError)
    end
  end

  describe 'malformed input' do
    it 'raises on a non-decryptable payload' do
      expect { crypto.decrypt('not-base64-or-aligned!!') }.to raise_error(described_class::DecryptError)
    end

    it 'rejects an invalid encoding aes key' do
      expect do
        described_class.new(token: token, encoding_aes_key: 'tooshort', receive_id: corp_id)
      end.to raise_error(described_class::Error)
    end
  end
end
