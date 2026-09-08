# == Schema Information
#
# Table name: marine_copilot_threads
#
#  id           :bigint           not null, primary key
#  title        :string           not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :bigint           not null
#  assistant_id :bigint           not null
#  user_id      :bigint           not null
#
# Marine-owned copilot thread. Fully independent of Captain premium licensing,
# Chatwoot Hub, pricing plans, and any premium feature flag. A thread is owned by
# a Marine assistant and scoped to the account + user that created it.
class Marine::CopilotThread < ApplicationRecord
  self.table_name = 'marine_copilot_threads'

  belongs_to :account
  belongs_to :user
  belongs_to :assistant, class_name: 'Marine::Assistant'
  # Synchronous dependent: :destroy so messages are removed in the same transaction
  # before the thread, satisfying the marine_copilot_messages -> marine_copilot_threads
  # foreign key.
  has_many :copilot_messages, class_name: 'Marine::CopilotMessage', dependent: :destroy

  validates :title, presence: true

  # Derive the account from the assistant so a thread can never be persisted with an
  # account that differs from its assistant's (cross-account threads are impossible).
  before_validation :ensure_account

  scope :ordered, -> { order(created_at: :desc) }

  def previous_history
    copilot_messages
      .where(message_type: %w[user assistant])
      .order(created_at: :asc)
      .map { |message| { role: message.message_type, content: message.message['content'].to_s } }
  end

  private

  def ensure_account
    self.account_id = assistant.account_id if assistant
  end
end
