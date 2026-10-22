# frozen_string_literal: true

# Server-only provider status callback endpoint for the WhatsApp Web connector.
# Carries NO agent/browser authentication — authorization is an exact raw-body
# HMAC over the per-inbox Channel::Api `secret` (the same secret the connector
# signs outbound webhooks with), plus a bounded timestamp freshness window and a
# Redis-backed delivery-UUID replay guard. It fails closed on anything it cannot
# verify and never exposes a connector/channel secret or any customer content in
# its response or logs.
#
#   POST /public/api/v1/wijaya/whatsapp_web/provider_events/:inbox_identifier
#     X-Wijaya-Delivery   : UUID (replay key)
#     X-Wijaya-Timestamp  : unix seconds
#     X-Wijaya-Signature  : lowercase hex HMAC-SHA256(secret, "<ts>.<rawBody>")
#   body: { session_id, inbox_identifier, chatwoot_message_id,
#           provider_message_id, status }
#
class Public::Api::V1::Wijaya::WhatsappWeb::ProviderEventsController < PublicController
  TIMESTAMP_TOLERANCE = 300
  REPLAY_TTL = 900
  REPLAY_PREFIX = 'wijaya:wa_web:provider_event:'
  ALLOWED_STATUSES = %w[sent delivered read failed].freeze
  STATUS_RANK = { 'sent' => 1, 'delivered' => 2, 'read' => 3 }.freeze
  PROVIDER_ID_RE = /\A[A-Za-z0-9._:=@-]{1,255}\z/
  FAILED_ERROR_CODE = 'provider_delivery_failed'

  def create
    raw = request.raw_post.to_s
    verdict = authenticate(raw)
    return render_status(verdict) if verdict

    # Authenticated: guard against an exact network replay (fail closed if the
    # replay store is unavailable — the connector's durable outbox retries).
    case replay_state
    when :duplicate then return render_ok('duplicate')
    when :unavailable then return render_status(:service_unavailable)
    end

    handle_event(raw)
  rescue ActionDispatch::Http::Parameters::ParseError
    # A malformed JSON body (even if validly signed) is an expected client error,
    # not a server fault — fail closed without leaking which check tripped.
    render_status(:unprocessable_entity)
  rescue StandardError => e
    Rails.logger.error("[Wijaya] whatsapp_web provider_event failed: #{e.class}")
    render_status(:internal_server_error)
  end

  private

  # Returns a failure status symbol, or nil when authenticated (sets @channel).
  def authenticate(raw)
    return :unauthorized unless headers_present?
    return :unauthorized unless timestamp_fresh?

    @channel = find_channel
    return :not_found if @channel.nil?

    secret = @channel.secret.to_s
    return :unauthorized if secret.blank?
    return :unauthorized unless valid_signature?(secret, raw)

    nil
  end

  def handle_event(raw)
    body = parse_body(raw)
    return render_status(:unprocessable_entity) if body.nil?
    return render_status(:unprocessable_entity) unless valid_schema?(body, @channel)

    message = locate_message(@channel, body)
    return render_status(:not_found) if message.nil?
    return render_status(:unprocessable_entity) unless message.outgoing?

    apply_status(message, body)
  end

  def headers_present?
    delivery_uuid.present? && timestamp_header.present? && signature_header.present?
  end

  def delivery_uuid
    request.headers['X-Wijaya-Delivery'].to_s
  end

  def timestamp_header
    request.headers['X-Wijaya-Timestamp'].to_s
  end

  def signature_header
    request.headers['X-Wijaya-Signature'].to_s
  end

  def timestamp_fresh?
    ts = Integer(timestamp_header, exception: false)
    return false if ts.nil?

    (Time.now.to_i - ts).abs <= TIMESTAMP_TOLERANCE
  end

  # Only a Channel::Api explicitly marked as a whatsapp_web provider inbox.
  def find_channel
    channel = ::Channel::Api.find_by(identifier: params[:inbox_identifier])
    return nil if channel.nil?
    return nil unless whatsapp_web_channel?(channel)

    channel
  end

  def whatsapp_web_channel?(channel)
    attrs = channel.additional_attributes
    attrs.is_a?(Hash) &&
      attrs[Wijaya::Batteries::WhatsappWebInbox::Record::ADDITIONAL_ATTRIBUTES_KEY] ==
        Wijaya::Batteries::WhatsappWebInbox::Record::PROVIDER
  end

  def valid_signature?(secret, raw)
    expected = OpenSSL::HMAC.hexdigest('sha256', secret, "#{timestamp_header}.#{raw}")
    ActiveSupport::SecurityUtils.secure_compare(expected, signature_header)
  end

  # :fresh | :duplicate | :unavailable — SET NX with a TTL; a prior key means an
  # exact replay of this delivery UUID (idempotent success).
  def replay_state
    key = "#{REPLAY_PREFIX}#{delivery_uuid}"
    Redis::Alfred.set(key, '1', nx: true, ex: REPLAY_TTL) ? :fresh : :duplicate
  rescue StandardError
    :unavailable
  end

  def parse_body(raw)
    parsed = JSON.parse(raw)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  def valid_schema?(body, channel)
    return false unless body['inbox_identifier'] == params[:inbox_identifier]
    return false unless ALLOWED_STATUSES.include?(body['status'])
    return false unless body['chatwoot_message_id'].is_a?(Integer)

    mapping = Wijaya::Batteries::WhatsappWebInbox::Record.find_by(inbox_id: channel.inbox.id)
    return false if mapping.nil?

    # session_id must equal this inbox's connector session mapping.
    mapping.connector_session_id.present? && body['session_id'] == mapping.connector_session_id
  end

  # Only a message that belongs to this exact inbox/account.
  def locate_message(channel, body)
    inbox = channel.inbox
    ::Message.find_by(id: body['chatwoot_message_id'], account_id: inbox.account_id, inbox_id: inbox.id)
  end

  def apply_status(message, body)
    status = body['status']
    maybe_set_source_id(message, body['provider_message_id'])

    # Explicit monotonic guard: never downgrade read/delivered; a duplicate or
    # stale status is an idempotent success (no write).
    return render_ok('duplicate') unless status_advances?(message.status, status)

    error = status == 'failed' ? FAILED_ERROR_CODE : nil
    Messages::StatusUpdateService.new(message, status, error).perform
    render_ok('updated')
  end

  # Back-fill the provider id as source_id when safe (enables quote resolution
  # against this outgoing message). Never overwrite an existing source_id.
  def maybe_set_source_id(message, provider_id)
    return if message.source_id.present?
    return unless provider_id.is_a?(String) && PROVIDER_ID_RE.match?(provider_id)

    message.update_column(:source_id, provider_id) # rubocop:disable Rails/SkipsModelValidations
  end

  def status_advances?(current, incoming)
    return current != 'read' && current != 'failed' if incoming == 'failed'

    (STATUS_RANK[incoming] || 0) > (STATUS_RANK[current] || 0)
  end

  def render_ok(result)
    render json: { status: result }, status: :ok
  end

  # Generic, body-free error responses — never leak which check failed in detail.
  def render_status(symbol)
    head symbol
  end
end
