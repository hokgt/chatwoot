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
#   * With no ERP User mapping for the agent it returns, leaving the existing owner
#     untouched (OwnerMapping resolves by stable Chatwoot user id, no name fallback).
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
          return unless conversation.assignee_id == expected_assignee_id

          draft = conversation.wijaya_erp_lead_draft
          return if draft.nil? || draft.erp_lead_id.blank?

          target_owner = OwnerMapping.erp_user_for(conversation.assignee)
          return if target_owner.blank?

          OwnerSyncService.new(
            conversation: conversation,
            draft: draft,
            expected_assignee_id: expected_assignee_id,
            target_owner: target_owner
          ).perform
        end
      end
    end
  end
end
