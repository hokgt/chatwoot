<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import MarinePreferencesAPI from 'dashboard/api/marine/preferences';
import { useMarineAssistants } from '../composables/useMarineAssistants';
import MarinePageShell from '../components/MarinePageShell.vue';

const { t } = useI18n();
const { activeAssistant, fetchAssistants } = useMarineAssistants();
const loading = ref(false);
const preferences = ref({
  enabled: true,
  hub: 'local',
  remote_hub: false,
  account_id: null,
  default_model: null,
  models: {},
  features: {},
});

const yesNo = value =>
  value ? t('MARINE_AI.SETTINGS.ENABLED') : t('MARINE_AI.SETTINGS.DISABLED');

const statusRows = computed(() => {
  const features = preferences.value.features || {};
  return [
    {
      key: 'status',
      label: t('MARINE_AI.SETTINGS.STATUS'),
      value: yesNo(preferences.value.enabled),
    },
    {
      key: 'hub',
      label: t('MARINE_AI.SETTINGS.HUB'),
      value: t('MARINE_AI.SETTINGS.HUB_LOCAL'),
    },
    {
      key: 'account',
      label: t('MARINE_AI.SETTINGS.ACCOUNT'),
      value: preferences.value.account_id ?? t('MARINE_AI.SETTINGS.NONE'),
    },
    {
      key: 'model',
      label: t('MARINE_AI.SETTINGS.DEFAULT_MODEL'),
      value: preferences.value.default_model || t('MARINE_AI.SETTINGS.NONE'),
    },
    {
      key: 'assistant',
      label: t('MARINE_AI.SETTINGS.FEATURE_ASSISTANT'),
      value: yesNo(features.assistant),
    },
    {
      key: 'knowledge_base',
      label: t('MARINE_AI.SETTINGS.FEATURE_KNOWLEDGE_BASE'),
      value: yesNo(features.knowledge_base),
    },
    {
      key: 'handoff',
      label: t('MARINE_AI.SETTINGS.FEATURE_HANDOFF'),
      value: yesNo(features.handoff),
    },
  ];
});

const fetchSettings = async () => {
  loading.value = true;
  try {
    await fetchAssistants();
    const { data } = await MarinePreferencesAPI.get();
    if (data) {
      preferences.value = { ...preferences.value, ...data };
    }
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
          {{ t('MARINE_AI.SETTINGS.STATUS_TITLE') }}
        </h2>
        <p class="mt-1 text-sm text-n-slate-11">
          {{ t('MARINE_AI.SETTINGS.STATUS_HINT') }}
        </p>
        <dl class="mt-3 grid gap-2 text-sm sm:grid-cols-2">
          <div
            v-for="row in statusRows"
            :key="row.key"
            class="flex items-center justify-between gap-3 rounded-lg border border-n-weak px-3 py-2"
          >
            <dt class="text-n-slate-11">{{ row.label }}</dt>
            <dd class="font-medium text-n-slate-12">{{ row.value }}</dd>
          </div>
        </dl>
      </section>

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
    </div>
  </MarinePageShell>
</template>
