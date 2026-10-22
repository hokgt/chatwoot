# frozen_string_literal: true

require 'faraday'
require 'faraday/multipart'
require 'down'

# Thin HTTP client for the WeCom (qyapi.weixin.qq.com) APIs used by the channel:
# gettoken, kf/sync_msg, kf/send_msg, kf/customer/batchget, media/upload, media/get.
#
# - access_token is cached in Redis to its expiry and refreshed exactly once on a
#   40014 (invalid token) / 42001 (expired token) error, then the call is retried.
# - WECOM_HTTP_PROXY is applied ONLY to requests whose host is exactly
#   qyapi.weixin.qq.com; every endpoint here is on that host, and the host is
#   re-checked per request so the proxy can never leak to any other destination.
# - Downloads are size-bounded and all requests are timeout-bounded.
# - Never logs secrets, access tokens, or customer message bodies.
module Wijaya
  module Batteries
    module WecomChannel
      class ApiClient
        class Error < StandardError
          attr_reader :errcode

          def initialize(message, errcode: nil)
            @errcode = errcode
            super(message)
          end
        end

        API_HOST = 'qyapi.weixin.qq.com'
        API_BASE = "https://#{API_HOST}".freeze
        TOKEN_REFRESH_ERRCODES = [40_014, 42_001].freeze
        OPEN_TIMEOUT = 5
        READ_TIMEOUT = 15
        MAX_DOWNLOAD_BYTES = 25 * 1024 * 1024
        TOKEN_SAFETY_MARGIN = 300
        # The provider errmsg is surfaced on the failed Chatwoot message, so it is bounded
        # and scrubbed of anything token-shaped before it ever reaches a stored error.
        ERRMSG_MAX_LENGTH = 200

        def initialize(channel)
          @channel = channel
        end

        def sync_msg(cursor:, token:, open_kfid:, limit: 1000)
          authed_post('/cgi-bin/kf/sync_msg', { cursor: cursor, token: token, open_kfid: open_kfid, limit: limit }.compact)
        end

        def send_text(touser:, open_kfid:, content:)
          authed_post('/cgi-bin/kf/send_msg',
                      { touser: touser, open_kfid: open_kfid, msgtype: 'text', text: { content: content } })
        end

        def send_media(touser:, open_kfid:, msgtype:, media_id:)
          body = { touser: touser, open_kfid: open_kfid, msgtype: msgtype }
          body[msgtype.to_s] = { media_id: media_id }
          authed_post('/cgi-bin/kf/send_msg', body)
        end

        # List the corp's 微信客服 accounts. Used once after the Secret is saved to
        # discover and auto-fill the Open KF ID when the corp has exactly one account.
        def kf_account_list(offset: 0, limit: 100)
          authed_post('/cgi-bin/kf/account/list', { offset: offset, limit: limit })
        end

        def batch_customer(external_userids)
          authed_post('/cgi-bin/kf/customer/batchget',
                      { external_userid_list: Array(external_userids).first(100), need_enter_session_context: 0 })
        end

        # Upload a media blob, returning the temporary WeCom media_id. `type` is one of
        # image / voice / video / file per the WeCom media types.
        def upload_media(io:, filename:, content_type:, type:)
          with_token_retry do |token|
            part = Faraday::Multipart::FilePart.new(io, content_type || 'application/octet-stream', filename)
            response = multipart_connection.post('/cgi-bin/media/upload', { media: part }) do |req|
              req.params['access_token'] = token
              req.params['type'] = type
            end
            parse_json(response).fetch('media_id')
          end
        end

        # Download a temporary media by id. Returns a Down tempfile (responds to
        # #original_filename / #content_type). Raises Error on a WeCom JSON error.
        def download_media(media_id)
          with_token_retry do |token|
            url = "#{API_BASE}/cgi-bin/media/get?access_token=#{CGI.escape(token)}&media_id=#{CGI.escape(media_id.to_s)}"
            file = Down.download(url, max_size: MAX_DOWNLOAD_BYTES, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT,
                                      **proxy_option(url))
            raise_if_json_error!(file)
            file
          end
        end

        def access_token
          cached = ::Redis::Alfred.get(token_cache_key)
          return cached if cached.present?

          fetch_and_cache_token
        end

        private

        def authed_post(path, body)
          with_token_retry do |token|
            response = json_connection.post(path, body.to_json) { |req| req.params['access_token'] = token }
            parse_json(response)
          end
        end

        # Run an authenticated call, refreshing the token once on an expiry/invalid
        # error code before giving up.
        def with_token_retry
          attempts = 0
          begin
            attempts += 1
            yield access_token
          rescue Error => e
            if attempts < 2 && TOKEN_REFRESH_ERRCODES.include?(e.errcode)
              ::Redis::Alfred.delete(token_cache_key)
              retry
            end
            raise
          end
        end

        def fetch_and_cache_token
          response = json_connection.get('/cgi-bin/gettoken') do |req|
            req.params['corpid'] = @channel.corp_id
            req.params['corpsecret'] = @channel.secret
          end
          json = parse_json(response)
          token = json['access_token']
          ttl = json['expires_in'].to_i
          ::Redis::Alfred.setex(token_cache_key, token, [ttl - TOKEN_SAFETY_MARGIN, 60].max) if token.present?
          token
        end

        def parse_json(response)
          json = JSON.parse(response.body.to_s)
          errcode = json['errcode'].to_i
          raise api_error('api', errcode, json['errmsg']) if errcode != 0

          json
        rescue JSON::ParserError
          raise Error, 'wecom api returned non-json response'
        end

        def raise_if_json_error!(file)
          return unless file.content_type.to_s.include?('application/json') || file.content_type.to_s.include?('text/plain')

          body = file.read
          file.rewind
          json = JSON.parse(body)
          errcode = json['errcode'].to_i
          raise api_error('media', errcode, json['errmsg']) if errcode != 0
        rescue JSON::ParserError
          nil
        end

        # Build the provider error carried onto the failed Chatwoot message: errcode plus
        # the sanitized provider errmsg. Never includes secrets, access tokens, or request
        # bodies — only the errcode and the scrubbed errmsg string WeCom returned.
        def api_error(kind, errcode, errmsg)
          Error.new("wecom #{kind} error #{errcode}: #{sanitize_errmsg(errmsg)}", errcode: errcode)
        end

        def sanitize_errmsg(errmsg)
          text = errmsg.to_s.strip
          return 'no error message' if text.empty?

          # A WeCom errmsg should never contain the token, but scrub any access_token=…
          # fragment defensively so a credential can never leak into a stored error.
          text.gsub(/access_token=[^\s&]+/i, 'access_token=[redacted]').truncate(ERRMSG_MAX_LENGTH)
        end

        def json_connection
          @json_connection ||= build_connection
        end

        def multipart_connection
          @multipart_connection ||= build_connection { |f| f.request :multipart }
        end

        def build_connection
          Faraday.new(url: API_BASE) do |f|
            f.proxy = proxy_url if proxy_applicable?(URI.parse(API_BASE))
            f.options.open_timeout = OPEN_TIMEOUT
            f.options.timeout = READ_TIMEOUT
            yield f if block_given?
            f.adapter Faraday.default_adapter
          end
        end

        def proxy_option(url)
          proxy_applicable?(URI.parse(url)) ? { proxy: proxy_url } : {}
        end

        # Proxy is used only for the exact WeCom host, never any other destination.
        def proxy_applicable?(uri)
          proxy_url.present? && uri.host == API_HOST
        end

        def proxy_url
          @proxy_url ||= ENV.fetch('WECOM_HTTP_PROXY', nil).presence
        end

        def token_cache_key
          digest = Digest::SHA256.hexdigest("#{@channel.corp_id}:#{@channel.secret}")
          "WIJAYA_WECOM_TOKEN::#{digest}"
        end
      end
    end
  end
end
