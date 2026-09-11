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
#   * Definite invalid mapping value  -> :invalid, no PUT, owner + draft unchanged
#     (LeadActivityPersonDirectory.valid? returns false for a real "no such User").
#   * Stale after a rapid B -> C swap -> :stale, no PUT (row-lock re-check).
#   * Already synced to this owner    -> :noop, no PUT (idempotent across dup jobs);
#     a 'failed' draft still retries because its status is not 'synced'.
#   * ERP outage / non-2xx / timeout  -> SyncError -> draft marked 'failed' with a
#     generic, non-secret error; the Chatwoot assignment stays committed.
#
# Nested module style so the fully-qualified sibling-battery constants resolve.
module Wijaya
  module Batteries
    module ErpLeadOwnerSync
      class OwnerSyncService
        def initialize(conversation:, draft:, expected_assignee_id:, target_owner:)
          @conversation = conversation
          @draft = draft
          @expected_assignee_id = expected_assignee_id
          @target_owner = target_owner
          @account = draft.account
        end

        def perform
          return :skipped unless config.erp_configured?(@account)
          # A definite "no such User" (false) is an invalid mapping: skip and preserve
          # the existing owner. An ERP outage raises SyncError (handled below), which is
          # deliberately distinct from a definite false.
          return :invalid unless person_directory.valid?(@account, @target_owner)

          apply_owner!
        rescue Wijaya::Batteries::ErpLeadSidebar::SyncError
          mark_failed
          :failed
        end

        private

        # The lock serializes concurrent jobs for the same conversation and lets the
        # stale + idempotency checks read committed state before any PUT. put_owner!
        # raising SyncError propagates out (rolling back this empty transaction) to the
        # rescue in #perform; the draft is never dirtied before a successful PUT.
        def apply_owner!
          @conversation.with_lock do
            @draft.reload
            next :stale unless @conversation.assignee_id == @expected_assignee_id
            next :noop if already_synced?

            put_owner!
            @draft.update!(
              fields: @draft.fields.merge('lead_owner' => @target_owner),
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

        def already_synced?
          @draft.sync_status == 'synced' && @draft.fields['lead_owner'].to_s == @target_owner
        end

        def mark_failed
          @draft.update!(sync_status: 'failed', last_error: 'ERPNext lead owner sync failed')
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
