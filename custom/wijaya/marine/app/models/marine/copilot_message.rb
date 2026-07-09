# == Schema Information
#
# Table name: marine_copilot_messages
#
#  id                :bigint           not null, primary key
#  message           :jsonb            not null
#  message_type      :integer          default("user"), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :bigint           not null
#  copilot_thread_id :bigint           not null
#
# Marine-owned copilot message. Belongs to a Marine copilot thread. The message
# payload is a small JSON hash — assistant answers additionally carry the cited
# conversation/contact records under the `citations` key.
class Marine::CopilotMessage < ApplicationRecord
  self.table_name = 'marine_copilot_messages'

  ALLOWED_MESSAGE_KEYS = %w[content citations error].freeze

  belongs_to :copilot_thread, class_name: 'Marine::CopilotThread'
  belongs_to :account

  enum message_type: { user: 0, assistant: 1 }

  validates :message_type, presence: true
  validates :message, presence: true
  before_validation :ensure_account
  validate :validate_message_attributes

  def push_event_data
    {
      id: id,
      message: message,
      message_type: message_type,
      created_at: created_at.to_i,
      copilot_thread_id: copilot_thread_id
    }
  end

  private

  def ensure_account
    self.account_id ||= copilot_thread&.account_id
  end

  def validate_message_attributes
    return if message.blank?

    invalid_keys = message.keys.map(&:to_s) - ALLOWED_MESSAGE_KEYS
    errors.add(:message, "contains invalid attributes: #{invalid_keys.join(', ')}") if invalid_keys.any?
  end
end
