// WIJAYA_CUSTOM meta_ads_team_routing
import { frontendURL } from '../../../../helper/URLHelper';
import SettingsWrapper from '../SettingsWrapper.vue';
import MetaAdsRoutingIndex from './Index.vue';

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/wijaya/meta-ads-routing'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          name: 'wijaya_meta_ads_routing_index',
          component: MetaAdsRoutingIndex,
          meta: {
            permissions: ['administrator'],
          },
        },
      ],
    },
  ],
};
