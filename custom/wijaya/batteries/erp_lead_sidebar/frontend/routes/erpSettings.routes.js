// WIJAYA_CUSTOM erp_lead_sidebar
import { frontendURL } from 'dashboard/helper/URLHelper';
import SettingsWrapper from 'dashboard/routes/dashboard/settings/SettingsWrapper.vue';
import ErpSettingsIndex from './ErpSettings.vue';

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/wijaya/erp-settings'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          name: 'wijaya_erp_settings_index',
          component: ErpSettingsIndex,
          meta: {
            permissions: ['administrator'],
          },
        },
      ],
    },
  ],
};
