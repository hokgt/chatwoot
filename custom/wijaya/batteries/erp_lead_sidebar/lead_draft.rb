# frozen_string_literal: true

# Per-conversation ERP Lead draft. Holds the agent-confirmed form values as a
# free-form JSON `fields` blob (frontend is the source of truth for values),
# plus the ERP Lead reference once a lead has been created and the last sync
# error for retry UX. One draft per (account, conversation).
#
# Loaded via require (see config/initializers/wijaya_erp_lead_sidebar.rb), not
# Zeitwerk, since it lives under the non-autoloaded custom/ battery path.
class Wijaya::ErpLeadDraft < ApplicationRecord
  self.table_name = 'wijaya_erp_lead_drafts'

  belongs_to :account
  belongs_to :conversation

  validates :conversation_id, uniqueness: { scope: :account_id }

  # Ensure `fields` always reads back as a Hash even when never written.
  def fields
    super || {}
  end

  def synced?
    erp_lead_id.present?
  end
end
