# Channel-aware evaluation of whether the messaging window that governed an active handoff
# has lapsed by the time a new inbound customer turn arrived.
#
# A Marine circuit handoff must keep Marine silent only for the applicable ACTIVE channel
# messaging window (the interval during which a human agent may still reply on that channel).
# Chatwoot already owns the authoritative, channel-specific policy for that interval in
# Conversations::MessageWindowService (WhatsApp/Twilio-WA 24h, Meta Messenger/Instagram
# 24h or 7d by GlobalConfig, TikTok 48h, API by configured agent_reply_time_window, and a
# nil/no-window policy for web widget, email, etc.). This class REUSES that duration rather
# than duplicating any timing rule.
#
# The window is anchored, exactly as Meta anchors it, on the customer's messages: each
# inbound turn (re)opens the window; if the customer goes silent past the window and messages
# again, that new turn opens a FRESH window. So the handoff-era window has lapsed for a new
# inbound iff the gap between it and the immediately-preceding inbound turn is at least the
# channel window. This mirrors the native strict `<` "still open" test
# (open == arrival < anchor + window), so lapsed == arrival >= anchor + window.
#
# Fails closed: when no channel window policy applies (duration blank) or there is no prior
# inbound turn to anchor on, the window is treated as NOT expired, so a handoff on a channel
# without a window policy stays terminal. This is a pure read: it never mutates state and
# never creates a message.
class Marine::Circuit::HandoffWindow
  def initialize(conversation:, message:)
    @conversation = conversation
    @message = message
  end

  def expired?
    return false unless message.respond_to?(:incoming?) && message.incoming?

    window = messaging_window
    return false if window.blank?

    prior = previous_incoming
    return false if prior.nil?

    message.created_at >= prior.created_at + window
  end

  private

  attr_reader :conversation, :message

  # The authoritative channel window DURATION. messaging_window is message-independent
  # (it reads only channel_type and channel config), so reusing it here delegates all Meta/
  # channel timing to core. It is a private method; if a future core refactor renames it the
  # rescue degrades to nil (fail closed -> handoff stays terminal) rather than re-engaging
  # wrongly. Duplicating the channel case-statement here would fork the Meta timing rules,
  # which this battery must not do.
  def messaging_window
    Conversations::MessageWindowService.new(conversation).send(:messaging_window)
  rescue StandardError
    nil
  end

  # The latest public inbound turn strictly before this message — the window anchor Meta
  # would use for the previous window.
  def previous_incoming
    conversation.messages.incoming.where(private: false)
                .where('id < ?', message.id)
                .reorder(created_at: :desc, id: :desc).first
  end
end
