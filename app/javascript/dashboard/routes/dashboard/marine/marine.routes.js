import { frontendURL } from '../../../helper/URLHelper';
import MarineIndex from './Index.vue';

const meta = {
  permissions: ['administrator', 'agent'],
};

export const routes = [
  {
    path: frontendURL('accounts/:accountId/marine'),
    component: MarineIndex,
    name: 'marine_assistants_index',
    meta,
  },
];
