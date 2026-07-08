<script setup>
import { onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import MarineDocumentAPI from 'dashboard/api/marine/document';
import { useMarineAssistants } from '../composables/useMarineAssistants';
import MarinePageShell from '../components/MarinePageShell.vue';

const { t } = useI18n();
const { activeAssistantId, fetchAssistants, createDefaultAssistant } =
  useMarineAssistants();
const loading = ref(false);
const saving = ref(false);
const documents = ref([]);
const form = reactive({ name: '', externalLink: '', content: '' });

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

const setupAssistant = async () => {
  saving.value = true;
  try {
    await createDefaultAssistant();
    await fetchDocuments();
  } finally {
    saving.value = false;
  }
};

const createDocument = async () => {
  if (!activeAssistantId.value || !form.externalLink.trim()) return;
  saving.value = true;
  try {
    await MarineDocumentAPI.create({
      assistantId: activeAssistantId.value,
      name: form.name || form.externalLink,
      externalLink: form.externalLink,
      content: form.content,
    });
    form.name = '';
    form.externalLink = '';
    form.content = '';
    await fetchDocuments();
  } finally {
    saving.value = false;
  }
};

onMounted(fetchDocuments);
</script>

<template>
  <MarinePageShell
    :title="t('MARINE_AI.DOCUMENTS.TITLE')"
    :description="t('MARINE_AI.DOCUMENTS.DESCRIPTION')"
  >
    <div
      v-if="!activeAssistantId"
      class="rounded-xl border border-n-weak bg-n-solid-1 p-4 space-y-3"
    >
      <p class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.EMPTY_ASSISTANT.DESCRIPTION') }}
      </p>
      <button
        type="button"
        class="rounded-lg bg-n-brand px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
        :disabled="saving"
        @click="setupAssistant"
      >
        {{ t('MARINE_AI.EMPTY_ASSISTANT.CREATE') }}
      </button>
    </div>
    <div v-else class="space-y-4">
      <form
        class="rounded-xl border border-n-weak bg-n-solid-1 p-4 space-y-3"
        @submit.prevent="createDocument"
      >
        <h2 class="text-base font-medium text-n-slate-12">
          {{ t('MARINE_AI.DOCUMENTS.ADD') }}
        </h2>
        <input
          v-model="form.name"
          class="w-full rounded-lg border border-n-weak bg-n-alpha-black1 p-3 text-sm text-n-slate-12"
          :placeholder="t('MARINE_AI.DOCUMENTS.NAME')"
        />
        <input
          v-model="form.externalLink"
          class="w-full rounded-lg border border-n-weak bg-n-alpha-black1 p-3 text-sm text-n-slate-12"
          :placeholder="t('MARINE_AI.DOCUMENTS.URL')"
        />
        <textarea
          v-model="form.content"
          rows="5"
          class="w-full rounded-lg border border-n-weak bg-n-alpha-black1 p-3 text-sm text-n-slate-12"
          :placeholder="t('MARINE_AI.DOCUMENTS.CONTENT')"
        />
        <button
          type="submit"
          class="rounded-lg bg-n-brand px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
          :disabled="saving || !form.externalLink.trim()"
        >
          {{ saving ? t('MARINE_AI.SAVING') : t('MARINE_AI.DOCUMENTS.SAVE') }}
        </button>
      </form>

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
    </div>
  </MarinePageShell>
</template>
