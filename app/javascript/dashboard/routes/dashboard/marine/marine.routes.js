import { frontendURL } from '../../../helper/URLHelper';
import MarineRouteView from './Index.vue';
import MarineNavigationPage from './pages/AssistantsIndexPage.vue';
import MarineAssistantsIndex from './responses/Index.vue';
import MarineDocumentsIndex from './documents/Index.vue';
import MarineScenariosIndex from './scenarios/Index.vue';
import MarineCopilotIndex from './copilot/Index.vue';
import MarinePlaygroundIndex from './playground/Index.vue';
import MarineInboxesIndex from './inboxes/Index.vue';
import MarineToolsIndex from './tools/Index.vue';
import MarineSettingsIndex from './settings/Index.vue';
import MarineLLMSettingsIndex from './llm-settings/Index.vue';
import MarineGuardrailsIndex from './guardrails/Index.vue';
import MarineGuidelinesIndex from './guidelines/Index.vue';

const meta = {
  permissions: ['administrator', 'agent'],
};

const assistantRoutes = [
  {
    path: frontendURL('accounts/:accountId/marine/:assistantId/faqs'),
    component: MarineAssistantsIndex,
    name: 'marine_assistants_responses_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/marine/:assistantId/faqs/pending'),
    component: MarineAssistantsIndex,
    name: 'marine_assistants_responses_pending_index',
    meta: { ...meta, defaultStatus: 'pending' },
  },
  {
    path: frontendURL('accounts/:accountId/marine/:assistantId/documents'),
    component: MarineDocumentsIndex,
    name: 'marine_assistants_documents_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/marine/:assistantId/scenarios'),
    component: MarineScenariosIndex,
    name: 'marine_assistants_scenarios_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/marine/:assistantId/copilot'),
    component: MarineCopilotIndex,
    name: 'marine_assistants_copilot_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/marine/:assistantId/playground'),
    component: MarinePlaygroundIndex,
    name: 'marine_assistants_playground_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/marine/:assistantId/inboxes'),
    component: MarineInboxesIndex,
    name: 'marine_assistants_inboxes_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/marine/:assistantId/tools'),
    component: MarineToolsIndex,
    name: 'marine_tools_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/marine/:assistantId/settings'),
    component: MarineSettingsIndex,
    name: 'marine_assistants_settings_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/marine/:assistantId/llm-settings'),
    component: MarineLLMSettingsIndex,
    name: 'marine_assistants_llm_settings_index',
    meta,
  },
  {
    path: frontendURL(
      'accounts/:accountId/marine/:assistantId/settings/guardrails'
    ),
    component: MarineGuardrailsIndex,
    name: 'marine_assistants_guardrails_index',
    meta,
  },
  {
    path: frontendURL(
      'accounts/:accountId/marine/:assistantId/settings/guidelines'
    ),
    component: MarineGuidelinesIndex,
    name: 'marine_assistants_guidelines_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/marine/assistants'),
    component: MarineNavigationPage,
    name: 'marine_assistants_create_index',
    meta,
  },
  {
    path: frontendURL('accounts/:accountId/marine/:navigationPath'),
    component: MarineNavigationPage,
    name: 'marine_assistants_index',
    meta,
  },
];

export const routes = [
  {
    path: frontendURL('accounts/:accountId/marine'),
    component: MarineRouteView,
    redirect: to => ({
      name: 'marine_assistants_index',
      params: {
        navigationPath: 'marine_assistants_responses_index',
        ...to.params,
      },
    }),
    children: [...assistantRoutes],
  },
];
