# frozen_string_literal: true

# WIJAYA_CUSTOM_START meta_ads_team_routing
# Loads the Meta Ads -> Team routing battery (model, service, hooks). These files live
# under custom/ which is not a Zeitwerk autoload root, so we require them explicitly.
# Wrapped in to_prepare so the ApplicationRecord-backed model is (re)loaded on boot and
# on each development reload.
Rails.application.config.to_prepare do
  require Rails.root.join('custom/wijaya/batteries/meta_ads_team_routing/hooks').to_s
end
# WIJAYA_CUSTOM_END meta_ads_team_routing
