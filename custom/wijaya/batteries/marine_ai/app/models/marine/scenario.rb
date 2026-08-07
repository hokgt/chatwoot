# == Schema Information
#
# Table name: marine_scenarios
#
#  id           :bigint           not null, primary key
#  description  :text
#  enabled      :boolean          default(TRUE), not null
#  instruction  :text
#  title        :string
#  tools        :jsonb
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :bigint           not null
#  assistant_id :bigint           not null
#
# Indexes
#
#  index_marine_scenarios_on_account_id                (account_id)
#  index_marine_scenarios_on_assistant_id              (assistant_id)
#  index_marine_scenarios_on_assistant_id_and_enabled  (assistant_id,enabled)
#  index_marine_scenarios_on_enabled                   (enabled)
#
# Marine-owned scenario model. Fully independent of premium licensing, hub
# connectivity, pricing plans, and any premium feature flag. Marine tools are
# all account-scoped custom tools (Marine::CustomTool), so tool references
# resolve exclusively against the assistant's enabled custom tools.
class Marine::Scenario < ApplicationRecord
  self.table_name = 'marine_scenarios'

  belongs_to :assistant, class_name: 'Marine::Assistant'
  belongs_to :account

  validates :title, presence: true
  validates :description, presence: true
  validates :instruction, presence: true
  validates :assistant_id, presence: true
  validates :account_id, presence: true
  validate :validate_instruction_tools

  scope :enabled, -> { where(enabled: true) }

  # Derive the account from the assistant so a scenario can never be persisted with
  # an account that differs from its assistant's (cross-account scenarios are
  # impossible).
  before_validation :ensure_account
  before_save :resolve_tool_references

  # Custom HTTP tools have been removed to eliminate all direct outbound
  # connectivity between Marine AI and ERP; scenarios no longer resolve, expose,
  # validate, or persist any tool references.
  def resolved_tools = []

  def agent_tools = []

  private

  def ensure_account
    self.account_id = assistant.account_id if assistant
  end

  # No-op: tool references are no longer validated because tools are removed.
  def validate_instruction_tools = true

  # No-op: tool references are no longer materialized; the tools field stays nil.
  def resolve_tool_references
    self.tools = nil
  end

  def resolve_tool_instance(*) = nil
end
