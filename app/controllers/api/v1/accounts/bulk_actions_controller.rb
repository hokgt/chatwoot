require Rails.root.join('custom/wijaya/batteries/custom_roles/hooks')

class Api::V1::Accounts::BulkActionsController < Api::V1::Accounts::BaseController
  def create
    return render_assignment_forbidden if conversation_assignment_action? && !can_manage_conversation_assignment?

    case normalized_type
    when 'Conversation'
      enqueue_conversation_job
      head :ok
    when 'Contact'
      check_authorization_for_contact_action
      enqueue_contact_job
      head :ok
    else
      render json: { success: false }, status: :unprocessable_entity
    end
  end

  private

  def conversation_assignment_action?
    # WIJAYA_CUSTOM_START custom_roles_rbac
    Wijaya::Batteries::CustomRoles::Hooks.conversation_assignment_action?(
      normalized_type: normalized_type,
      fields: conversation_params[:fields]
    )
    # WIJAYA_CUSTOM_END custom_roles_rbac
  end

  def can_manage_conversation_assignment?
    # WIJAYA_CUSTOM_START custom_roles_rbac
    Wijaya::Batteries::CustomRoles::Hooks.can_manage_all_conversations?(Current.account_user)
    # WIJAYA_CUSTOM_END custom_roles_rbac
  end

  def render_assignment_forbidden
    # WIJAYA_CUSTOM_START custom_roles_rbac
    render json: Wijaya::Batteries::CustomRoles::Hooks.assignment_forbidden_response, status: :forbidden
    # WIJAYA_CUSTOM_END custom_roles_rbac
  end

  def normalized_type
    params[:type].to_s.camelize
  end

  def enqueue_conversation_job
    ::BulkActionsJob.perform_later(
      account: @current_account,
      user: current_user,
      params: conversation_params
    )
  end

  def enqueue_contact_job
    Contacts::BulkActionJob.perform_later(
      @current_account.id,
      current_user.id,
      contact_params
    )
  end

  def delete_contact_action?
    params[:action_name] == 'delete'
  end

  def check_authorization_for_contact_action
    authorize(Contact, :destroy?) if delete_contact_action?
  end

  def conversation_params
    # TODO: Align conversation payloads with the `{ action_name, action_attributes }`
    # and then remove this method in favor of a common params method.
    base = params.permit(
      :snoozed_until,
      fields: [:status, :assignee_id, :team_id]
    )
    append_common_bulk_attributes(base)
  end

  def contact_params
    # TODO: remove this method in favor of a common params method.
    # once legacy conversation payloads are migrated.
    append_common_bulk_attributes({})
  end

  def append_common_bulk_attributes(base_params)
    # NOTE: Conversation payloads historically diverged per action. Going forward we
    # want all objects to share a common contract: `{ action_name, action_attributes }`
    common = params.permit(:type, :action_name, ids: [], labels: [add: [], remove: []])
    base_params.merge(common)
  end
end
