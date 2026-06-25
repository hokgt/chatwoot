# frozen_string_literal: true

module Wijaya
  module Batteries
    module CustomRoles
      module Hooks
        CONVERSATION_MANAGE = 'conversation_manage'
        CONVERSATION_UNASSIGNED_MANAGE = 'conversation_unassigned_manage'
        CONVERSATION_PARTICIPATING_MANAGE = 'conversation_participating_manage'

        CONVERSATION_PERMISSIONS = [
          CONVERSATION_MANAGE,
          CONVERSATION_UNASSIGNED_MANAGE,
          CONVERSATION_PARTICIPATING_MANAGE
        ].freeze

        module_function

        def validate_known_permissions!(record, available_permissions)
          unknown_permissions = record.permissions - available_permissions
          return if unknown_permissions.blank?

          record.errors.add(:permissions, "contains unsupported permissions: #{unknown_permissions.join(', ')}")
        end

        def validate_exactly_one_conversation_permission!(record)
          selected_conversation_permissions = record.permissions & CONVERSATION_PERMISSIONS
          return if selected_conversation_permissions.one?

          record.errors.add(:permissions, 'must include exactly one conversation permission')
        end

        def account_user_permissions(account_user, default_permissions)
          return default_permissions if account_user.administrator?

          account_user.custom_role.present? ? (account_user.custom_role.permissions + ['custom_role']) : default_permissions
        end

        def can_manage_all_conversations?(account_user)
          account_user&.administrator? || account_user&.permissions&.include?(CONVERSATION_MANAGE)
        end

        def custom_role_agent?(account_user)
          account_user&.agent? && account_user&.custom_role_id.present?
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
      end
    end
  end
end
