# frozen_string_literal: true

# Post-commit ERP Lead owner sync. Enqueued by ConversationExtensions the moment a
# conversation's assignee change to a present agent commits, so the ERP call happens
# off the assignment transaction and can never roll it back.
#
# It is idempotent and stale-safe:
#   * expected_assignee_id is the assignee captured at enqueue. If the conversation
#     has since moved to a different (or no) assignee, this job is stale and returns
#     without touching ERP — a later job owns the newer owner (the B -> C guard).
#   * With no linked ErpLeadDraft or a blank erp_lead_id it returns without creating
#     any draft or ERP data.
#   * The ERP owner is the committed assignee's Chatwoot email (stripped, exact) — the
#     authoritative identity that matches the ERPNext User.name (login/email) on this
#     deployment. Never the agent's display name and never a substituted user. A blank
#     email returns without touching ERP; OwnerSyncService still validates the email is a
#     real enabled non-Guest ERP User before any write.
# All remaining validation, locking, idempotency and failure handling live in
# OwnerSyncService.
module Wijaya
  module Batteries
    module ErpLeadOwnerSync
      class OwnerSyncJob < ApplicationJob
        queue_as :low

        def perform(conversation_id, expected_assignee_id)
          conversation = Conversation.find_by(id: conversation_id)
          return if conversation.nil?

          draft = conversation.wijaya_erp_lead_draft
          return if draft.nil? || draft.erp_lead_id.blank?

          # Override state is read fresh (not captured at enqueue) so a reset/manual
          # choice that commits before this job runs decides which owner is synced;
          # OwnerSyncService re-checks it under the row lock for the final say.
          if manual_override?(draft)
            sync_manual_owner(conversation, draft, expected_assignee_id)
          else
            sync_assignee_owner(conversation, draft, expected_assignee_id)
          end
        end

        private

        def manual_override?(draft)
          ActiveModel::Type::Boolean.new.cast(draft.fields['lead_owner_override']) && draft.fields['lead_owner'].present?
        end

        # Sticky manual override: push the agent's confirmed owner, regardless of the
        # current assignee (assignee changes never reach here — see ConversationExtensions).
        def sync_manual_owner(conversation, draft, expected_assignee_id)
          target_owner = draft.fields['lead_owner'].to_s.strip.presence
          return if target_owner.blank?

          OwnerSyncService.new(
            conversation: conversation, draft: draft,
            expected_assignee_id: expected_assignee_id, target_owner: target_owner, mode: :manual
          ).perform
        end

        # Default automatic path: owner follows the committed assignee email.
        def sync_assignee_owner(conversation, draft, expected_assignee_id)
          return unless conversation.assignee_id == expected_assignee_id

          target_owner = conversation.assignee&.email.to_s.strip.presence
          return if target_owner.blank?

          OwnerSyncService.new(
            conversation: conversation, draft: draft,
            expected_assignee_id: expected_assignee_id, target_owner: target_owner, mode: :assignee
          ).perform
        end
      end
    end
  end
end
