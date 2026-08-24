# Phase 3 — Centralized human-takeover / conversation eligibility. The single
# canonical answer to "may Marine still act on this conversation?", computed from
# PUBLIC Conversation/Message fields and associations only. It reads; it never
# mutates state and never creates a message.
#
# A conversation is INELIGIBLE (terminal) when:
#   * it is resolved or snoozed, or
#   * Marine has already announced a circuit handoff (an active handoff marker), which stays
#     active for the applicable channel messaging window so Marine stays silent during it; the
#     marker is cleared upstream (Wijaya::Marine::Hooks) only when a new inbound turn opens a
#     fresh window, after which this reads eligible again unless a human has taken over, or
#   * a human has taken over — i.e. there is a public (non-private) OUTGOING
#     message that is either sent by a User agent, or is an external_echo (a reply
#     the human sent from the native app: WhatsApp Business, Instagram, etc.).
#
# Deliberately NOT a takeover:
#   * private notes (private == true),
#   * Marine's own outgoing replies (sender is a Marine::Assistant, not a User,
#     and carries no external_echo).
#
# The result is a strict value object carrying an allowlisted reason code — never
# a raw record or error. Account/assistant/inbox integration and job invocation
# are out of Phase 3 scope.
class Marine::Conversation::Eligibility
  REASON_ELIGIBLE = 'eligible'.freeze
  REASON_RESOLVED = 'resolved'.freeze
  REASON_SNOOZED = 'snoozed'.freeze
  REASON_HUMAN_TAKEOVER = 'human_takeover'.freeze
  REASON_ACTIVE_HANDOFF = 'active_handoff'.freeze
  REASONS = [REASON_ELIGIBLE, REASON_RESOLVED, REASON_SNOOZED, REASON_HUMAN_TAKEOVER, REASON_ACTIVE_HANDOFF].freeze

  Decision = Struct.new(:eligible, :reason, keyword_init: true) do
    def eligible?
      eligible
    end
  end

  def initialize(conversation:)
    @conversation = conversation
  end

  def decision
    return terminal(REASON_RESOLVED) if conversation.resolved?
    return terminal(REASON_SNOOZED) if conversation.snoozed?
    return terminal(REASON_ACTIVE_HANDOFF) if active_handoff?
    return terminal(REASON_HUMAN_TAKEOVER) if human_takeover?

    Decision.new(eligible: true, reason: REASON_ELIGIBLE)
  end

  private

  attr_reader :conversation

  def terminal(reason)
    Decision.new(eligible: false, reason: reason)
  end

  # An active circuit-handoff marker is terminal while it is present: Marine stays silent for
  # the applicable channel messaging window. The marker is cleared only upstream (by a fresh
  # inbound turn past the window), so this read simply reflects its current presence.
  def active_handoff?
    Marine::Circuit::HandoffStateStore.new(conversation: conversation).active?
  end

  # Any public outgoing message that is a genuine human reply counts as a
  # takeover. Private notes are excluded at the query; Marine assistant replies
  # fail both predicates below.
  def human_takeover?
    conversation.messages.outgoing.where(private: false).any? { |message| human_reply?(message) }
  end

  def human_reply?(message)
    message.sender_type == 'User' || external_echo?(message)
  end

  # external_echo is a native-app human reply. Chatwoot sets it to boolean true
  # (see Message builders); require that exact truthy value so a stringified
  # "false" (or any non-true payload) is never mistaken for a takeover.
  def external_echo?(message)
    attributes = message.content_attributes
    attributes.is_a?(Hash) && attributes['external_echo'] == true
  end
end
