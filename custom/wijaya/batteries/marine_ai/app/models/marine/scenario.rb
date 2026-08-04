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
  # Matches markdown tool references like [Tool name](tool://tool_slug).
  TOOL_REFERENCE_REGEX = %r{\[[^\]]+\]\(tool://([^/)]+)\)}

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

  # Tool metadata for the tools currently referenced by the scenario, resolved
  # against the assistant's available (enabled) Marine custom tools.
  def resolved_tools
    return [] if tools.blank?

    available_tools = assistant.available_agent_tools
    tools.filter_map do |tool_id|
      available_tools.find { |tool| tool[:id] == tool_id }
    end
  end

  # Instantiated tool objects for scenario execution. Deferred usage — exposed
  # now so Marine LLM scenario execution can consume them later.
  def agent_tools
    resolved_tools.filter_map { |tool| resolve_tool_instance(tool) }
  end

  private

  def ensure_account
    self.account_id = assistant.account_id if assistant
  end

  def extract_tool_ids_from_text(text)
    return [] if text.blank?

    text.scan(TOOL_REFERENCE_REGEX).flatten.uniq
  end

  def resolve_tool_instance(tool_metadata)
    custom_tool = Marine::CustomTool.find_by(slug: tool_metadata[:id], account_id: account_id, enabled: true)
    custom_tool&.tool(assistant)
  end

  # Rejects tool references in the instruction that do not map to an enabled
  # custom tool for the assistant's account.
  def validate_instruction_tools
    return if instruction.blank?

    tool_ids = extract_tool_ids_from_text(instruction)
    return if tool_ids.empty?

    invalid_tools = tool_ids - assistant.available_tool_ids
    return if invalid_tools.empty?

    errors.add(:instruction, "contains invalid tools: #{invalid_tools.join(', ')}")
  end

  # Materializes the tool references from the instruction text into the tools
  # JSONB field. Sets tools to nil when no references are present.
  def resolve_tool_references
    return if instruction.blank?

    self.tools = extract_tool_ids_from_text(instruction).presence
  end
end
