<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import InboxesAPI from 'dashboard/api/inboxes';
import MarineInboxesAPI from 'dashboard/api/marine/inboxes';
import { useMarineAssistants } from '../composables/useMarineAssistants';
import MarinePageShell from '../components/MarinePageShell.vue';

const { t } = useI18n();
const { activeAssistantId, fetchAssistants, createDefaultAssistant } =
  useMarineAssistants();
const loading = ref(false);
const saving = ref(false);
const inboxes = ref([]);
const allInboxes = ref([]);
const selectedInboxId = ref('');

const connectedIds = computed(() => inboxes.value.map(inbox => inbox.id));
const availableInboxes = computed(() =>
  allInboxes.value.filter(inbox => !connectedIds.value.includes(inbox.id))
);

const fetchInboxes = async () => {
  loading.value = true;
  try {
    await fetchAssistants();
    const { data: allData } = await InboxesAPI.get();
    allInboxes.value = allData.payload || [];
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

const setupAssistant = async () => {
  saving.value = true;
  try {
    await createDefaultAssistant();
    await fetchInboxes();
  } finally {
    saving.value = false;
  }
};

const connectInbox = async () => {
  if (!activeAssistantId.value || !selectedInboxId.value) return;
  saving.value = true;
  try {
    await MarineInboxesAPI.create({
      assistantId: activeAssistantId.value,
      inboxId: selectedInboxId.value,
    });
    selectedInboxId.value = '';
    await fetchInboxes();
  } finally {
    saving.value = false;
  }
};

const disconnectInbox = async inbox => {
  if (!activeAssistantId.value) return;
  saving.value = true;
  try {
    await MarineInboxesAPI.delete({
      assistantId: activeAssistantId.value,
      inboxId: inbox.id,
    });
    await fetchInboxes();
  } finally {
    saving.value = false;
  }
};

onMounted(fetchInboxes);
</script>

<template>
  <MarinePageShell
    :title="t('MARINE_AI.INBOXES.TITLE')"
    :description="t('MARINE_AI.INBOXES.DESCRIPTION')"
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
        class="rounded-xl border border-n-weak bg-n-solid-1 p-4 flex flex-col gap-3 sm:flex-row"
        @submit.prevent="connectInbox"
      >
        <select
          v-model="selectedInboxId"
          class="min-w-0 flex-1 rounded-lg border border-n-weak bg-n-alpha-black1 p-3 text-sm text-n-slate-12"
        >
          <option value="">{{ t('MARINE_AI.INBOXES.SELECT') }}</option>
          <option
            v-for="inbox in availableInboxes"
            :key="inbox.id"
            :value="inbox.id"
          >
            {{ inbox.name }}
          </option>
        </select>
        <button
          type="submit"
          class="rounded-lg bg-n-brand px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
          :disabled="saving || !selectedInboxId"
        >
          {{ saving ? t('MARINE_AI.SAVING') : t('MARINE_AI.INBOXES.CONNECT') }}
        </button>
      </form>

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
            class="flex items-center justify-between gap-3 rounded-lg border border-n-weak p-3"
          >
            <span class="font-medium text-n-slate-12">{{ inbox.name }}</span>
            <button
              type="button"
              class="rounded-md border border-n-weak px-2.5 py-1 text-xs font-medium text-n-ruby-11 disabled:opacity-50"
              :disabled="saving"
              @click="disconnectInbox(inbox)"
            >
              {{ t('MARINE_AI.INBOXES.DISCONNECT') }}
            </button>
          </li>
        </ul>
      </div>
    </div>
  </MarinePageShell>
</template>
