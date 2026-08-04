class MarineInbox < ApplicationRecord
  belongs_to :marine_assistant, class_name: 'Marine::Assistant'
  belongs_to :inbox

  validates :inbox_id, uniqueness: true
  # A Marine assistant may only be linked to an inbox from its own account.
  validate :assistant_and_inbox_same_account

  private

  def assistant_and_inbox_same_account
    return if marine_assistant.nil? || inbox.nil?
    return if marine_assistant.account_id == inbox.account_id

    errors.add(:inbox, 'must belong to the same account as the assistant')
  end
end
