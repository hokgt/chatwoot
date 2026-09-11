# frozen_string_literal: true

# Battery-owned seam on the erp_lead_sidebar draft model for Critical Case B: a conversation
# is assigned to an agent BEFORE any ERP Lead exists, so the assignee-change seam
# (ConversationExtensions) had no linked erp_lead_id to sync and returned. When the agent
# later creates or links the Lead through the existing erp_lead_sidebar SyncService/controller
# path — the ONLY trigger; assignment alone never creates a Lead — that write sets
# erp_lead_id on the draft. An after_update_commit (and an after_create_commit for the rare
# draft created already linked) observes exactly that transition and enqueues the existing
# OwnerSyncJob with the conversation's CURRENT committed assignee, so the assignee email
# becomes lead_owner right after linkage.
#
# Race safety: the current assignee is captured post-commit and passed as expected_assignee_id;
# OwnerSyncJob + OwnerSyncService re-check it under a row lock, so if assignment changed while
# the Lead was being created/linked, a stale owner can never be the final one (a later
# assignee-change seam enqueue, now that erp_lead_id is present, owns the newer owner). It
# fires only when erp_lead_id actually changed to a present value (create or relink), never on
# an ordinary field/status draft update, and is fail-open so a Lead sync is never rolled back.
module Wijaya::Batteries::ErpLeadOwnerSync::LeadDraftExtensions
  extend ActiveSupport::Concern

  included do
    # ONE registration for both create and update. The normal sidebar path creates the draft
    # blank then updates it on link (the update case); a draft created already linked (rare) is
    # the create case. It must be a single after_commit with on: %i[create update] — registering
    # after_create_commit and after_update_commit for the SAME method name would make the later
    # one win and silently drop the other (Rails dedupes commit callbacks by filter). The handler
    # is idempotent-guarded: saved_change_to_erp_lead_id? is true only when the id actually
    # changed to a present value, so a blank draft create and ordinary field updates are no-ops.
    after_commit :wijaya_sync_erp_lead_owner_on_link, on: %i[create update]
  end

  private

  def wijaya_sync_erp_lead_owner_on_link
    return unless saved_change_to_erp_lead_id?
    return if erp_lead_id.blank?

    assignee_id = conversation&.assignee_id
    return if assignee_id.blank?

    Wijaya::Batteries::ErpLeadOwnerSync::OwnerSyncJob.perform_later(conversation_id, assignee_id)
  rescue StandardError => e
    # Fail-open: the Lead sync is already committed; an owner-sync enqueue error must never
    # surface to the erp_lead_sidebar caller. Log the class only (never a message).
    Rails.logger.error("[Wijaya] erp_lead_owner_sync lead-link enqueue failed: #{e.class}")
  end
end
