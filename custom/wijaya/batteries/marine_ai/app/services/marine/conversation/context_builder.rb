# Phase 2 (conversation) — Canonical bounded conversation context and interaction-phase
# detection. The single source of truth for the two inputs every Marine reasoning path
# needs from a trigger-bound turn:
#
#   * history — the eligible PRIOR public turns of THIS Conversation, bounded and ordered,
#     for grounding; and
#   * trigger — the current customer turn, bounded, provided SEPARATELY so it is supplied to
#     each downstream path exactly once (never appended to history and also passed as query).
#
# It also computes an interaction phase (opening vs follow-up) as structured metadata for
# later use. Phase 2 only EXPOSES the phase; it never changes greetings, prompts, wording,
# FAQ/product output, or any behavior based on it.
#
# New-interaction (native messaging window) awareness: when the current trigger OPENS a fresh
# native messaging window relative to the immediately prior public inbound — measured with the
# authoritative, channel-specific Conversations::MessageWindowService duration, exactly as
# Marine::Circuit::HandoffWindow does — the turn is classified as opening AND all pre-window
# history is excluded, so an aged unresolved topic from a lapsed interaction can never be
# supplied/revived by a downstream generation path. It NEVER touches persisted product-flow
# state (that has its own expiry). Channels with no window policy or a lookup failure fail CLOSED
# to the window-agnostic behavior above.
#
# Eligibility for history (all required):
#   * same Conversation, strictly BEFORE the trigger (by created_at, then id);
#   * public only (private notes excluded);
#   * incoming or outgoing only (activity/template excluded);
#   * nonblank textual content only.
# The newest MAX_HISTORY_MESSAGES eligible turns are kept and returned oldest-to-newest,
# each truncated to MAX_HISTORY_MESSAGE_CHARS. The trigger is identified/excluded by message
# id (never by content), so an earlier message with identical text stays valid history.
#
# Read-only: it queries public Conversation/Message fields only, mutates nothing, persists
# nothing, creates no message, and applies no semantic filtering/retrieval/summarization or
# phrase/language/product hardcoding. The result is in-memory only.
class Marine::Conversation::ContextBuilder
  # Newest N eligible prior turns kept for grounding.
  MAX_HISTORY_MESSAGES = 10
  # Hard per-prior-turn character cap (no ellipsis), mirroring the extractor's context bound.
  MAX_HISTORY_MESSAGE_CHARS = 500
  # Current-trigger character cap — the existing intent-extractor input limit (4,000).
  MAX_TRIGGER_CHARS = 4000

  # Marine's own public replies carry this polymorphic sender_type (see Marine::Assistant);
  # human agent replies are 'User' and are deliberately NOT Marine responses.
  MARINE_SENDER_TYPE = 'Marine::Assistant'.freeze

  PHASE_OPENING = :opening
  PHASE_FOLLOW_UP = :follow_up

  # Structured, in-memory context API. `history` is an ordered Array of { role:, content: }
  # (role 'user' for incoming, 'assistant' for outgoing — the direction mapping existing
  # consumers expect); `trigger` is the bounded current-turn String; `phase` is a symbol.
  Result = Struct.new(:history, :trigger, :phase, keyword_init: true) do
    def opening?
      phase == PHASE_OPENING
    end

    def follow_up?
      phase == PHASE_FOLLOW_UP
    end
  end

  def initialize(conversation:, trigger_message:)
    @conversation = conversation
    @trigger_message = trigger_message
  end

  def build
    Result.new(history: history, trigger: trigger, phase: phase)
  end

  private

  attr_reader :conversation, :trigger_message

  # Eligible prior turns, newest MAX_HISTORY_MESSAGES first, returned chronological and
  # per-message truncated. Excludes the trigger by id and everything at/after its position.
  #
  # When the trigger OPENS a fresh native messaging window (see #new_interaction_window?), every
  # earlier turn belongs to a prior, lapsed interaction, so no pre-window history is supplied — an
  # aged unresolved topic can never be revived by generation. A channel with no window policy, no
  # anchor, or a lookup failure falls closed to the full bounded history below.
  def history
    return [] if new_interaction_window?

    prior_messages.reverse.map do |message|
      { role: role_for(message), content: bounded(message.content, MAX_HISTORY_MESSAGE_CHARS) }
    end
  end

  def prior_messages
    conversation.messages
                .where(message_type: %i[incoming outgoing], private: false)
                .where.not(id: trigger_message.id)
                .where(before_trigger_clause, ts: trigger_message.created_at, tid: trigger_message.id)
                .where(nonblank_content_clause)
                .reorder(created_at: :desc, id: :desc)
                .limit(MAX_HISTORY_MESSAGES)
                .to_a
  end

  # The current customer turn, bounded to the existing input limit and supplied separately.
  def trigger
    bounded(trigger_message.content, MAX_TRIGGER_CHARS)
  end

  # A fresh native messaging window is always an opening/new interaction, regardless of any
  # earlier Marine reply in the now-lapsed prior window. Otherwise: opening until Marine has
  # posted at least one PUBLIC reply earlier in this Conversation; follow-up thereafter. Human
  # replies (sender_type 'User'), private Marine notes, and any Marine reply at/after the trigger
  # are excluded, so none of them turns opening into follow-up.
  def phase
    return PHASE_OPENING if new_interaction_window?

    earlier_marine_reply? ? PHASE_FOLLOW_UP : PHASE_OPENING
  end

  # A new native messaging window: the current incoming trigger arrived at/after the channel
  # messaging window elapsed since the immediately prior public inbound turn, so — exactly as the
  # channel itself anchors windows on inbound turns — the trigger OPENS a fresh interaction.
  # Chatwoot owns the authoritative, channel-specific window duration in
  # Conversations::MessageWindowService (WhatsApp/Twilio-WA 24h, Meta 24h/7d, TikTok 48h, API by
  # config; nil for web widget/email, etc.); this REUSES that duration rather than duplicating any
  # timing rule, mirroring Marine::Circuit::HandoffWindow. Fails CLOSED to the existing
  # (window-agnostic) behavior when the trigger is not a customer inbound, no window policy applies
  # (duration blank), there is no prior inbound to anchor on, or the lookup raises.
  def new_interaction_window?
    return @new_interaction_window if defined?(@new_interaction_window)

    @new_interaction_window = compute_new_interaction_window
  end

  def compute_new_interaction_window
    return false unless trigger_message.respond_to?(:incoming?) && trigger_message.incoming?

    window = messaging_window
    return false if window.blank?

    prior = previous_public_inbound
    return false if prior.nil?

    trigger_message.created_at >= prior.created_at + window
  rescue StandardError
    false
  end

  # The authoritative channel window DURATION, message-independent (channel_type + config only),
  # so reusing it delegates all channel timing to core. Private method; a future core rename
  # degrades to nil here (fail closed -> existing behavior) rather than mis-detecting a new window.
  def messaging_window
    Conversations::MessageWindowService.new(conversation).send(:messaging_window)
  rescue StandardError
    nil
  end

  # The latest public inbound turn strictly before the trigger — the anchor the channel would use
  # for the previous window (the SAME anchor as Marine::Circuit::HandoffWindow).
  def previous_public_inbound
    conversation.messages.incoming.where(private: false)
                .where('id < ?', trigger_message.id)
                .reorder(created_at: :desc, id: :desc).first
  end

  def earlier_marine_reply?
    conversation.messages
                .where(message_type: :outgoing, private: false, sender_type: MARINE_SENDER_TYPE)
                .exists?([before_trigger_clause, { ts: trigger_message.created_at, tid: trigger_message.id }])
  end

  # Strictly before the trigger by (created_at, id) — the same ordering key used for history,
  # so the position boundary is deterministic even when timestamps tie.
  def before_trigger_clause
    'messages.created_at < :ts OR (messages.created_at = :ts AND messages.id < :tid)'
  end

  # Nonblank textual content: keep only rows whose content has at least one non-whitespace
  # character. The POSIX `[[:space:]]` class covers spaces, tabs, and CR/LF (and vertical
  # tab / form feed), so tab- or newline-only content is excluded just like spaces; NULL
  # content never matches, so nil is excluded too. A fixed literal — no customer-derived SQL.
  # Applied before the ordering/limit above, so the newest MAX_HISTORY_MESSAGES are selected
  # from already-eligible rows rather than fetched then rejected in Ruby.
  def nonblank_content_clause
    "messages.content ~ '[^[:space:]]'"
  end

  def role_for(message)
    message.incoming? ? 'user' : 'assistant'
  end

  # Hard character cut (no ellipsis), matching the extractor's bounding convention. Content is
  # otherwise preserved verbatim.
  def bounded(content, limit)
    content.to_s[0, limit]
  end
end
