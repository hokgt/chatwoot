<script setup>
import { onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import MarineAssistantAPI from 'dashboard/api/marine/assistant';

const { t } = useI18n();
const loading = ref(false);
const assistants = ref([]);

const fetchAssistants = async () => {
  loading.value = true;
  try {
    const { data } = await MarineAssistantAPI.get();
    assistants.value = data.payload || [];
  } finally {
    loading.value = false;
  }
};

onMounted(fetchAssistants);
</script>

<template>
  <main class="flex-1 p-6 overflow-auto">
    <section class="max-w-5xl mx-auto space-y-4">
      <div>
        <h1 class="text-2xl font-semibold text-n-slate-12">
          {{ t('MARINE_AI.DASHBOARD.TITLE') }}
        </h1>
        <p class="text-sm text-n-slate-11">
          {{ t('MARINE_AI.DASHBOARD.DESCRIPTION') }}
        </p>
      </div>
      <div class="rounded-xl border border-n-weak bg-n-solid-1 p-4">
        <h2 class="text-base font-medium text-n-slate-12">
          {{ t('MARINE_AI.DASHBOARD.ASSISTANTS') }}
        </h2>
        <p v-if="loading" class="text-sm text-n-slate-11">
          {{ t('MARINE_AI.DASHBOARD.LOADING') }}
        </p>
        <p v-else-if="assistants.length === 0" class="text-sm text-n-slate-11">
          {{ t('MARINE_AI.DASHBOARD.EMPTY') }}
        </p>
        <ul v-else class="mt-3 space-y-2">
          <li
            v-for="assistant in assistants"
            :key="assistant.id"
            class="rounded-lg border border-n-weak p-3"
          >
            <div class="font-medium text-n-slate-12">{{ assistant.name }}</div>
            <div class="text-sm text-n-slate-11">
              {{ assistant.description }}
            </div>
          </li>
        </ul>
      </div>
    </section>
  </main>
</template>
