<script setup>
import { onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import MarinePreferencesAPI from 'dashboard/api/marine/preferences';
import { useMarineAssistants } from '../composables/useMarineAssistants';
import MarinePageShell from '../components/MarinePageShell.vue';

const { t } = useI18n();
const { activeAssistant, fetchAssistants } = useMarineAssistants();
const loading = ref(false);
const preferences = ref({ models: {}, features: {} });

const fetchSettings = async () => {
  loading.value = true;
  try {
    await fetchAssistants();
    const { data } = await MarinePreferencesAPI.get();
    preferences.value = data || { models: {}, features: {} };
  } finally {
    loading.value = false;
  }
};

onMounted(fetchSettings);
</script>

<template>
  <MarinePageShell
    :title="t('MARINE_AI.SETTINGS.TITLE')"
    :description="t('MARINE_AI.SETTINGS.DESCRIPTION')"
  >
    <div
      v-if="loading"
      class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
    >
      <p class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.SETTINGS.LOADING') }}
      </p>
    </div>
    <div v-else class="grid gap-4">
      <section class="rounded-xl border border-n-weak bg-n-solid-1 p-4">
        <h2 class="text-base font-medium text-n-slate-12">
          {{ t('MARINE_AI.SETTINGS.ASSISTANT') }}
        </h2>
        <dl class="mt-3 grid gap-2 text-sm">
          <div class="grid gap-1">
            <dt class="text-n-slate-11">
              {{ t('MARINE_AI.DASHBOARD.ASSISTANTS') }}
            </dt>
            <dd class="text-n-slate-12">
              {{ activeAssistant?.name || t('MARINE_AI.SETTINGS.NONE') }}
            </dd>
          </div>
          <div class="grid gap-1">
            <dt class="text-n-slate-11">
              {{ t('MARINE_AI.SETTINGS.INSTRUCTIONS') }}
            </dt>
            <dd class="whitespace-pre-wrap text-n-slate-12">
              {{
                activeAssistant?.config?.instructions ||
                t('MARINE_AI.SETTINGS.NONE')
              }}
            </dd>
          </div>
          <div class="grid gap-1">
            <dt class="text-n-slate-11">
              {{ t('MARINE_AI.SETTINGS.TEMPERATURE') }}
            </dt>
            <dd class="text-n-slate-12">
              {{
                activeAssistant?.config?.temperature ||
                t('MARINE_AI.SETTINGS.NONE')
              }}
            </dd>
          </div>
        </dl>
      </section>

      <section class="rounded-xl border border-n-weak bg-n-solid-1 p-4">
        <h2 class="text-base font-medium text-n-slate-12">
          {{ t('MARINE_AI.SETTINGS.MODELS') }}
        </h2>
        <pre
          class="mt-3 overflow-auto rounded-lg bg-n-alpha-black1 p-3 text-xs text-n-slate-12"
        >
          {{ JSON.stringify(preferences.models || {}, null, 2) }}
        </pre>
      </section>

      <section class="rounded-xl border border-n-weak bg-n-solid-1 p-4">
        <h2 class="text-base font-medium text-n-slate-12">
          {{ t('MARINE_AI.SETTINGS.FEATURES') }}
        </h2>
        <pre
          class="mt-3 overflow-auto rounded-lg bg-n-alpha-black1 p-3 text-xs text-n-slate-12"
        >
          {{ JSON.stringify(preferences.features || {}, null, 2) }}
        </pre>
      </section>
    </div>
  </MarinePageShell>
</template>
