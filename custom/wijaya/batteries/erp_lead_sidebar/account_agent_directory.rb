# frozen_string_literal: true

# Account-scoped Chatwoot agent directory for the ERP Lead Owner picker.
#
# The Lead Owner options come from the agents registered with THIS Chatwoot
# account (account.users, i.e. the account_users membership that native Chatwoot
# lists in Agent settings and uses for assignment — administrators and agents
# alike). It is deliberately NOT the ERPNext User list: no ERP request is made to
# populate the picker. Contacts, agent bots/system users, and users belonging to
# other accounts are never account.users, so they are never offered.
#
# Each option's value AND label is the agent's email, which is the exact value
# persisted as the manual override / automatic default and written to the ERP
# Lead owner. The browser is untrusted, so `agent?` re-confirms any submitted
# email is a current-account Chatwoot agent before it is stored/enqueued; the
# ERP owner write itself stays fail-closed validated downstream by the
# erp_lead_owner_sync battery (LeadActivityPersonDirectory.valid? before the PUT).
#
# Declared with the compact style (the repo's EnforcedStyle) as a single
# constant: this helper references no unqualified sibling constants, so it needs
# nothing but its own namespace in Module.nesting.
module Wijaya::Batteries::ErpLeadSidebar::AccountAgentDirectory
  module_function

  # [{ value:, label: }] for every Chatwoot agent of the account, value and
  # label both the agent email, ordered by email (the value the picker displays
  # and persists). A local DB read: it never raises SyncError and never issues
  # an ERP request.
  def fetch_options(account)
    account.users
           .order(:email)
           .pluck(:email)
           .compact_blank
           .uniq
           .map { |email| { value: email, label: email } }
  end

  # True only when `email` is the exact email of a current-account Chatwoot
  # agent. A blank value is never valid. Used as the server-side gate so a
  # fabricated/cross-account/non-agent email can never be stored as the owner.
  def agent?(account, email)
    target = email.to_s.strip
    return false if target.empty?

    account.users.exists?(email: target)
  end
end
