# frozen_string_literal: true

# Read-only discovery / dry-run for the historical backfill (operator-invoked, one-time).
#
# It surfaces conversations that became open + unassigned BEFORE the agent-deletion bridge
# existed and therefore carry no deferred marker, so an operator can review them and decide
# which (if any) to hand to the explicit-allowlist apply path (HistoricalBackfill). It is
# provably read-only: it only SELECTs — it never creates a marker, enqueues a job, assigns a
# conversation, updates any row, calls ERP, or otherwise mutates state. Nothing it returns
# flows automatically into apply; the operator must copy the ids they approve.
#
# Scope is always pinned to an explicit account and bounded by a hard limit (never an
# unbounded account-wide load). Default discovery criteria (open, assignee_id NULL,
# assignee_agent_bot_id NULL, no existing marker) are a REVIEW starting point only — matching
# them is not approval and does not imply the conversation should be reassigned.
#
# Evidence per candidate is structured for operator review. The only free text included is
# the latest assignment-related ACTIVITY message (a staff-facing system event such as
# "Assigned to X by the System"); customer message bodies are never read or emitted. Free
# text is evidence only — it is never treated as proof and never drives approval. The
# apparent_target classification is a best-effort heuristic label (current_agent /
# current_team / deleted_or_unknown / ambiguous), explicitly "apparent", never authoritative.
module Wijaya
  module Batteries
    module DeferredAutoAssignment
      module HistoricalDiscovery
        module_function

        DEFAULT_LIMIT = 100
        MAX_LIMIT = 500

        # account_id (required, explicit). Optional inbox_id narrows the scan. Optional
        # conversation_ids previews EXACTLY those ids (marker presence reported, not excluded)
        # so an operator can inspect a proposed allowlist before applying; without it, the
        # default criteria are scanned. limit is always clamped to MAX_LIMIT.
        def discover(account_id:, limit: DEFAULT_LIMIT, inbox_id: nil, conversation_ids: nil)
          candidate_scope(account_id, inbox_id, conversation_ids)
            .limit(bounded_limit(limit))
            .map { |conversation| evidence_for(conversation) }
        end

        def candidate_scope(account_id, inbox_id, conversation_ids)
          scope = Conversation.where(account_id: account_id, status: Conversation.statuses[:open])
                              .where(assignee_id: nil, assignee_agent_bot_id: nil)
          scope = scope.where(inbox_id: inbox_id) if inbox_id.present?
          if conversation_ids.nil?
            # Default work-list (only when NO allowlist is supplied): exclude conversations that
            # already carry a marker (those are handled by the normal live pipeline, not the
            # historical backfill).
            scope.where.not(id: Marker.where(account_id: account_id).select(:conversation_id)).order(:id)
          else
            # An EXPLICIT allowlist previews exactly those ids — including an empty one, which
            # must return no rows and never silently fall back to the broad default scan.
            scope.where(id: conversation_ids).order(:id)
          end
        end

        def evidence_for(conversation)
          activity = latest_assignment_activity(conversation)
          {
            conversation_id: conversation.id,
            display_id: conversation.display_id,
            account_id: conversation.account_id,
            inbox_id: conversation.inbox_id,
            team_id: conversation.team_id,
            status: conversation.status,
            assignee_id: conversation.assignee_id,
            assignee_agent_bot_id: conversation.assignee_agent_bot_id,
            marker_present: Marker.exists?(conversation_id: conversation.id),
            created_at: conversation.created_at,
            updated_at: conversation.updated_at,
            latest_assignment_activity: activity,
            apparent_target: classify(conversation, activity),
            linked_erp_lead: linked_erp_lead?(conversation),
            deferrable: Eligibility.deferrable?(conversation)
          }
        end

        def bounded_limit(limit)
          value = limit.to_i
          return DEFAULT_LIMIT if value <= 0

          [value, MAX_LIMIT].min
        end

        # Latest ACTIVITY message that looks assignment-related. Read-only, activity-type only
        # (never a customer incoming/outgoing body), sanitized to a bounded single line.
        def latest_assignment_activity(conversation)
          message = conversation.messages
                                .where(message_type: Message.message_types[:activity])
                                .where('content ILIKE ?', '%assign%')
                                .order(created_at: :desc)
                                .first
          return nil if message.nil?

          { id: message.id, created_at: message.created_at, content: sanitize(message.content) }
        end

        def sanitize(text)
          text.to_s.gsub(/\s+/, ' ').strip.truncate(200)
        end

        # Best-effort, explicitly "apparent" label parsed from the bounded activity evidence —
        # never authoritative, never used for approval or apply. The apparent target NAME is
        # pulled from the latest assignment activity and compared case-insensitively against the
        # current account's users AND teams:
        #   * matches a user only          -> current_agent
        #   * matches a team only          -> current_team
        #   * matches neither              -> deleted_or_unknown (the deleted-agent case)
        #   * no activity / unparseable /
        #     matches both a user and team -> ambiguous
        def classify(conversation, activity)
          return :ambiguous if activity.nil?

          name = apparent_assignee_name(activity[:content])
          return :ambiguous if name.blank?

          apparent_target_for(conversation.account_id, name)
        rescue StandardError
          :ambiguous
        end

        def apparent_target_for(account_id, name)
          user_match = account_has_agent_named?(account_id, name)
          team_match = account_has_team_named?(account_id, name)
          return :ambiguous if user_match && team_match
          return :current_agent if user_match
          return :current_team if team_match

          :deleted_or_unknown
        end

        def apparent_assignee_name(content)
          match = content.to_s.match(/assigned to (.+?)(?: by | via | from |$)/i)
          match && match[1].strip
        end

        def account_has_agent_named?(account_id, name)
          Account.find(account_id).users.exists?(['LOWER(name) = ?', name.downcase])
        end

        def account_has_team_named?(account_id, name)
          Account.find(account_id).teams.exists?(['LOWER(name) = ?', name.downcase])
        end

        def linked_erp_lead?(conversation)
          return false unless conversation.respond_to?(:wijaya_erp_lead_draft)

          draft = conversation.wijaya_erp_lead_draft
          draft.present? && draft.erp_lead_id.present?
        rescue StandardError
          false
        end
      end
    end
  end
end
