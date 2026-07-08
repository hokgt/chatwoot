<script setup>
import { onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import MarineDocumentAPI from 'dashboard/api/marine/document';
import { useMarineAssistants } from '../composables/useMarineAssistants';
import MarinePageShell from '../components/MarinePageShell.vue';

const { t } = useI18n();
const { activeAssistantId, fetchAssistants } = useMarineAssistants();
const loading = ref(false);
const documents = ref([]);

const fetchDocuments = async () => {
  loading.value = true;
  try {
    await fetchAssistants();
    if (!activeAssistantId.value) {
      documents.value = [];
      return;
    }
    const { data } = await MarineDocumentAPI.get({
      assistantId: activeAssistantId.value,
    });
    documents.value = data.payload || [];
  } finally {
    loading.value = false;
  }
};

onMounted(fetchDocuments);
</script>

<template>
  <MarinePageShell
    :title="t('MARINE_AI.DOCUMENTS.TITLE')"
    :description="t('MARINE_AI.DOCUMENTS.DESCRIPTION')"
  >
    <div class="rounded-xl border border-n-weak bg-n-solid-1 p-4">
      <p v-if="loading" class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.DOCUMENTS.LOADING') }}
      </p>
      <p v-else-if="documents.length === 0" class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.DOCUMENTS.EMPTY') }}
      </p>
      <ul v-else class="space-y-2">
        <li
          v-for="document in documents"
          :key="document.id"
          class="rounded-lg border border-n-weak p-3"
        >
          <div class="font-medium text-n-slate-12">
            {{ document.name }}
          </div>
          <a
            v-if="document.external_link"
            :href="document.external_link"
            target="_blank"
            rel="noopener noreferrer"
            class="text-sm text-n-blue-11 break-all"
          >
            {{ document.external_link }}
          </a>
        </li>
      </ul>
    </div>
  </MarinePageShell>
</template>
