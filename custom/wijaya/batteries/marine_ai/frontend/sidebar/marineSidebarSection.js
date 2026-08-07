/**
 * Marine AI primary sidebar section (Wijaya battery-owned).
 *
 * The native dashboard sidebar (app/javascript/dashboard/components-next/sidebar/Sidebar.vue)
 * contributes this whole section through a single marker-wrapped call:
 *
 *   buildMarineSidebarSection({ t, accountScopedRoute })
 *
 * All Marine menu structure/labels/routes live here so the native file carries only the
 * thin delegation. `t` (vue-i18n translate) and `accountScopedRoute` are injected by the
 * caller so this module stays free of any framework wiring.
 */
export function buildMarineSidebarSection({ t, accountScopedRoute }) {
  const marineRoute = navigationPath =>
    accountScopedRoute('marine_assistants_index', { navigationPath });

  return {
    name: 'Marine',
    icon: 'i-lucide-ship-wheel',
    label: t('MARINE_AI.SIDEBAR.MARINE_AI'),
    activeOn: ['marine_assistants_create_index'],
    children: [
      {
        name: 'FAQs',
        label: t('MARINE_AI.SIDEBAR.RESPONSES'),
        activeOn: [
          'marine_assistants_responses_index',
          'marine_assistants_responses_pending',
        ],
        to: marineRoute('marine_assistants_responses_index'),
      },
      {
        name: 'Documents',
        label: t('MARINE_AI.SIDEBAR.DOCUMENTS'),
        activeOn: ['marine_assistants_documents_index'],
        to: marineRoute('marine_assistants_documents_index'),
      },
      {
        name: 'Scenarios',
        label: t('MARINE_AI.SIDEBAR.SCENARIOS'),
        activeOn: ['marine_assistants_scenarios_index'],
        to: marineRoute('marine_assistants_scenarios_index'),
      },
      {
        name: 'Copilot',
        label: t('MARINE_AI.SIDEBAR.COPILOT'),
        activeOn: ['marine_assistants_copilot_index'],
        to: marineRoute('marine_assistants_copilot_index'),
      },
      {
        name: 'Playground',
        label: t('MARINE_AI.SIDEBAR.PLAYGROUND'),
        activeOn: ['marine_assistants_playground_index'],
        to: marineRoute('marine_assistants_playground_index'),
      },
      {
        name: 'Inboxes',
        label: t('MARINE_AI.SIDEBAR.INBOXES'),
        activeOn: ['marine_assistants_inboxes_index'],
        to: marineRoute('marine_assistants_inboxes_index'),
      },
      {
        name: 'LLM Settings',
        label: t('MARINE_AI.SIDEBAR.LLM_SETTINGS'),
        activeOn: ['marine_assistants_llm_settings_index'],
        to: marineRoute('marine_assistants_llm_settings_index'),
      },
      {
        name: 'Settings',
        label: t('MARINE_AI.SIDEBAR.SETTINGS'),
        activeOn: [
          'marine_assistants_settings_index',
          'marine_assistants_guidelines_index',
          'marine_assistants_guardrails_index',
        ],
        to: marineRoute('marine_assistants_settings_index'),
      },
    ],
  };
}

export default buildMarineSidebarSection;
