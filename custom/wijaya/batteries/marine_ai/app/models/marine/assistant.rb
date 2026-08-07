class Marine::Assistant < ApplicationRecord
  include Avatarable
  self.table_name = 'marine_assistants'

  belongs_to :account
  # Synchronous dependent: :destroy (not destroy_async) so children are removed in
  # the same transaction before the assistant row, satisfying the restrictive
  # foreign keys on assistant_id / marine_assistant_id and preserving each child's
  # own callback cleanup (e.g. Marine::Document source_file purge and its
  # documentable responses).
  has_many :documents, class_name: 'Marine::Document', dependent: :destroy
  has_many :responses, class_name: 'Marine::AssistantResponse', dependent: :destroy
  has_many :marine_inboxes, class_name: 'MarineInbox', foreign_key: :marine_assistant_id, dependent: :destroy
  has_many :inboxes, through: :marine_inboxes
  has_many :scenarios, class_name: 'Marine::Scenario', dependent: :destroy
  has_many :copilot_threads, class_name: 'Marine::CopilotThread', dependent: :destroy
  has_many :messages, as: :sender, dependent: :nullify

  store_accessor :config, :temperature, :feature_faq, :feature_memory, :feature_contact_attributes, :product_name, :welcome_message,
                 :handoff_message, :resolution_message, :instructions

  validates :name, :description, :account_id, presence: true

  scope :ordered, -> { order(created_at: :desc) }
  scope :for_account, ->(account_id) { where(account_id: account_id) }

  def available_name = name

  # Custom HTTP tools have been removed to eliminate all direct outbound
  # connectivity between Marine AI and ERP; no agent tools are exposed anymore.
  def available_agent_tools = []

  def available_tool_ids = []

  def push_event_data
    { id: id, name: name, avatar_url: avatar_url.presence || default_avatar_url, description: description, created_at: created_at,
      type: 'marine_assistant' }
  end

  def webhook_data = push_event_data

  def default_avatar_url
    "#{ENV.fetch('FRONTEND_URL', nil)}/assets/images/dashboard/marine/logo.svg"
  end
end
