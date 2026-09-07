# == Schema Information
#
# Table name: inbox_members
#
#  id         :integer          not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  inbox_id   :integer          not null
#  user_id    :integer          not null
#
# Indexes
#
#  index_inbox_members_on_inbox_id              (inbox_id)
#  index_inbox_members_on_inbox_id_and_user_id  (inbox_id,user_id) UNIQUE
#

class InboxMember < ApplicationRecord
  validates :inbox_id, presence: true
  validates :user_id, presence: true
  validates :user_id, uniqueness: { scope: :inbox_id }

  belongs_to :user
  belongs_to :inbox

  after_create :add_agent_to_round_robin
  after_destroy :remove_agent_from_round_robin
  # WIJAYA_CUSTOM_START deferred_auto_assignment
  # A newly added inbox member may be the first eligible agent for conversations in this inbox
  # that are waiting on a deferred marker. Run after commit so a rolled-back add never enqueues;
  # the battery gates on markers and coalesces per inbox. Fail-open via the core dispatcher.
  after_create_commit :wijaya_process_deferred_on_inbox_member_added
  # WIJAYA_CUSTOM_END deferred_auto_assignment

  private

  def add_agent_to_round_robin
    ::AutoAssignment::InboxRoundRobinService.new(inbox: inbox).add_agent_to_queue(user_id)
  end

  def remove_agent_from_round_robin
    ::AutoAssignment::InboxRoundRobinService.new(inbox: inbox).remove_agent_from_queue(user_id) if inbox.present?
  end

  # WIJAYA_CUSTOM_START deferred_auto_assignment
  def wijaya_process_deferred_on_inbox_member_added
    return unless defined?(Wijaya::Batteries::Core::Hooks)

    Wijaya::Batteries::Core::Hooks.dispatch(
      :deferred_auto_assignment, :on_inbox_member_added,
      default: nil, inbox_id: inbox_id
    )
  end
  # WIJAYA_CUSTOM_END deferred_auto_assignment
end

InboxMember.include_mod_with('Audit::InboxMember')
