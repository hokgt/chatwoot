# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require 'erb'

# Pushes the linked ERP Lead's owner to match the conversation's committed assignee.
#
# It performs an owner-ONLY PUT against the ALREADY LINKED erp_lead_id — never a
# create and never a find-by-phone — so it can only ever update the one Lead this
# draft is already bound to. It reuses the erp_lead_sidebar battery's per-account
# credential resolution (Config), credentialed transport (SafeHttp) and the live
# ERP User validator (LeadActivityPersonDirectory); it does not re-run the full Lead
# PayloadBuilder/validate! so an owner change never depends on unrelated draft fields.
#
# Safety contract:
#   * Unconfigured account            -> :skipped, no PUT, owner + draft unchanged.
#   * Definite invalid owner email    -> :failed, no PUT, draft marked failed (retryable)
#     with the intended owner email (LeadActivityPersonDirectory.valid? returns false for a
#     real "no such User"). Assignment stays committed; the sidebar's draft-driven retry
#     resends once the ERP User exists.
#   * Stale after a rapid B -> C swap -> :stale, no PUT (row-lock re-check). For a
#     manual job this also covers a newer manual selection that changed the desired
#     owner under the lock, so an older manual write can never win over a newer one.
#   * Already synced to this owner    -> :noop, no PUT (idempotent across dup jobs).
#     "Synced" means a successful ERP PUT cleared the lead_owner_sync_pending marker;
#     local storage of the owner is never itself treated as proof of ERP sync, so a
#     freshly stored manual owner (pending) still performs exactly one validated PUT,
#     and a 'failed' draft still retries.
#   * ERP outage / non-2xx / timeout  -> SyncError -> draft marked 'failed' with a
#     generic, non-secret error and the intended new owner, under the same row lock
#     + staleness re-check, so the sidebar's draft-driven retry resends the intended
#     owner and a stale B failure can't clobber a later C; assignment stays committed.
#
# Nested module style so the fully-qualified sibling-battery constants resolve.
module Wijaya
  module Batteries
    module ErpLeadOwnerSync
      class OwnerSyncService
        # mode:
        #   :assignee -> owner follows the committed conversation assignee. Skips
        #     while a sticky manual override is active (the agent picked the owner
        #     by hand) and honors the B -> C staleness guard.
        #   :manual   -> owner is the agent's explicit manual choice (sticky
        #     override). Skips if the override has since been cleared (e.g. a reset
        #     committed after this job was enqueued) so a stale manual write can
        #     never win over a newer reset/assignee state.
        def initialize(conversation:, draft:, expected_assignee_id:, target_owner:, mode: :assignee)
          @conversation = conversation
          @draft = draft
          @expected_assignee_id = expected_assignee_id
          @target_owner = target_owner
          @mode = mode
          @account = draft.account
        end

        def perform
          return :skipped unless config.erp_configured?(@account)
          # A definite "no such User" (false) is an invalid owner email: record a retryable
          # failure carrying the intended email (no PUT), so a later retry resends once the
          # ERP User exists. An ERP outage raises SyncError (also -> mark_failed below).
          return mark_invalid unless person_directory.valid?(@account, @target_owner)

          apply_owner!
        rescue Wijaya::Batteries::ErpLeadSidebar::SyncError
          mark_failed
        end

        private

        # Definite invalid ERP User: no ERP write. Log safely (no email, no ERP body) and
        # persist the retryable failure with the intended owner under the same row-lock +
        # staleness re-check mark_failed uses, so a stale invalid result can't clobber a
        # newer assignee either.
        def mark_invalid
          Rails.logger.warn('[Wijaya] erp_lead_owner_sync target owner is not a valid ERP User; recorded for retry')
          mark_failed
        end

        # The lock serializes concurrent jobs for the same conversation and lets the
        # stale + idempotency checks read committed state before any PUT. put_owner!
        # raising SyncError propagates out (rolling back this empty transaction) to the
        # rescue in #perform; the draft is never dirtied before a successful PUT.
        def apply_owner!
          @conversation.with_lock do
            @draft.reload
            next :skipped unless mode_permitted?
            next :stale if stale_target?
            next :noop if already_synced?

            put_owner!
            # Clear the pending marker only after a successful ERP owner PUT: local
            # storage is never proof of ERP synchronization, so the pending flag is the
            # single source of truth that this owner still needs to reach ERP.
            @draft.update!(
              fields: @draft.fields.merge('lead_owner' => @target_owner).except('lead_owner_sync_pending'),
              sync_status: 'synced',
              last_error: nil
            )
            :synced
          end
        end

        def put_owner!
          response = Wijaya::Batteries::ErpLeadSidebar::SafeHttp.request(
            method: :put,
            uri: lead_uri,
            api_key: config.erp_api_key(@account),
            api_secret: config.erp_api_secret(@account),
            body: { lead_owner: @target_owner }.to_json
          )
          return if response.is_a?(Net::HTTPSuccess)

          raise Wijaya::Batteries::ErpLeadSidebar::SyncError, 'ERPNext lead owner update failed'
        end

        # Synced only when a successful ERP PUT has cleared the pending marker. A manual
        # selection (or a link-time preserve) stores lead_owner locally AND sets
        # lead_owner_sync_pending, so the same-owner + synced-status combination is NOT
        # treated as proof of ERP sync until this battery clears the pending flag itself.
        def already_synced?
          @draft.sync_status == 'synced' &&
            @draft.fields['lead_owner'].to_s == @target_owner &&
            !owner_sync_pending?
        end

        def owner_sync_pending?
          ActiveModel::Type::Boolean.new.cast(@draft.fields['lead_owner_sync_pending'])
        end

        # A job is stale when the state it was enqueued for has since moved on:
        #   * :assignee — the committed assignee changed (the B -> C guard).
        #   * :manual   — a newer manual selection changed the desired owner under the
        #     lock, so this older job's target must not win over the newer one (the
        #     newer selection enqueued its own job). A cleared override (reset) is
        #     already handled earlier by mode_permitted?.
        def stale_target?
          return @conversation.assignee_id != @expected_assignee_id if @mode == :assignee

          @draft.fields['lead_owner'].to_s != @target_owner
        end

        # Read under the row lock so it reflects committed override state:
        #   * :assignee proceeds only while NO manual override is active — a sticky
        #     manual owner is never clobbered by an assignee change.
        #   * :manual proceeds only while the override is STILL active — a reset that
        #     committed after this job was enqueued removes the override, and the
        #     manual write then declines rather than resurrecting the manual owner.
        def mode_permitted?
          @mode == :manual ? override_active? : !override_active?
        end

        def override_active?
          ActiveModel::Type::Boolean.new.cast(@draft.fields['lead_owner_override'])
        end

        # Persist the failure under the same row lock and staleness re-check the PUT
        # ran under, so a B job that failed cannot clobber the draft once the
        # conversation has moved on to C. The intended new owner (target_owner) is
        # written into the draft alongside the failed status so the sidebar's
        # draft-driven retry resends B rather than the previous owner A.
        def mark_failed
          @conversation.with_lock do
            @draft.reload
            next :skipped unless mode_permitted?
            next :stale if stale_target?

            # Keep the pending marker set: the owner still has not reached ERP, so the
            # draft-driven retry must resend it (the flag is the retryable-state signal).
            @draft.update!(
              fields: @draft.fields.merge('lead_owner' => @target_owner, 'lead_owner_sync_pending' => true),
              sync_status: 'failed',
              last_error: 'ERPNext lead owner sync failed'
            )
            :failed
          end
        end

        def lead_uri
          base = config.erp_base_url(@account).chomp('/')
          URI.parse("#{base}/api/resource/Lead/#{ERB::Util.url_encode(@draft.erp_lead_id)}")
        end

        def config
          Wijaya::Batteries::ErpLeadSidebar::Config
        end

        def person_directory
          Wijaya::Batteries::ErpLeadSidebar::LeadActivityPersonDirectory
        end
      end
    end
  end
end
