<script setup>
// Marine AI feature wrapper. Mirrors Captain's page route view: renders the
// active Marine section (FAQs, Knowledge Base, Scenarios, Playground, Inboxes,
// Tools, Settings) inside a full-height shell.
import { watch } from 'vue';
import { useRoute } from 'vue-router';
import { useUISettings } from 'dashboard/composables/useUISettings';

const route = useRoute();
const { uiSettings, updateUISettings } = useUISettings();

watch(
  () => route.params.assistantId,
  newAssistantId => {
    if (
      newAssistantId &&
      newAssistantId !==
        String(uiSettings.value.marine_last_active_assistant_id)
    ) {
      updateUISettings({
        marine_last_active_assistant_id: Number(newAssistantId),
      });
    }
  }
);
</script>

<template>
  <div class="flex w-full h-full min-h-0">
    <section class="flex flex-1 h-full px-0 overflow-hidden bg-n-surface-1">
      <router-view />
    </section>
  </div>
</template>
