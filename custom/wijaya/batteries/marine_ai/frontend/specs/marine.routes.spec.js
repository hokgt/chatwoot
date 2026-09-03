// The route components are page shells that transitively pull in shared dashboard
// stores; loading them as a test entry point triggers a circular import unrelated
// to what we assert here (route RBAC metadata). Stub each component module — they
// resolve to the same absolute IDs marine.routes.js imports, so these stubs
// intercept them — leaving the real `meta` wiring under test.
vi.mock('../routes/marine/Index.vue', () => ({ default: {} }));
vi.mock('../routes/marine/pages/AssistantsIndexPage.vue', () => ({
  default: {},
}));
vi.mock('../routes/marine/responses/Index.vue', () => ({ default: {} }));
vi.mock('../routes/marine/documents/Index.vue', () => ({ default: {} }));
vi.mock('../routes/marine/scenarios/Index.vue', () => ({ default: {} }));
vi.mock('../routes/marine/copilot/Index.vue', () => ({ default: {} }));
vi.mock('../routes/marine/playground/Index.vue', () => ({ default: {} }));
vi.mock('../routes/marine/inboxes/Index.vue', () => ({ default: {} }));
vi.mock('../routes/marine/settings/Index.vue', () => ({ default: {} }));
vi.mock('../routes/marine/llm-settings/Index.vue', () => ({ default: {} }));
vi.mock('../routes/marine/guardrails/Index.vue', () => ({ default: {} }));
vi.mock('../routes/marine/guidelines/Index.vue', () => ({ default: {} }));

import { routes } from '../routes/marine/marine.routes';
import { routeIsAccessibleFor } from 'dashboard/helper/routeHelpers';

// Marine route RBAC: the three admin-only areas (Inboxes, AI Provider / LLM
// Settings, Settings — including its Guardrails and Response Guidelines subroutes)
// carry meta.permissions === ['administrator'], so the shared router guard
// (routeIsAccessibleFor / hasPermissions) blocks direct navigation for every
// non-administrator. All other Marine routes keep ['administrator', 'agent'].
describe('marine.routes RBAC metadata', () => {
  const marineRoutes = routes[0].children;
  const byName = name => marineRoutes.find(route => route.name === name);

  const ADMIN_ONLY_ROUTES = [
    'marine_assistants_inboxes_index',
    'marine_assistants_settings_index',
    'marine_assistants_llm_settings_index',
    'marine_assistants_guardrails_index',
    'marine_assistants_guidelines_index',
  ];

  const UNRESTRICTED_ROUTES = [
    'marine_assistants_responses_index',
    'marine_assistants_documents_index',
    'marine_assistants_scenarios_index',
    'marine_assistants_copilot_index',
    'marine_assistants_playground_index',
  ];

  // Representative account.permissions arrays for each role. Administrators carry
  // 'administrator'; plain agents 'agent'; custom roles their granted permissions
  // plus the 'custom_role' marker — never 'administrator'.
  const ADMIN_PERMS = ['administrator'];
  const AGENT_PERMS = ['agent'];
  const SUPERVISOR_PERMS = ['conversation_manage', 'custom_role'];
  const NON_ADMIN_PERMS = [AGENT_PERMS, SUPERVISOR_PERMS];

  describe('admin-only routes', () => {
    ADMIN_ONLY_ROUTES.forEach(name => {
      it(`${name} is restricted to administrators`, () => {
        const route = byName(name);
        expect(route).toBeDefined();
        expect(route.meta.permissions).toEqual(['administrator']);

        expect(routeIsAccessibleFor(route, ADMIN_PERMS)).toBe(true);
        NON_ADMIN_PERMS.forEach(perms => {
          expect(routeIsAccessibleFor(route, perms)).toBe(false);
        });
      });
    });
  });

  describe('unrestricted Marine routes', () => {
    UNRESTRICTED_ROUTES.forEach(name => {
      it(`${name} stays accessible to agents and administrators`, () => {
        const route = byName(name);
        expect(route).toBeDefined();
        expect(route.meta.permissions).toEqual(['administrator', 'agent']);

        expect(routeIsAccessibleFor(route, ADMIN_PERMS)).toBe(true);
        expect(routeIsAccessibleFor(route, AGENT_PERMS)).toBe(true);
      });
    });
  });
});
