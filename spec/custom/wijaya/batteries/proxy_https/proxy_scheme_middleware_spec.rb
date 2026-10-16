require 'rails_helper'
require Rails.root.join('custom/wijaya/batteries/proxy_https/proxy_scheme_middleware')

RSpec.describe Wijaya::Batteries::ProxyHttps::ProxySchemeMiddleware do
  subject(:response_env) do
    described_class.new(->(request_env) { [200, {}, [request_env]] }).call(request_env).last.first
  end

  let(:request_env) do
    {
      'HTTPS' => 'off',
      'rack.url_scheme' => 'http',
      'HTTP_X_FORWARDED_PROTO' => 'http'
    }
  end

  it 'normalizes a Cloudflare HTTPS request before Rails SSL enforcement' do
    request_env['HTTP_CF_VISITOR'] = '{"scheme":"https"}'

    expect(response_env).to include(
      'HTTPS' => 'on',
      'rack.url_scheme' => 'https',
      'HTTP_X_FORWARDED_PROTO' => 'https'
    )
  end

  it 'keeps a Cloudflare HTTP request insecure so Rails redirects it' do
    request_env['HTTP_CF_VISITOR'] = '{"scheme":"http"}'
    request_env['HTTPS'] = 'on'
    request_env['rack.url_scheme'] = 'https'
    request_env['HTTP_X_FORWARDED_PROTO'] = 'https'

    expect(response_env).to include(
      'HTTPS' => 'off',
      'rack.url_scheme' => 'http',
      'HTTP_X_FORWARDED_PROTO' => 'http'
    )
  end

  it 'fails closed to HTTP for a malformed Cloudflare visitor header' do
    request_env['HTTP_CF_VISITOR'] = 'not-json'

    expect(response_env).to include(
      'HTTPS' => 'off',
      'rack.url_scheme' => 'http',
      'HTTP_X_FORWARDED_PROTO' => 'http'
    )
  end

  it 'preserves standard proxy scheme headers when Cloudflare metadata is absent' do
    request_env['HTTPS'] = 'on'
    request_env['rack.url_scheme'] = 'https'
    request_env['HTTP_X_FORWARDED_PROTO'] = 'https'

    expect(response_env).to include(
      'HTTPS' => 'on',
      'rack.url_scheme' => 'https',
      'HTTP_X_FORWARDED_PROTO' => 'https'
    )
  end

  it 'redirects Cloudflare HTTP and serves Cloudflare HTTPS through ActionDispatch::SSL' do
    terminal_app = ->(_env) { [200, { 'content-type' => 'text/plain' }, ['ok']] }
    ssl_app = ActionDispatch::SSL.new(terminal_app, redirect: {}, hsts: {}, secure_cookies: true)
    app = described_class.new(ssl_app)
    http_env = Rack::MockRequest.env_for(
      'http://chatwoot.wijayacorp.com/',
      'HTTP_CF_VISITOR' => '{"scheme":"http"}'
    )
    https_env = Rack::MockRequest.env_for(
      'http://chatwoot.wijayacorp.com/',
      'HTTP_CF_VISITOR' => '{"scheme":"https"}'
    )

    http_status, http_headers = app.call(http_env).first(2)
    https_status, https_headers = app.call(https_env).first(2)

    expect(http_status).to eq(301)
    expect(http_headers.fetch('location')).to eq('https://chatwoot.wijayacorp.com/')
    expect(https_status).to eq(200)
    expect(https_headers.fetch('strict-transport-security')).to include('max-age=')
  end
end
