# frozen_string_literal: true

# Nested (not compact `module Wijaya::Batteries::CustomRoles::Hooks`) so this file
# is standalone-safe: native app files (controllers, finders, models) `require` it
# at their own load time, which is not guaranteed to be after the Wijaya battery
# initializer. No loader creates the CustomRoles namespace, so this nested
# declaration is its sole creator; a compact form raises `uninitialized constant
# Wijaya::Batteries::CustomRoles` (one of the exact CI collection failures).
module Wijaya
  module Batteries
    module CustomRoles
      module Hooks
        CONVERSATION_MANAGE = 'conversation_manage'
        CONVERSATION_UNASSIGNED_MANAGE = 'conversation_unassigned_manage'
        CONVERSATION_PARTICIPATING_MANAGE = 'conversation_participating_manage'

        module_function

        def validate_known_permissions!(record, available_permissions)
          unknown_permissions = record.permissions - available_permissions
          return if unknown_permissions.blank?

          record.errors.add(:permissions, "contains unsupported permissions: #{unknown_permissions.join(', ')}")
        end

        def account_user_permissions(account_user, default_permissions)
          return default_permissions if account_user.administrator?

          account_user.custom_role.present? ? (account_user.custom_role.permissions + ['custom_role']) : default_permissions
        end

        # Only custom-role AGENTS are subject to Wijaya conversation-assignment gating.
        # Administrators and ordinary (non-custom-role) agents must retain native
        # assignment / self-assignment behaviour, so this returns true for them and
        # delegates the restriction exclusively to custom-role agents, who then require
        # the explicit `conversation_manage` permission to manage all conversations.
        def can_manage_all_conversations?(account_user)
          return true if account_user&.administrator?
          return true unless custom_role_agent?(account_user)

          account_user.permissions.include?(CONVERSATION_MANAGE)
        end

        def custom_role_agent?(account_user)
          account_user&.agent? && account_user&.custom_role_id.present?
        end

        # Native conversation show uses Pundit authorization (401), while the
        # Enterprise reporting-events endpoint intentionally uses the explicit
        # forbidden response (403). Wijaya custom-role agents also need the 403
        # path so their scoped conversation policy is evaluated consistently.
        def explicit_conversation_forbidden_response?(account_user:, action_name:)
          custom_role_agent?(account_user) || action_name.to_s == 'reporting_events'
        end

        def conversation_visible?(conversation, user, account)
          Conversations::PermissionFilterService.allowed?(conversation, user, account)
        end

        def conversation_allowed?(conversation, user, account)
          Conversations::PermissionFilterService.new(account.conversations, user, account).perform.exists?(id: conversation.id)
        end

        def filter_by_permissions(accessible_conversations:, permissions:, user:)
          if permissions.include?(CONVERSATION_MANAGE)
            accessible_conversations
          elsif permissions.include?(CONVERSATION_UNASSIGNED_MANAGE)
            filter_unassigned_and_mine(accessible_conversations, user)
          elsif permissions.include?(CONVERSATION_PARTICIPATING_MANAGE)
            filter_participating_and_mine(accessible_conversations, user)
          else
            Conversation.none
          end
        end

        def filter_unassigned_and_mine(accessible_conversations, user)
          accessible_conversations.where(assignee_id: [nil, user.id])
        end

        def filter_participating_and_mine(accessible_conversations, user)
          conversations_table = Conversation.arel_table
          participants_table = ConversationParticipant.arel_table
          allowed_condition = conversations_table[:assignee_id].eq(user.id).or(participants_table[:user_id].eq(user.id))

          accessible_conversations
            .left_joins(:conversation_participants)
            .where(allowed_condition)
            .distinct
        end

        def participating_filter(conversations, user)
          conversations.left_joins(:conversation_participants)
                       .where(conversation_participants: { user_id: user.id })
                       .distinct
        end

        def conversation_assignment_action?(normalized_type:, fields:)
          return false unless normalized_type == 'Conversation'

          fields&.key?(:assignee_id) || fields&.key?('assignee_id') ||
            fields&.key?(:team_id) || fields&.key?('team_id')
        end

        def assignment_forbidden_response
          { error: 'You are not authorized to assign conversations' }
        end

        def conversation_forbidden_response
          { error: 'You are not authorized to access this conversation' }
        end

        def permitted_agent_account_user_attributes(default_attributes)
          (default_attributes + [:custom_role_id]).uniq
        end

        def permitted_agent_attributes(default_attributes)
          (default_attributes + [:custom_role_id]).uniq
        end

        def agent_builder_account_user_attributes(base_attributes, custom_role_id)
          base_attributes.merge(custom_role_id: custom_role_id).compact
        end

        # Enterprise agents controller create/update hook: associates the agent's
        # account_user with the submitted custom_role_id. Accepts either a nested
        # `agent[custom_role_id]` param or a top-level `custom_role_id`. No-op /
        # fail-open when the key is absent so native agent create/update is unchanged.
        def associate_agent_with_custom_role(agent, params)
          return unless params[:agent]&.key?(:custom_role_id) || params.key?(:custom_role_id)

          custom_role_id = params.dig(:agent, :custom_role_id) || params[:custom_role_id]
          agent.current_account_user.update!(custom_role_id: custom_role_id)
        end
      end
    end
  end
end
