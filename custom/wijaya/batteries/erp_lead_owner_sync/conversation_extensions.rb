# frozen_string_literal: true

# Battery-owned Conversation seam for ERP Lead owner sync, attached via the loader's
# to_prepare include (idempotent, reload-safe) so app/models/conversation.rb stays
# untouched. It reuses the linked ERP draft association that the erp_lead_sidebar
# battery already defines on Conversation (has_one :wijaya_erp_lead_draft).
#
# Fires only from after_update_commit — i.e. AFTER the assignment transaction has
# committed, never before save and never inside the assignment transaction — so the
# downstream ERP call can never roll back or block a successful Chatwoot assignment.
# It catches every callback-driven change-to-present assignee alike: Assignment V2's
# claim_and_assign `update!` and a genuine manual reassignment. It deliberately does
# NOT fire for a change to nil (Agents::DestroyJob clears assignee_id with update_all,
# which skips callbacks entirely, and even a callback-driven unassign is filtered out
# here) and never when assignee_id did not actually change.
module Wijaya::Batteries::ErpLeadOwnerSync::ConversationExtensions
  extend ActiveSupport::Concern

  included do
    after_update_commit :wijaya_sync_erp_lead_owner
  end

  private

  def wijaya_sync_erp_lead_owner
    return unless saved_change_to_assignee_id?
    return if assignee_id.blank?

    # Only conversations with an already-linked ERP Lead are relevant; skip the
    # enqueue for everything else so an install-wide assignment change does not
    # queue a no-op job. The has_one is a single indexed lookup.
    draft = wijaya_erp_lead_draft
    return if draft.nil? || draft.erp_lead_id.blank?

    # expected_assignee_id is captured now (the committed assignee) so a later job
    # can detect it has gone stale after a rapid reassignment.
    Wijaya::Batteries::ErpLeadOwnerSync::OwnerSyncJob.perform_later(id, assignee_id)
  rescue StandardError => e
    # Fail-open: the assignment is already committed; a sync-enqueue error must
    # never surface to the native caller. Log the class only (never a message).
    Rails.logger.error("[Wijaya] erp_lead_owner_sync enqueue failed: #{e.class}")
  end
end
