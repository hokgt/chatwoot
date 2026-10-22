require 'net/http'
require 'json'
require 'uri'

# OpenRouter Decisions transport for the Marine Decision Maker (Phase 2 / Stage 2). It
# POSTs exactly to the normalized /api/alpha/decisions endpoint with the model plus an
# allowlisted questions/state body, and returns ONLY a bounded, deep-copied `answers`
# payload — never the whole provider body.
#
# The request structure and bounds are validated BEFORE the network call, so an oversized
# or malformed request never leaves the process and no unknown top-level field is ever
# sent. Non-2xx, provider error objects, timeouts, network errors, and malformed/empty/
# oversized JSON all map to an opaque allowlisted reason; the provider body, the API key,
# and raw exception text are never returned or logged. The Authorization key lives only
# in the request header.
#
# The endpoint normalization mirrors Marine::Llm::OpenrouterDecisionsClient's tested
# semantics (the connection-test client is intentionally left untouched).
class Marine::Decision::OpenrouterDecisionsClient
  API_MODE = 'openrouter_decisions'.freeze
  DECISIONS_PATH = '/api/alpha/decisions'.freeze
  DEFAULT_BASE = 'https://openrouter.ai'.freeze
  REQUEST_TIMEOUT = 10

  # The only allowlisted top-level request keys.
  REQUEST_KEYS = %i[questions state].freeze

  # Conservative outbound/inbound bounds so hostile or oversized data can never blow up
  # the transport or the downstream normalizer.
  MAX_QUESTIONS = 16
  MAX_STATE_KEYS = 64
  MAX_DEPTH = 6
  MAX_STRING_LENGTH = 2_000
  MAX_ARRAY_ITEMS = 64          # items per nested array
  MAX_HASH_KEYS = 64            # keys per nested hash
  MAX_REQUEST_BYTES = 32_000
  MAX_ANSWERS_BYTES = 64_000
  # Whole raw response body ceiling, applied BEFORE any strip/JSON.parse.
  MAX_RESPONSE_BYTES = 256_000

  def initialize(model:, endpoint:, api_key:)
    @model = model.to_s
    @endpoint = endpoint.to_s
    @api_key = api_key.to_s
  end

  def call(request)
    body = outbound_body(request)
    return failure('malformed_response') if body.nil?

    interpret(execute(body))
  rescue Timeout::Error
    failure('timeout')
  rescue JSON::ParserError
    failure('malformed_response')
  rescue StandardError
    failure('provider_error')
  end

  # Resolves the exact Decisions URL: an endpoint already ending /api/alpha/decisions is
  # used as-is; the OpenRouter base (or /api base) is normalized without appending /v1.
  def decisions_url
    base = @endpoint.strip.chomp('/')
    base = DEFAULT_BASE if base.empty?
    return base if base.end_with?(DECISIONS_PATH)

    "#{base.delete_suffix('/api')}#{DECISIONS_PATH}"
  end

  private

  # Build the ONLY allowlisted outbound body — { model, questions, state } — from a
  # validated, in-bounds request. Returns nil (fail-closed) on any structural violation.
  # Defense in depth: unknown or duplicate canonical top-level keys are rejected here too,
  # never silently ignored, even though the facade already filters them.
  def outbound_body(request)
    attrs = canonical_top_level(request, REQUEST_KEYS)
    return nil if attrs.nil?

    questions = attrs[:questions]
    state = attrs.key?(:state) ? attrs[:state] : {}
    return nil unless valid_questions?(questions) && valid_state?(state)

    body = { model: @model, questions: questions, state: state }
    return nil unless within_bytes?(body, MAX_REQUEST_BYTES)

    body
  end

  # Canonicalize the top-level request to symbol keys, rejecting (nil) any non-String/Symbol
  # key, any key outside the allowlist, and any duplicate canonical key. Never mutates input.
  def canonical_top_level(request, allowed)
    return nil unless request.is_a?(Hash)

    attrs = {}
    request.each do |key, value|
      return nil unless key.is_a?(String) || key.is_a?(Symbol)

      canonical = key.to_sym
      return nil unless allowed.include?(canonical)
      return nil if attrs.key?(canonical)

      attrs[canonical] = value
    end
    attrs
  end

  def valid_questions?(questions)
    questions.is_a?(Hash) && questions.present? && questions.size <= MAX_QUESTIONS && bounded?(questions, 1)
  end

  def valid_state?(state)
    state.is_a?(Hash) && state.size <= MAX_STATE_KEYS && bounded?(state, 1)
  end

  # Recursive structural bounds: depth, per-hash key count, per-array item count, string
  # length, scalar-only leaves, and rejection of duplicate canonical String/Symbol hash
  # keys BEFORE serialization (a later JSON.parse would silently collapse them).
  def bounded?(value, depth)
    return false if depth > MAX_DEPTH

    case value
    when Hash then bounded_hash?(value, depth)
    when Array then value.size <= MAX_ARRAY_ITEMS && value.all? { |child| bounded?(child, depth + 1) }
    else bounded_leaf?(value)
    end
  end

  def bounded_hash?(hash, depth)
    return false if hash.size > MAX_HASH_KEYS

    seen = {}
    hash.all? do |key, child|
      next false unless bounded_key?(key)

      canonical = key.to_s
      next false if seen.key?(canonical)

      seen[canonical] = true
      bounded?(child, depth + 1)
    end
  end

  def bounded_leaf?(value)
    case value
    when String then value.length <= MAX_STRING_LENGTH
    when Numeric, true, false, nil then true
    else false
    end
  end

  def bounded_key?(key)
    (key.is_a?(String) || key.is_a?(Symbol)) && key.to_s.length <= MAX_STRING_LENGTH
  end

  def within_bytes?(value, limit)
    value.to_json.bytesize <= limit
  rescue StandardError
    false
  end

  def execute(body)
    uri = URI.parse(decisions_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = REQUEST_TIMEOUT
    http.read_timeout = REQUEST_TIMEOUT

    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{@api_key}"
    request['Content-Type'] = 'application/json'
    request.body = body.to_json
    http.request(request)
  end

  def interpret(response)
    return failure('provider_error') unless (200..299).cover?(response.code.to_i)
    return failure('malformed_response') if oversized_body?(response.body)

    parsed = parse_body(response.body)
    return failure('malformed_response') unless parsed.is_a?(Hash) && parsed.present?
    return failure('provider_error') if provider_error?(parsed)

    answers = valid_answers(parsed)
    return failure('malformed_response') if answers.nil?

    Marine::Decision::TransportResult.success(payload: answers, model: @model, api_mode: API_MODE)
  end

  # The bounded `answers` Hash, or nil if missing/empty/oversized/out-of-bounds.
  def valid_answers(parsed)
    answers = parsed['answers'] || parsed[:answers]
    return nil unless answers.is_a?(Hash) && answers.present?
    return nil unless within_bytes?(answers, MAX_ANSWERS_BYTES) && bounded?(answers, 1)

    answers
  end

  def provider_error?(parsed)
    (parsed['error'] || parsed[:error]).present?
  end

  # Guards the raw body size BEFORE strip/JSON.parse so a hostile multi-megabyte payload is
  # never materialized into Ruby objects.
  def oversized_body?(body)
    body.to_s.bytesize > MAX_RESPONSE_BYTES
  end

  # JSON.parse silently collapses any duplicate provider response keys; the returned
  # `answers` is untrusted transport output and Stage 3 MUST revalidate it (this transport
  # only bounds it structurally, it does not build a candidate plan).
  def parse_body(body)
    text = body.to_s.strip
    return nil if text.empty?

    JSON.parse(text)
  end

  def failure(reason)
    Marine::Decision::TransportResult.failure(reason: reason, api_mode: API_MODE, model: @model)
  end
end
