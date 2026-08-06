<script setup>
import { computed } from 'vue';
import { useRoute } from 'vue-router';
import MarinePageLayout from '../components/MarinePageLayout.vue';
import MarineAssistantPlayground from '../components/MarineAssistantPlayground.vue';

const route = useRoute();
const assistantId = computed(() => Number(route.params.assistantId));
</script>

<template>
  <MarinePageLayout
    show-assistant-switcher
    :show-pagination-footer="false"
    :show-know-more="false"
    class="h-full"
  >
    <template #body>
      <div class="flex flex-col h-full">
        <MarineAssistantPlayground
          :assistant-id="assistantId"
          class="bg-n-solid-1"
        />
      </div>
    </template>
  </MarinePageLayout>
</template>
