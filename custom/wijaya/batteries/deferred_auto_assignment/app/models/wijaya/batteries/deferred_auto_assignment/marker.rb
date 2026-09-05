# frozen_string_literal: true

# Durable, per-conversation marker recording that a brand-new conversation completed its
# creation-time native (legacy) auto-assignment but found no eligible ONLINE agent, so it
# is waiting for one to become available. The conversation itself stays open with a nil
# assignee (no new status, naturally visible in Unassigned/All); this row is the only
# state the battery adds. It is created once at conversation creation (Registrar), consumed
# when a later agent-availability/presence transition lets processing assign the
# conversation (InboxProcessor), and destroyed on assignment or on becoming ineligible.
#
# There is exactly one marker per conversation (unique conversation_id), and inbox_id is
# stored so a trigger for a given agent can query only the markers for the inboxes that
# agent belongs to — never a blanket scan of all unassigned conversations.
#
# Lifecycle cleanup (destroy on conversation delete, on manual/bot assignment, on becoming
# non-open) is owned by the battery's ConversationExtensions concern, not by core.
#
# Nested (not compact `class Wijaya::Batteries::DeferredAutoAssignment::Marker`) to match the
# sibling battery files, whose unqualified cross-references resolve lexically; kept uniform.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      class Marker < ApplicationRecord
        self.table_name = 'wijaya_deferred_assignments'

        belongs_to :account
        belongs_to :inbox
        belongs_to :conversation

        validates :conversation_id, uniqueness: true
      end
    end
  end
end
