import { frontendURL } from '../../../../helper/URLHelper';
import SettingsWrapper from '../SettingsWrapper.vue';
import Index from './Index.vue';

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/marine'),
      component: SettingsWrapper,
      props: {
        headerTitle: 'MARINE_SETTINGS.TITLE',
        icon: 'i-lucide-ship-wheel',
        showNewButton: false,
      },
      children: [
        {
          path: '',
          name: 'marine_settings_index',
          component: Index,
          meta: { permissions: ['administrator'] },
        },
      ],
    },
  ],
};
