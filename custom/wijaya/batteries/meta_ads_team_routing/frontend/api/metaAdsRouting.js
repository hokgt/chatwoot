import ApiClient from 'dashboard/api/ApiClient';

// WIJAYA_CUSTOM meta_ads_team_routing
// Admin API for Meta Ads Ad ID -> Team routing rules.
class MetaAdsRoutingAPI extends ApiClient {
  constructor() {
    super('wijaya/meta_ads_team_routing_rules', { accountScoped: true });
  }
}

export default new MetaAdsRoutingAPI();
