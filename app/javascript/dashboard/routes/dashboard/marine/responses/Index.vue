<script setup>
import { onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import MarineResponseAPI from 'dashboard/api/marine/response';
import { useMarineAssistants } from '../composables/useMarineAssistants';
import MarinePageShell from '../components/MarinePageShell.vue';

const { t } = useI18n();
const { activeAssistantId, fetchAssistants } = useMarineAssistants();
const loading = ref(false);
const responses = ref([]);

const fetchResponses = async () => {
  loading.value = true;
  try {
    await fetchAssistants();
    if (!activeAssistantId.value) {
      responses.value = [];
      return;
    }
    const { data } = await MarineResponseAPI.get({
      assistantId: activeAssistantId.value,
    });
    responses.value = data.payload || [];
  } finally {
    loading.value = false;
  }
};

onMounted(fetchResponses);
</script>

<template>
  <MarinePageShell
    :title="t('MARINE_AI.FAQS.TITLE')"
    :description="t('MARINE_AI.FAQS.DESCRIPTION')"
  >
    <div class="rounded-xl border border-n-weak bg-n-solid-1 p-4">
      <p v-if="loading" class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.FAQS.LOADING') }}
      </p>
      <p v-else-if="responses.length === 0" class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.FAQS.EMPTY') }}
      </p>
      <ul v-else class="space-y-2">
        <li
          v-for="response in responses"
          :key="response.id"
          class="rounded-lg border border-n-weak p-3"
        >
          <div class="font-medium text-n-slate-12">
            {{ response.question }}
          </div>
          <div class="text-sm text-n-slate-11">
            {{ response.answer }}
          </div>
        </li>
      </ul>
    </div>
  </MarinePageShell>
</template>
