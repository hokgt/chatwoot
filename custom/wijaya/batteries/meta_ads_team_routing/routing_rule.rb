# frozen_string_literal: true

# Account-scoped mapping between a Meta Ads Ad ID (normalized referral source_id)
# and the Chatwoot Team that brand-new conversations from that ad should route to.
# Loaded via the battery loader (custom/wijaya/batteries/meta_ads_team_routing/loader.rb),
# not Zeitwerk, so it lives under the battery path without an autoload root.
class Wijaya::MetaAdsTeamRoutingRule < ApplicationRecord
  self.table_name = 'wijaya_meta_ads_team_routing_rules'

  belongs_to :account
  belongs_to :team

  # Rails `enum` auto-generates the `.active` / `.inactive` scopes and predicates
  # used by the routing service and the admin API.
  enum status: { inactive: 0, active: 1 }

  validates :source_id, presence: true, uniqueness: { scope: :account_id }
  validate :team_belongs_to_account

  private

  def team_belongs_to_account
    return if team.blank? || account_id.blank?

    errors.add(:team, 'must belong to the same account') if team.account_id != account_id
  end
end
