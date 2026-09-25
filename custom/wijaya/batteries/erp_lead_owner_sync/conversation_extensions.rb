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
#
# A newly committed assignment to a present agent is AUTHORITATIVE: it supersedes any
# prior sticky manual Lead Owner override. That override clearing happens synchronously
# here (not in the async job), so a manual owner picked AFTER this assignment — which
# re-sets the override — still wins over this and any older queued job, and only the
# assignment-triggered seam is ever authoritative (the manual/reset/retry/link paths
# never run this callback, so they keep their existing override-respecting semantics).
module Wijaya::Batteries::ErpLeadOwnerSync::ConversationExtensions
  extend ActiveSupport::Concern

  included do
    after_update_commit :wijaya_sync_erp_lead_owner
  end

  private

  def wijaya_sync_erp_lead_owner
    return unless saved_change_to_assignee_id?
    return if assignee_id.blank?

    draft = wijaya_erp_lead_draft
    return if draft.nil?

    # Record the committed assignee as the new intended owner + pending marker and clear
    # any sticky manual override, so the panel reflects the new owner immediately and the
    # assignment-authoritative rule is enforced at commit time. Local storage is never
    # proof of ERP sync — the pending marker keeps the validated PUT mandatory downstream.
    wijaya_record_assignment_owner(draft)

    # Only a linked ERP Lead has an owner to PUT; an unlinked draft keeps the intended
    # owner locally and is reconciled when the Lead first links (LeadDraftExtensions).
    # Assignment never creates an ERP Lead. expected_assignee_id is captured now (the
    # committed assignee) so a later job can detect it has gone stale after a rapid
    # reassignment.
    return if draft.erp_lead_id.blank?

    Wijaya::Batteries::ErpLeadOwnerSync::OwnerSyncJob.perform_later(id, assignee_id)
  rescue StandardError => e
    # Fail-open: the assignment is already committed; neither the synchronous owner
    # record nor the sync enqueue may surface an error to the native caller. Log the
    # class only (never a message, which could carry data).
    Rails.logger.error("[Wijaya] erp_lead_owner_sync callback failed: #{e.class}")
  end

  # Clear the sticky manual override and store the committed assignee as the new intended
  # owner + pending marker. Only the owner keys are touched, so unrelated draft fields
  # (and the Lead Activity PIC, which never lives on the draft) stay intact. A blank
  # assignee email leaves the draft untouched (no valid owner to record).
  def wijaya_record_assignment_owner(draft)
    owner_email = assignee&.email.to_s.strip.presence
    return if owner_email.blank?

    committed_assignee_id = assignee_id
    self.class.transaction do
      # Serialize concurrent assignment callbacks on the conversation row so an older
      # assignment committing after a newer one cannot overwrite the newest owner in the
      # draft: only record when this callback's committed assignee is still the
      # database-current assignee (newest committed assignment wins). The lock is on the
      # conversation row alone, so there is no cross-row lock ordering to deadlock on.
      if self.class.where(id: id).lock.pick(:assignee_id) == committed_assignee_id
        draft.update!(
          fields: draft.fields.except('lead_owner_override').merge(
            'lead_owner' => owner_email, 'lead_owner_sync_pending' => true
          )
        )
      end
    end
  end
end
