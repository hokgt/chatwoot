# frozen_string_literal: true

# Registers a durable deferred marker for a brand-new conversation that just completed its
# creation-time native legacy auto-assignment without landing an assignee, because no
# eligible ONLINE agent existed. Called from the Conversation after_create_commit seam, so
# it runs exactly once, only at creation, and only after the row (and its in-transaction
# immediate-assignment attempt) has committed — a later manual/SPV unassignment can never
# reach here. Idempotent: find_or_create keyed on the unique conversation_id.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module Registrar
        module_function

        def register_unassigned_on_create(conversation)
          return unless Eligibility.deferrable?(conversation)

          register_marker(conversation)

          # Close the trigger-before-marker race: an agent who became reachable AFTER the
          # creation-time assignment attempt but BEFORE this marker existed would have found no
          # marker to act on, and no later trigger is guaranteed. A coalesced, marker-gated pass
          # now assigns immediately if an eligible agent is already available.
          ProcessInboxJob.enqueue_for_inbox(conversation.inbox_id)
        end

        # Bridge for an agent deletion: Agents::DestroyJob has already cleared this agent's
        # assignee_id via update_all (callbacks skipped), so the affected conversations are now
        # open + unassigned but carry no marker. Re-run native legacy auto-assignment for exactly
        # those conversations — mark each still-eligible one (idempotent find_or_create keyed on
        # the unique conversation_id, so a retried DestroyJob never double-marks) and enqueue a
        # coalesced pass for each affected inbox. The InboxProcessor then assigns an eligible
        # online agent under a row lock, or the marker waits for a later availability/presence
        # trigger. Only account-scoped ids from this deletion are considered — never a blanket
        # scan. Runs after the deletion transaction commits (see Agents::DestroyJob).
        #
        # Retry / crash window: a normal ActiveJob retry re-runs the whole DestroyJob; by then the
        # agent owns no conversations, so the bridge collects an empty id list and this is a no-op,
        # and the unique conversation_id keeps find_or_create_by! from double-marking even if the
        # SAME ids are re-dispatched. The one irreducible gap is a process SIGKILL AFTER the
        # unassignment transaction commits but BEFORE the post-commit dispatch runs: those
        # conversations are then unassigned with no marker and no trigger. It is left irreducible
        # deliberately — closing it would mean either marking INSIDE the deletion transaction
        # (coupling the battery in so a marker error could roll back a user deletion, breaking the
        # fail-open contract) or a broad account-wide unassigned scan (out of scope). A later manual
        # assignment or a fresh inbound still resolves such a conversation normally.
        def register_unassigned_after_agent_deletion(account_id, conversation_ids)
          affected_inbox_ids = []
          Conversation.where(account_id: account_id, id: conversation_ids).find_each do |conversation|
            next unless Eligibility.deferrable?(conversation)

            register_marker(conversation)
            affected_inbox_ids << conversation.inbox_id
          end
          affected_inbox_ids.uniq.each { |inbox_id| ProcessInboxJob.enqueue_for_inbox(inbox_id) }
        end

        # Historical backfill entry point (operator-invoked, one-time). For an EXPLICIT,
        # account-scoped allowlist of conversation ids that became open + unassigned BEFORE the
        # deletion bridge existed, mark each still-eligible one and enqueue the coalesced
        # per-inbox pass — sharing register_marker and the existing ProcessInboxJob pipeline with
        # the agent-deletion bridge. It differs from that bridge in exactly one way: a
        # conversation that ALREADY carries a marker is SKIPPED entirely (no re-mark, no enqueue),
        # because an existing marker means the live pipeline already owns it — the historical
        # backfill only ever adopts markerless conversations. The remaining per-id gate is the
        # shared Eligibility.deferrable? recheck (open, human- and bot-unassigned, legacy path,
        # native auto-assignment applicable), evaluated here and re-evaluated under the row lock
        # in InboxProcessor. Cross-account ids are impossible to act on because the scope is
        # pinned to account_id (they simply never match); the caller (HistoricalBackfill)
        # additionally rejects them distinctly before enqueue. Idempotent: the existing-marker
        # skip plus the unique conversation_id in register_marker mean a retried BackfillJob or a
        # re-submitted id never double-marks, and an already-marked/assigned/resolved id is a
        # safe no-op. Never a blanket scan — the allowlist is the entire work-list.
        def register_unassigned_historical(account_id, conversation_ids)
          adopt_markerless(account_id, conversation_ids)
        end

        # Provenance-backed entry point for the automatic one-time reconciliation (Reconciler).
        # The Reconciler has already established, from durable structured provenance, that each id
        # was assigned to a human agent who was subsequently deleted and is currently deferrable;
        # this narrowly named entry point marks exactly those account-scoped ids through the SAME
        # shared pipeline as every other path — no direct assignee write, no new engine.
        #
        # It differs from adopt_markerless in two deliberate, correctness-driven ways:
        #   1. It STAMPS the marker with +generation+ so the shared InboxProcessor can attribute the
        #      eventual assignment outcome back to this run. The generation is written only when THIS
        #      call creates the marker, so an existing (ordinary or already-reconciled) marker is
        #      never restamped and every non-reconciliation marker stays unchanged.
        #   2. It returns a STRUCTURED outcome { adopted:, inbox_ids: } reporting how many markers
        #      were ACTUALLY adopted here (marker.previously_new_record?) rather than pre-counted by
        #      the caller. A row that was marked or assigned between the Reconciler's classification
        #      and this call is re-checked (Marker.exists? / Eligibility.deferrable? / a
        #      concurrently-created marker) and reported as skipped, so "registered" can never
        #      overstate reality. It does NOT enqueue: the Reconciler owns the coalesced per-inbox
        #      pass, enqueuing AFTER its batch commits so a rolled-back adoption leaves no phantom job.
        # The unique conversation_id still keeps a retried run from double-marking.
        def register_unassigned_from_provenance(account_id, conversation_ids, generation:)
          adopted = 0
          affected_inbox_ids = []
          Conversation.where(account_id: account_id, id: conversation_ids).find_each do |conversation|
            next if Marker.exists?(conversation_id: conversation.id)
            next unless Eligibility.deferrable?(conversation)

            marker = register_reconciliation_marker(conversation, generation)
            next unless marker.previously_new_record?

            adopted += 1
            affected_inbox_ids << conversation.inbox_id
          end
          { adopted: adopted, inbox_ids: affected_inbox_ids.uniq }
        end

        # Shared body for the markerless-adoption paths (historical allowlist + provenance
        # reconciliation): for each account-scoped id, skip if it already carries a marker (the
        # live pipeline owns it), recheck Eligibility.deferrable?, then mark the still-eligible ones
        # via the idempotent find_or_create and enqueue one coalesced pass per affected inbox.
        def adopt_markerless(account_id, conversation_ids)
          affected_inbox_ids = []
          Conversation.where(account_id: account_id, id: conversation_ids).find_each do |conversation|
            next if Marker.exists?(conversation_id: conversation.id)
            next unless Eligibility.deferrable?(conversation)

            register_marker(conversation)
            affected_inbox_ids << conversation.inbox_id
          end
          affected_inbox_ids.uniq.each { |inbox_id| ProcessInboxJob.enqueue_for_inbox(inbox_id) }
        end

        # Shared marker registration used by every entry point (creation, deletion bridge,
        # historical backfill). find_or_create_by! keyed on the unique conversation_id, so it is
        # idempotent across retries and re-dispatches. Extracted verbatim from the original
        # inline call sites — the marking behavior is unchanged.
        def register_marker(conversation)
          Marker.find_or_create_by!(conversation_id: conversation.id) do |marker|
            marker.account_id = conversation.account_id
            marker.inbox_id = conversation.inbox_id
          end
        end

        # Reconciliation variant of register_marker: identical idempotent find_or_create keyed on
        # the unique conversation_id, but stamps the generation so the InboxProcessor can attribute
        # the assignment outcome back to the run. The generation is set only in the creation block,
        # so an existing marker (ordinary or already reconciliation-owned) is never restamped.
        def register_reconciliation_marker(conversation, generation)
          Marker.find_or_create_by!(conversation_id: conversation.id) do |marker|
            marker.account_id = conversation.account_id
            marker.inbox_id = conversation.inbox_id
            marker.reconciliation_generation = generation
          end
        end
      end
    end
  end
end
