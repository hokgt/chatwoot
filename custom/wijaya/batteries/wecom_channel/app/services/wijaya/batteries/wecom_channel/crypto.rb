# frozen_string_literal: true

# WeCom WXBizMsgCrypt: message signature + AES-256-CBC (PKCS7) encryption used by
# the callback endpoint. Mirrors the reference algorithm Tencent publishes for the
# WeChat Work / WeCom callback:
#   - msg_signature = SHA1(sort([token, timestamp, nonce, encrypt]).join)
#   - AES-256-CBC, key = Base64Decode(EncodingAESKey + '='), iv = key[0,16]
#   - plaintext = random(16) | msg_len(4, network order) | msg | receiveid(corp_id)
#
# Security: signature is compared in constant time and ALWAYS verified before any
# decryption; the embedded receive_id is likewise checked in constant time so a
# payload encrypted for another corp is rejected. No secrets or plaintext bodies
# are ever logged here.
module Wijaya
  module Batteries
    module WecomChannel
      class Crypto
        class Error < StandardError; end
        class SignatureError < Error; end
        class DecryptError < Error; end

        BLOCK_SIZE = 32
        AES_KEY_BYTES = 32
        RANDOM_PREFIX_BYTES = 16

        def initialize(token:, encoding_aes_key:, receive_id:)
          @token = token.to_s
          @receive_id = receive_id.to_s
          @aes_key = Base64.decode64("#{encoding_aes_key}=")
          raise Error, 'invalid encoding aes key' unless @aes_key.bytesize == AES_KEY_BYTES
        end

        def signature(timestamp, nonce, encrypt)
          Digest::SHA1.hexdigest([@token, timestamp.to_s, nonce.to_s, encrypt.to_s].sort.join)
        end

        def valid_signature?(msg_signature, timestamp, nonce, encrypt)
          return false if msg_signature.to_s.empty?

          ActiveSupport::SecurityUtils.secure_compare(signature(timestamp, nonce, encrypt), msg_signature.to_s)
        end

        # Verify the signature then decrypt. Raises SignatureError/DecryptError on any
        # failure so callers can uniformly reject malformed callbacks.
        def decrypt_message(msg_signature:, timestamp:, nonce:, encrypt:)
          raise SignatureError, 'signature mismatch' unless valid_signature?(msg_signature, timestamp, nonce, encrypt)

          decrypt(encrypt)
        end

        def decrypt(encrypt)
          cipher = OpenSSL::Cipher.new('AES-256-CBC')
          cipher.decrypt
          cipher.padding = 0
          cipher.key = @aes_key
          cipher.iv = @aes_key[0, RANDOM_PREFIX_BYTES]
          raw = cipher.update(Base64.decode64(encrypt.to_s)) + cipher.final
          parse_plaintext(remove_pkcs7(raw))
        rescue OpenSSL::Cipher::CipherError
          raise DecryptError, 'cipher error'
        end

        # Encrypt plaintext to Base64. Used for GET echostr round-trip verification in
        # tests and keeps the algorithm symmetric/auditable without real credentials.
        def encrypt(plaintext, random: nil)
          random ||= SecureRandom.random_bytes(RANDOM_PREFIX_BYTES)
          msg = plaintext.to_s.dup.force_encoding('BINARY')
          data = random + [msg.bytesize].pack('N') + msg + @receive_id.b
          cipher = OpenSSL::Cipher.new('AES-256-CBC')
          cipher.encrypt
          cipher.padding = 0
          cipher.key = @aes_key
          cipher.iv = @aes_key[0, RANDOM_PREFIX_BYTES]
          encrypted = cipher.update(add_pkcs7(data)) + cipher.final
          Base64.strict_encode64(encrypted)
        end

        private

        def parse_plaintext(data)
          content = data.byteslice(RANDOM_PREFIX_BYTES, data.bytesize - RANDOM_PREFIX_BYTES).to_s
          raise DecryptError, 'truncated payload' if content.bytesize < 4

          msg_len = content.byteslice(0, 4).unpack1('N')
          raise DecryptError, 'invalid length' if msg_len.nil? || msg_len.negative? || msg_len > content.bytesize - 4

          msg = content.byteslice(4, msg_len).to_s
          receive_id = content.byteslice(4 + msg_len, content.bytesize - 4 - msg_len).to_s
          raise DecryptError, 'receive id mismatch' unless ActiveSupport::SecurityUtils.secure_compare(receive_id, @receive_id)

          msg.force_encoding('UTF-8')
        end

        def add_pkcs7(data)
          amount = BLOCK_SIZE - (data.bytesize % BLOCK_SIZE)
          amount = BLOCK_SIZE if amount.zero?
          data + (amount.chr * amount)
        end

        def remove_pkcs7(data)
          pad = data.getbyte(data.bytesize - 1)
          pad = 0 if pad.nil? || pad < 1 || pad > BLOCK_SIZE
          data.byteslice(0, data.bytesize - pad).to_s
        end
      end
    end
  end
end
