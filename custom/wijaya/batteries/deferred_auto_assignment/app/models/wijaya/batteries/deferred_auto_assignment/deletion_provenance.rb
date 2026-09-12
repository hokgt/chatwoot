# frozen_string_literal: true

# Durable structured provenance ("tombstone") for a conversation whose human assignee was
# cleared by an agent deletion. One row is written ATOMICALLY inside Agents::DestroyJob's
# unassignment transaction (see ProvenanceRecorder), so the exact prior-agent identity and the
# removal event/time survive the agent's User deletion and a crash between commit and the
# existing post-commit dispatch. It is the ONLY authoritative source the automatic historical
# reconciliation trusts — free-text activity is never proof.
#
# prior_assignee_id has NO belongs_to/foreign key on purpose: the referenced User is deleted in
# the very scenario this row exists for, so a FK association would either erase the row or dangle.
# account/conversation/inbox keep real associations (their FKs cascade at the DB level).
#
# Nested (not compact) to match the sibling battery files whose unqualified cross-references
# resolve lexically to Wijaya::Batteries::DeferredAutoAssignment::*.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      class DeletionProvenance < ApplicationRecord
        self.table_name = 'wijaya_deferred_assignment_provenance'

        AGENT_DELETION = 'agent_deletion'

        belongs_to :account
        belongs_to :conversation
        belongs_to :inbox

        validates :prior_assignee_id, presence: true
        validates :event, presence: true
        validates :event_at, presence: true

        # Rows still awaiting the one-time reconciliation.
        scope :unreconciled, -> { where(reconciled_at: nil) }
      end
    end
  end
end
