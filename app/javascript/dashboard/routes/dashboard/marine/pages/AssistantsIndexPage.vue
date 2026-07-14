<script setup>
import { nextTick, onMounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useUISettings } from 'dashboard/composables/useUISettings';

import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import { useMarineAssistants } from '../composables/useMarineAssistants';

const router = useRouter();
const route = useRoute();
const { uiSettings } = useUISettings();

const { assistants, fetchAssistants } = useMarineAssistants();

const isAssistantPresent = assistantId => {
  return !!assistants.value.find(a => a.id === Number(assistantId));
};

const routeToView = (name, params) => {
  router.replace({ name, params, replace: true });
};

const generateRouterParams = () => {
  const { marine_last_active_assistant_id: lastActiveAssistantId } =
    uiSettings.value || {};

  if (isAssistantPresent(lastActiveAssistantId)) {
    return {
      assistantId: lastActiveAssistantId,
    };
  }

  if (assistants.value.length > 0) {
    const { id: assistantId } = assistants.value[0];
    return { assistantId };
  }

  return null;
};

const routeToLastActiveAssistant = () => {
  const params = generateRouterParams();

  // No assistants found, redirect to create page
  if (!params) {
    return routeToView('marine_assistants_create_index', {
      accountId: route.params.accountId,
    });
  }

  const { navigationPath } = route.params;
  const isAValidRoute = [
    'marine_assistants_responses_index',
    'marine_assistants_documents_index',
    'marine_assistants_scenarios_index',
    'marine_assistants_copilot_index',
    'marine_assistants_playground_index',
    'marine_assistants_inboxes_index',
    'marine_tools_index',
    'marine_assistants_settings_index',
    'marine_assistants_llm_settings_index',
  ].includes(navigationPath);

  const navigateTo = isAValidRoute
    ? navigationPath
    : 'marine_assistants_responses_index';

  return routeToView(navigateTo, {
    accountId: route.params.accountId,
    ...params,
  });
};

const performRouting = async () => {
  await fetchAssistants();
  nextTick(() => routeToLastActiveAssistant());
};

onMounted(() => performRouting());
</script>

<template>
  <div
    class="flex items-center justify-center w-full bg-n-surface-1 text-n-slate-11"
  >
    <Spinner />
  </div>
</template>
