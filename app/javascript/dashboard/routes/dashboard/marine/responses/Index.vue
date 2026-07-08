<script setup>
import { onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import MarineResponseAPI from 'dashboard/api/marine/response';
import { useMarineAssistants } from '../composables/useMarineAssistants';
import MarinePageShell from '../components/MarinePageShell.vue';

const { t } = useI18n();
const { activeAssistantId, fetchAssistants, createDefaultAssistant } =
  useMarineAssistants();
const loading = ref(false);
const saving = ref(false);
const responses = ref([]);
const form = reactive({ question: '', answer: '' });

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

const setupAssistant = async () => {
  saving.value = true;
  try {
    await createDefaultAssistant();
    await fetchResponses();
  } finally {
    saving.value = false;
  }
};

const createResponse = async () => {
  if (
    !activeAssistantId.value ||
    !form.question.trim() ||
    !form.answer.trim()
  ) {
    return;
  }
  saving.value = true;
  try {
    await MarineResponseAPI.create({
      assistantId: activeAssistantId.value,
      question: form.question,
      answer: form.answer,
    });
    form.question = '';
    form.answer = '';
    await fetchResponses();
  } finally {
    saving.value = false;
  }
};

onMounted(fetchResponses);
</script>

<template>
  <MarinePageShell
    :title="t('MARINE_AI.FAQS.TITLE')"
    :description="t('MARINE_AI.FAQS.DESCRIPTION')"
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
        @submit.prevent="createResponse"
      >
        <h2 class="text-base font-medium text-n-slate-12">
          {{ t('MARINE_AI.FAQS.ADD') }}
        </h2>
        <input
          v-model="form.question"
          class="w-full rounded-lg border border-n-weak bg-n-alpha-black1 p-3 text-sm text-n-slate-12"
          :placeholder="t('MARINE_AI.FAQS.QUESTION')"
        />
        <textarea
          v-model="form.answer"
          rows="4"
          class="w-full rounded-lg border border-n-weak bg-n-alpha-black1 p-3 text-sm text-n-slate-12"
          :placeholder="t('MARINE_AI.FAQS.ANSWER')"
        />
        <button
          type="submit"
          class="rounded-lg bg-n-brand px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
          :disabled="saving || !form.question.trim() || !form.answer.trim()"
        >
          {{ saving ? t('MARINE_AI.SAVING') : t('MARINE_AI.FAQS.SAVE') }}
        </button>
      </form>

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
    </div>
  </MarinePageShell>
</template>
