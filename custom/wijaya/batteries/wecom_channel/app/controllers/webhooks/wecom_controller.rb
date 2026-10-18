# frozen_string_literal: true

# Public, unauthenticated corp-scoped WeCom callback endpoint:
#   GET  /webhooks/wecom/:corp_id  — URL verification; echoes the decrypted echostr
#   POST /webhooks/wecom/:corp_id  — encrypted event callback
#
# The callback is configured once per Corp ID in the standalone 微信客服 console
# (开发配置 → 企业内部接入). Verification must succeed before any Secret exists, so it
# relies only on the corp's Token + EncodingAESKey (held by every inbox sharing the
# Corp ID). We validate the msg_signature and decrypt against each sibling channel
# in turn, accepting the first whose signature matches.
#
# Security: the msg_signature is verified in constant time BEFORE any decryption
# (Crypto#decrypt_message), the embedded receive_id (Corp ID) is checked in constant
# time so a payload for another corp is rejected, XML is parsed with external
# entities/network disabled (no XXE), malformed callbacks are rejected with a bare
# status (no body), and nothing sensitive is logged. On a kf_msg_or_event the
# decrypted OpenKfId selects the matching inbox WITHIN the corp and a background pull
# is enqueued, returning 200 immediately so WeCom's callback stays fast.
class Webhooks::WecomController < ActionController::API
  Crypto = Wijaya::Batteries::WecomChannel::Crypto
  ChannelResolver = Wijaya::Batteries::WecomChannel::ChannelResolver
  SyncMessagesJob = Wijaya::Batteries::WecomChannel::SyncMessagesJob

  KF_EVENT = 'kf_msg_or_event'

  def verify
    plaintext = decrypt_with_corp_channel(params[:echostr])
    return head :unauthorized if plaintext.nil?

    render plain: plaintext
  rescue StandardError => e
    Rails.logger.error("[Wijaya] wecom verify failed: #{e.class}")
    head :bad_request
  end

  def events
    plaintext = decrypt_with_corp_channel(extract_encrypt(request.raw_post))
    return head :unauthorized if plaintext.nil?

    enqueue_sync(parse_event(plaintext))
    head :ok
  rescue StandardError => e
    Rails.logger.error("[Wijaya] wecom events failed: #{e.class}")
    head :bad_request
  end

  private

  # Validate the signature and decrypt against each channel configured for this Corp
  # ID, returning the first successful plaintext. Returns nil when no sibling exists
  # or none validates, so the caller answers 401 without leaking which case it was.
  def decrypt_with_corp_channel(encrypt)
    return nil if encrypt.blank?

    ChannelResolver.siblings(params[:corp_id]).find do |channel|
      return crypto_for(channel).decrypt_message(
        msg_signature: params[:msg_signature], timestamp: params[:timestamp],
        nonce: params[:nonce], encrypt: encrypt
      )
    rescue Crypto::Error
      next
    end
    nil
  end

  def crypto_for(channel)
    Crypto.new(token: channel.token, encoding_aes_key: channel.encoding_aes_key, receive_id: channel.corp_id)
  end

  def enqueue_sync(event)
    return unless event[:event] == KF_EVENT

    target = ChannelResolver.route_event(params[:corp_id], event[:open_kfid])
    return if target.nil? || target.open_kfid.blank?

    SyncMessagesJob.perform_later(channel_id: target.id, token: event[:token], open_kfid: target.open_kfid)
  end

  def extract_encrypt(body)
    safe_xml(body).at_xpath('//Encrypt')&.text.to_s
  end

  def parse_event(plaintext)
    doc = safe_xml(plaintext)
    {
      event: doc.at_xpath('//Event')&.text,
      open_kfid: doc.at_xpath('//OpenKfId')&.text,
      token: doc.at_xpath('//Token')&.text
    }
  end

  # Parse XML with network access disabled and WITHOUT NOENT, so external entities
  # are never resolved (no XXE). Nokogiri's defaults already leave NOENT off; NONET
  # is set belt-and-suspenders to forbid any network fetch during parsing.
  def safe_xml(xml)
    Nokogiri::XML(xml.to_s) { |config| config.options = Nokogiri::XML::ParseOptions::NONET }
  end
end
