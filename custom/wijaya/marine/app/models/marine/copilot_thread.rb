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
  has_many :copilot_messages, class_name: 'Marine::CopilotMessage', dependent: :destroy_async

  validates :title, presence: true

  scope :ordered, -> { order(created_at: :desc) }

  def previous_history
    copilot_messages
      .where(message_type: %w[user assistant])
      .order(created_at: :asc)
      .map { |message| { role: message.message_type, content: message.message['content'].to_s } }
  end
end
