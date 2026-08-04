# frozen_string_literal: true

# Route definitions for the Meta Ads team-routing battery. Drawn inside the
# api/v1 `scope module: :accounts` block, resolving to
# Api::V1::Accounts::Wijaya::* controllers. Owned entirely by this battery.
module Wijaya::Batteries::MetaAdsTeamRouting::Routes
  module_function

  def draw(mapper)
    mapper.instance_exec do
      namespace :wijaya do
        resources :meta_ads_team_routing_rules, only: %i[index show create update destroy]
      end
    end
  end
end
