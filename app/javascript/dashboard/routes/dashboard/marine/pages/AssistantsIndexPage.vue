<script setup>
import { computed } from 'vue';
import { useRoute } from 'vue-router';

import ResponsesIndex from '../responses/Index.vue';
import DocumentsIndex from '../documents/Index.vue';
import ScenariosIndex from '../scenarios/Index.vue';
import PlaygroundIndex from '../playground/Index.vue';
import InboxesIndex from '../inboxes/Index.vue';
import ToolsIndex from '../tools/Index.vue';
import SettingsIndex from '../settings/Index.vue';

const route = useRoute();

const sectionComponents = {
  marine_assistants_responses_index: ResponsesIndex,
  marine_assistants_responses_pending: ResponsesIndex,
  marine_assistants_documents_index: DocumentsIndex,
  marine_assistants_scenarios_index: ScenariosIndex,
  marine_assistants_playground_index: PlaygroundIndex,
  marine_assistants_inboxes_index: InboxesIndex,
  marine_tools_index: ToolsIndex,
  marine_assistants_settings_index: SettingsIndex,
  marine_assistants_guidelines_index: SettingsIndex,
  marine_assistants_guardrails_index: SettingsIndex,
};

const activeComponent = computed(() => {
  return (
    sectionComponents[route.params.navigationPath] ||
    sectionComponents.marine_assistants_responses_index
  );
});
</script>

<template>
  <component :is="activeComponent" />
</template>
