class RoomChannel < ApplicationCable::Channel
  def subscribed
    # TODO: should we only do ensure stream  if current account is present?
    # for now going ahead with guard clauses in update_subscription and broadcast_presence
    current_user
    current_account
    ensure_stream
    update_subscription
    broadcast_presence
  end

  def update_presence
    update_subscription
    broadcast_presence
  end

  private

  def broadcast_presence
    return if @current_account.blank?

    data = { account_id: @current_account.id, users: ::OnlineStatusTracker.get_available_users(@current_account.id) }
    data[:contacts] = ::OnlineStatusTracker.get_available_contacts(@current_account.id) if @current_user.is_a? User
    ActionCable.server.broadcast(pubsub_token, { event: 'presence.update', data: data })
  end

  def ensure_stream
    stream_from pubsub_token
    stream_from "account_#{@current_account.id}" if @current_account.present? && @current_user.is_a?(User)
  end

  def update_subscription
    return if @current_account.blank?

    # WIJAYA_CUSTOM_START deferred_auto_assignment
    # Detect a real absent -> present transition for an agent (User only) BEFORE refreshing
    # presence, so a repeated heartbeat while already present never re-triggers processing.
    wijaya_agent_became_present = @current_user.is_a?(User) &&
                                  !::OnlineStatusTracker.get_presence(@current_account.id, @current_user.class.name, @current_user.id)
    # WIJAYA_CUSTOM_END deferred_auto_assignment

    ::OnlineStatusTracker.update_presence(@current_account.id, @current_user.class.name, @current_user.id)

    # WIJAYA_CUSTOM_START deferred_auto_assignment
    return unless wijaya_agent_became_present && defined?(Wijaya::Batteries::Core::Hooks)

    Wijaya::Batteries::Core::Hooks.dispatch(
      :deferred_auto_assignment, :on_agent_present,
      default: nil, account_id: @current_account.id, user_id: @current_user.id
    )
    # WIJAYA_CUSTOM_END deferred_auto_assignment
  end

  def pubsub_token
    @pubsub_token ||= params[:pubsub_token]
  end

  def current_user
    @current_user ||= if params[:user_id].blank?
                        ContactInbox.find_by!(pubsub_token: pubsub_token).contact
                      else
                        User.find_by!(pubsub_token: pubsub_token, id: params[:user_id])
                      end
  end

  def current_account
    return if current_user.blank?

    @current_account ||= if @current_user.is_a? Contact
                           @current_user.account
                         else
                           @current_user.accounts.find(params[:account_id])
                         end
  end
end
