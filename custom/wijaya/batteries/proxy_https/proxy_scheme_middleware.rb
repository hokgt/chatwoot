require 'json'

# Installed by ProxyHttps::Policy before ActionDispatch::SSL so Cloudflare's original
# visitor scheme determines whether Rails serves HTTPS or redirects an HTTP request.
# rubocop:disable Style/ClassAndModuleChildren
module Wijaya
  module Batteries
    module ProxyHttps
      class ProxySchemeMiddleware
        def initialize(app)
          @app = app
        end

        def call(env)
          normalize_cloudflare_scheme!(env) if env.key?('HTTP_CF_VISITOR')
          @app.call(env)
        end

        private

        def normalize_cloudflare_scheme!(env)
          scheme = cloudflare_scheme(env.fetch('HTTP_CF_VISITOR'))
          env['HTTPS'] = scheme == 'https' ? 'on' : 'off'
          env['rack.url_scheme'] = scheme
          env['HTTP_X_FORWARDED_PROTO'] = scheme
        end

        def cloudflare_scheme(value)
          visitor = JSON.parse(value)
          visitor.is_a?(Hash) && visitor['scheme'] == 'https' ? 'https' : 'http'
        rescue JSON::ParserError, TypeError
          'http'
        end
      end
    end
  end
end
# rubocop:enable Style/ClassAndModuleChildren
