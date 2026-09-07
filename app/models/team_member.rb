# == Schema Information
#
# Table name: team_members
#
#  id         :bigint           not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  team_id    :bigint           not null
#  user_id    :bigint           not null
#
# Indexes
#
#  index_team_members_on_team_id              (team_id)
#  index_team_members_on_team_id_and_user_id  (team_id,user_id) UNIQUE
#  index_team_members_on_user_id              (user_id)
#
class TeamMember < ApplicationRecord
  belongs_to :user
  belongs_to :team
  validates :user_id, uniqueness: { scope: :team_id }
  # WIJAYA_CUSTOM_START deferred_auto_assignment
  # A newly added team member may be the first eligible agent for team conversations waiting on
  # a deferred marker. Run after commit so a rolled-back add never enqueues; the battery gates on
  # markers for the team's inboxes and coalesces. Fail-open via the core dispatcher.
  after_create_commit :wijaya_process_deferred_on_team_member_added
  # WIJAYA_CUSTOM_END deferred_auto_assignment

  private

  # WIJAYA_CUSTOM_START deferred_auto_assignment
  def wijaya_process_deferred_on_team_member_added
    return unless defined?(Wijaya::Batteries::Core::Hooks)

    Wijaya::Batteries::Core::Hooks.dispatch(
      :deferred_auto_assignment, :on_team_member_added,
      default: nil, account_id: team.account_id, team_id: team_id
    )
  end
  # WIJAYA_CUSTOM_END deferred_auto_assignment
end

TeamMember.include_mod_with('Audit::TeamMember')
