import { FEATURE_FLAGS } from '../../../../featureFlags';
// WIJAYA_CUSTOM_START custom_roles_rbac
import { customRoleInstallationTypes } from '../../../../../../../custom/wijaya/batteries/custom_roles/frontend/permissions';
// WIJAYA_CUSTOM_END custom_roles_rbac
import { frontendURL } from 'dashboard/helper/URLHelper';

import SettingsWrapper from '../SettingsWrapper.vue';
import CustomRolesHome from './Index.vue';

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/custom-roles'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          redirect: 'list',
        },
        {
          path: 'list',
          name: 'custom_roles_list',
          meta: {
            featureFlag: FEATURE_FLAGS.CUSTOM_ROLES,
            // WIJAYA_CUSTOM_START custom_roles_rbac
            installationTypes: customRoleInstallationTypes,
            // WIJAYA_CUSTOM_END custom_roles_rbac
            permissions: ['administrator'],
          },
          component: CustomRolesHome,
        },
      ],
    },
  ],
};
