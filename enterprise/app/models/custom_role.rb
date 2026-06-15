# == Schema Information
#
# Table name: custom_roles
#
#  id          :bigint           not null, primary key
#  description :string
#  name        :string
#  permissions :text             default([]), is an Array
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  account_id  :bigint           not null
#
# Indexes
#
#  index_custom_roles_on_account_id  (account_id)
#
#

# Available permissions for custom roles:
# - 'conversation_manage': Can manage all conversations.
# - 'conversation_unassigned_manage': Can manage unassigned conversations and assign to self.
# - 'conversation_participating_manage': Can manage conversations they are participating in (assigned to or a participant).
# - 'contact_manage': Can manage contacts.
# - 'report_manage': Can manage reports.
# - 'knowledge_base_manage': Can manage knowledge base portals.

class CustomRole < ApplicationRecord
  belongs_to :account
  has_many :account_users, dependent: :nullify

  PERMISSIONS = %w[
    conversation_manage
    conversation_unassigned_manage
    conversation_participating_manage
    contact_manage
    report_manage
    knowledge_base_manage
  ].freeze

  CONVERSATION_PERMISSIONS = %w[
    conversation_manage
    conversation_unassigned_manage
    conversation_participating_manage
  ].freeze

  validates :name, presence: true
  validate :permissions_are_known
  validate :exactly_one_conversation_permission

  private

  def permissions_are_known
    unknown_permissions = permissions - PERMISSIONS
    return if unknown_permissions.blank?

    errors.add(:permissions, "contains unsupported permissions: #{unknown_permissions.join(', ')}")
  end

  def exactly_one_conversation_permission
    selected_conversation_permissions = permissions & CONVERSATION_PERMISSIONS
    return if selected_conversation_permissions.one?

    errors.add(:permissions, 'must include exactly one conversation permission')
  end
end
