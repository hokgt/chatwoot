# frozen_string_literal: true

# Attaches the per-conversation ERP Lead draft association to core Conversation
# via to_prepare (see loader.rb), keeping app/models/conversation.rb unmodified.
# There is at most one draft per (account, conversation) — enforced by a unique
# index — so this is a has_one; dependent: :destroy cleans it up with the
# conversation. Required directly (not Zeitwerk) like the rest of this battery.
module Wijaya::Batteries::ErpLeadSidebar::ConversationExtensions
  extend ActiveSupport::Concern

  included do
    has_one :wijaya_erp_lead_draft, dependent: :destroy, class_name: 'Wijaya::ErpLeadDraft'
  end
end
