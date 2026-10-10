# frozen_string_literal: true

require 'openssl'
require 'digest'
require 'securerandom'

# Builds the three service-authentication headers the connector requires on every
# control-plane request. The signed string is, byte-for-byte:
#
#   "<METHOD-UPPERCASE>\n<path>\n<timestamp>\n<nonce>\n<sha256hex(rawBody)>"
#
# where <path> is the request pathname WITHOUT any query string, <timestamp> is unix
# seconds, <nonce> is a unique UUID (single-use on the connector), and the body hash is
# sha256 of the exact raw bytes sent (sha256("") for an empty body). Signature is the
# lowercase hex HMAC-SHA256 under the shared service secret, sent with NO "sha256="
# prefix. This mirrors the connector's serviceSigningString / verifyServiceSignature.
module Wijaya
  module Batteries
    module WhatsappWebInbox
      module RequestSigner
        HEADER_TIMESTAMP = 'X-Service-Timestamp'
        HEADER_NONCE = 'X-Service-Nonce'
        HEADER_SIGNATURE = 'X-Service-Signature'

        module_function

        # method: string verb, path: pathname only (no query), raw_body: the exact
        # String bytes to be sent (nil/'' for bodyless requests), secret: service HMAC
        # secret. Returns a headers hash; a fresh nonce/timestamp per call.
        def headers(method:, path:, raw_body:, secret:, timestamp: nil, nonce: nil)
          timestamp ||= Time.now.to_i.to_s
          nonce ||= SecureRandom.uuid
          signature = sign(method: method, path: path, raw_body: raw_body, secret: secret,
                           timestamp: timestamp, nonce: nonce)
          {
            HEADER_TIMESTAMP => timestamp,
            HEADER_NONCE => nonce,
            HEADER_SIGNATURE => signature
          }
        end

        def sign(method:, path:, raw_body:, secret:, timestamp:, nonce:)
          OpenSSL::HMAC.hexdigest('SHA256', secret.to_s, signing_string(
                                                           method: method, path: path, raw_body: raw_body,
                                                           timestamp: timestamp, nonce: nonce
                                                         ))
        end

        def signing_string(method:, path:, raw_body:, timestamp:, nonce:)
          body_hash = Digest::SHA256.hexdigest(raw_body.to_s)
          "#{method.to_s.upcase}\n#{path}\n#{timestamp}\n#{nonce}\n#{body_hash}"
        end
      end
    end
  end
end
