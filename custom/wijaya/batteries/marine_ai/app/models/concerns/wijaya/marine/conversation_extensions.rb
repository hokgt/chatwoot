# frozen_string_literal: true

# Attaches the Marine "conversation resolved" side effect to core Conversation
# without editing app/models/conversation.rb. Mirrors the native placement:
# the callback fires on after_update_commit (same as core notify_status_change)
# and only when the status actually transitioned to resolved. All behaviour and
# error handling live in Wijaya::Marine::Hooks.after_conversation_resolved, which
# rescues internally so a Marine failure never affects native resolve.
module Wijaya::Marine::ConversationExtensions
  extend ActiveSupport::Concern

  included do
    after_update_commit :wijaya_marine_notify_resolved
  end

  private

  def wijaya_marine_notify_resolved
    return unless saved_change_to_status? && resolved?

    Wijaya::Marine::Hooks.after_conversation_resolved(self)
  end
end
