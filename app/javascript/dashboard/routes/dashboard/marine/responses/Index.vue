<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import MarineResponseAPI from 'dashboard/api/marine/response';
import { useMarineAssistants } from '../composables/useMarineAssistants';
import MarinePageShell from '../components/MarinePageShell.vue';

const { t } = useI18n();
const route = useRoute();
const { activeAssistantId, fetchAssistants, createDefaultAssistant } =
  useMarineAssistants();
const loading = ref(false);
const saving = ref(false);
const responses = ref([]);
const statusFilter = ref(route.meta?.defaultStatus || 'all');
const form = reactive({ question: '', answer: '' });

const statusTabs = ['all', 'pending', 'approved'];

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
      status: statusFilter.value === 'all' ? undefined : statusFilter.value,
    });
    responses.value = data.payload || [];
  } finally {
    loading.value = false;
  }
};

const setStatusFilter = async value => {
  statusFilter.value = value;
  await fetchResponses();
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

const approveResponse = async response => {
  await MarineResponseAPI.approve(response.id);
  await fetchResponses();
};

const deleteResponse = async response => {
  await MarineResponseAPI.delete(response.id);
  await fetchResponses();
};

const statusLabel = status =>
  status === 'pending'
    ? t('MARINE_AI.FAQS.STATUS_PENDING')
    : t('MARINE_AI.FAQS.STATUS_APPROVED');

const statusTabLabel = computed(() => value => {
  if (value === 'pending') return t('MARINE_AI.FAQS.STATUS_PENDING');
  if (value === 'approved') return t('MARINE_AI.FAQS.STATUS_APPROVED');
  return t('MARINE_AI.FAQS.STATUS_ALL');
});

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

      <div class="flex gap-2">
        <button
          v-for="tab in statusTabs"
          :key="tab"
          type="button"
          class="rounded-lg border px-3 py-1.5 text-sm font-medium"
          :class="
            statusFilter === tab
              ? 'border-n-brand bg-n-brand text-white'
              : 'border-n-weak text-n-slate-11'
          "
          @click="setStatusFilter(tab)"
        >
          {{ statusTabLabel(tab) }}
        </button>
      </div>

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
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <div class="font-medium text-n-slate-12">
                  {{ response.question }}
                </div>
                <div class="text-sm text-n-slate-11">
                  {{ response.answer }}
                </div>
              </div>
              <span
                class="shrink-0 rounded-full px-2 py-0.5 text-xs font-medium"
                :class="
                  response.status === 'pending'
                    ? 'bg-n-amber-3 text-n-amber-11'
                    : 'bg-n-teal-3 text-n-teal-11'
                "
              >
                {{ statusLabel(response.status) }}
              </span>
            </div>
            <div class="mt-2 flex gap-2">
              <button
                v-if="response.status === 'pending'"
                type="button"
                class="rounded-md border border-n-weak px-2.5 py-1 text-xs font-medium text-n-teal-11"
                @click="approveResponse(response)"
              >
                {{ t('MARINE_AI.FAQS.APPROVE') }}
              </button>
              <button
                type="button"
                class="rounded-md border border-n-weak px-2.5 py-1 text-xs font-medium text-n-ruby-11"
                @click="deleteResponse(response)"
              >
                {{ t('MARINE_AI.FAQS.DELETE') }}
              </button>
            </div>
          </li>
        </ul>
      </div>
    </div>
  </MarinePageShell>
</template>
