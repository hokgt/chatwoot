require 'net/http'
require 'json'

# Minimal client for the OpenRouter Decisions API (POST /api/alpha/decisions).
# Decisions models (e.g. typesafe/jev-1.13) reject the chat/completions endpoint,
# so the connection test cannot reuse RubyLLM. This talks to the Decisions endpoint
# directly with a harmless bounded classification question and returns a normalized,
# sanitized result. The API key is never placed in the result and is redacted from
# any error text; provider response bodies are never returned verbatim.
#
#   { ok:, message:, error: }
class Marine::Llm::OpenrouterDecisionsClient
  DECISIONS_PATH = '/api/alpha/decisions'.freeze
  DEFAULT_BASE = 'https://openrouter.ai'.freeze
  DEFAULT_TIMEOUT = 5
  MAX_ERROR_LENGTH = 200

  def initialize(api_key:, endpoint: nil, model: nil, timeout: DEFAULT_TIMEOUT)
    @api_key = api_key.to_s
    @endpoint = endpoint.to_s
    @model = model.to_s
    @timeout = timeout
  end

  # Resolves the exact Decisions URL. An endpoint already ending /api/alpha/decisions
  # is used as-is; the OpenRouter base (https://openrouter.ai or https://openrouter.ai/api)
  # is normalized to .../api/alpha/decisions without appending /v1 or /chat/completions.
  def decisions_url
    base = @endpoint.strip.chomp('/')
    base = DEFAULT_BASE if base.empty?
    return base if base.end_with?(DECISIONS_PATH)

    "#{base.delete_suffix('/api')}#{DECISIONS_PATH}"
  end

  def test_connection
    interpret(execute(request_body))
  rescue Net::OpenTimeout, Net::ReadTimeout
    failure('Connection to the provider timed out.')
  rescue JSON::ParserError
    failure('The provider returned a malformed response.')
  rescue StandardError => e
    failure(e.message)
  end

  private

  # A harmless, bounded probe in the documented Decisions contract: `questions` is
  # an object keyed by question ID, each value carrying `type`/`instructions`/
  # `criteria`. A single `choice` question with no customer data confirms the
  # endpoint accepts the request; `state` carries only the required probe value.
  def request_body
    {
      model: @model,
      questions: {
        connection_check: {
          type: 'choice',
          instructions: 'Connectivity probe only. Classify this test request.',
          criteria: {
            reachable: 'The Decisions endpoint is reachable and processed this request.',
            invalid: 'The request could not be processed.'
          }
        }
      },
      state: { test_value: 'ping' }
    }
  end

  def execute(body)
    uri = URI.parse(decisions_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = @timeout
    http.read_timeout = @timeout

    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{@api_key}"
    request['Content-Type'] = 'application/json'
    request.body = body.to_json
    http.request(request)
  end

  def interpret(response)
    code = response.code.to_i
    return failure("The provider responded with HTTP #{code}.") unless (200..299).cover?(code)

    parsed = parse_body(response.body)
    # The response structure can evolve, so parsing stays generic — we only require
    # a non-empty JSON object/array with no top-level error, never a specific shape.
    return failure('The provider returned an empty or non-object response.') unless valid_result?(parsed)

    provider_error = extract_error(parsed)
    return failure(provider_error) if provider_error.present?

    success
  end

  def valid_result?(parsed)
    (parsed.is_a?(Hash) || parsed.is_a?(Array)) && parsed.present?
  end

  def parse_body(body)
    text = body.to_s.strip
    return nil if text.empty?

    JSON.parse(text)
  end

  # Pulls a bounded human message out of a provider error object, if present.
  def extract_error(parsed)
    return nil unless parsed.is_a?(Hash)

    error = parsed['error'] || parsed[:error]
    return nil if error.blank?
    return error.to_s unless error.is_a?(Hash)

    error['message'] || error[:message] || 'The provider returned an error.'
  end

  def success
    { ok: true, message: 'Connection successful. The Decisions endpoint returned a valid response.', error: nil }
  end

  def failure(message)
    { ok: false, message: nil, error: sanitize(message) }
  end

  # Redacts the API key and bounds the length so a raw key or unbounded body can
  # never leak through an error string.
  def sanitize(message)
    text = message.to_s
    text = text.gsub(@api_key, '[REDACTED]') if @api_key.present?
    text = 'Unknown error' if text.strip.empty?
    text.truncate(MAX_ERROR_LENGTH)
  end
end
