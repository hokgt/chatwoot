module Enterprise::Conversations::PermissionFilterService
  def perform
    return filter_by_permissions(permissions) if user_has_custom_role?

    super
  end

  private

  def user_has_custom_role?
    user_role == 'agent' && account_user&.custom_role_id.present?
  end

  def permissions
    account_user&.permissions || []
  end

  def filter_by_permissions(permissions)
    # Permission-based filtering with hierarchy
    # conversation_manage > conversation_unassigned_manage > conversation_participating_manage
    if permissions.include?('conversation_manage')
      accessible_conversations
    elsif permissions.include?('conversation_unassigned_manage')
      filter_unassigned_and_mine
    elsif permissions.include?('conversation_participating_manage')
      filter_participating_and_mine
    else
      Conversation.none
    end
  end

  def filter_unassigned_and_mine
    accessible_conversations.where(assignee_id: [nil, user.id])
  end

  def filter_participating_and_mine
    conversations_table = Conversation.arel_table
    participants_table = ConversationParticipant.arel_table
    allowed_condition = conversations_table[:assignee_id].eq(user.id).or(participants_table[:user_id].eq(user.id))

    accessible_conversations
      .left_joins(:conversation_participants)
      .where(allowed_condition)
      .distinct
  end
end
