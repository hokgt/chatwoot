module Wijaya::Marine::InboxExtensions
  extend ActiveSupport::Concern

  included do
    # Synchronous dependent: :destroy so the marine_inbox link row is removed in
    # the same transaction before the inbox, satisfying the marine_inboxes ->
    # inboxes foreign key.
    has_one :marine_inbox, dependent: :destroy
    has_one :marine_assistant, through: :marine_inbox
  end

  def active_bot?
    super || marine_active?
  end

  def marine_active?
    marine_assistant.present?
  end
end
