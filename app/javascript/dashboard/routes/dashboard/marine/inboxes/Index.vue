<script setup>
import { onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import MarineInboxesAPI from 'dashboard/api/marine/inboxes';
import { useMarineAssistants } from '../composables/useMarineAssistants';
import MarinePageShell from '../components/MarinePageShell.vue';

const { t } = useI18n();
const { activeAssistantId, fetchAssistants } = useMarineAssistants();
const loading = ref(false);
const inboxes = ref([]);

const fetchInboxes = async () => {
  loading.value = true;
  try {
    await fetchAssistants();
    if (!activeAssistantId.value) {
      inboxes.value = [];
      return;
    }
    const { data } = await MarineInboxesAPI.get({
      assistantId: activeAssistantId.value,
    });
    inboxes.value = data.payload || [];
  } finally {
    loading.value = false;
  }
};

onMounted(fetchInboxes);
</script>

<template>
  <MarinePageShell
    :title="t('MARINE_AI.INBOXES.TITLE')"
    :description="t('MARINE_AI.INBOXES.DESCRIPTION')"
  >
    <div class="rounded-xl border border-n-weak bg-n-solid-1 p-4">
      <p v-if="loading" class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.INBOXES.LOADING') }}
      </p>
      <p v-else-if="inboxes.length === 0" class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.INBOXES.EMPTY') }}
      </p>
      <ul v-else class="space-y-2">
        <li
          v-for="inbox in inboxes"
          :key="inbox.id"
          class="rounded-lg border border-n-weak p-3 font-medium text-n-slate-12"
        >
          {{ inbox.name }}
        </li>
      </ul>
    </div>
  </MarinePageShell>
</template>
