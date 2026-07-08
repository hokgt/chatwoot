<script setup>
import { onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import MarineAssistantAPI from 'dashboard/api/marine/assistant';
import { useMarineAssistants } from '../composables/useMarineAssistants';
import MarinePageShell from '../components/MarinePageShell.vue';

const { t } = useI18n();
const { activeAssistant, activeAssistantId, fetchAssistants } =
  useMarineAssistants();
const message = ref('');
const response = ref('');
const sending = ref(false);

onMounted(fetchAssistants);

const sendMessage = async () => {
  if (!message.value.trim() || !activeAssistantId.value) return;
  sending.value = true;
  try {
    const { data } = await MarineAssistantAPI.playground({
      assistantId: activeAssistantId.value,
      messageContent: message.value,
    });
    response.value = data.response || data.message || '';
  } finally {
    sending.value = false;
  }
};
</script>

<template>
  <MarinePageShell
    :title="t('MARINE_AI.PLAYGROUND.TITLE')"
    :description="t('MARINE_AI.PLAYGROUND.DESCRIPTION')"
  >
    <div
      v-if="!activeAssistant"
      class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
    >
      <p class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.EMPTY_ASSISTANT.DESCRIPTION') }}
      </p>
    </div>
    <div v-else class="space-y-4">
      <div class="rounded-xl border border-n-weak bg-n-solid-1 p-4 space-y-3">
        <textarea
          v-model="message"
          rows="3"
          class="w-full rounded-lg border border-n-weak bg-n-alpha-black1 p-3 text-sm text-n-slate-12"
          :placeholder="t('MARINE_AI.PLAYGROUND.PLACEHOLDER')"
        />
        <button
          type="button"
          class="rounded-lg bg-n-brand px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
          :disabled="sending || !message.trim()"
          @click="sendMessage"
        >
          {{
            sending
              ? t('MARINE_AI.PLAYGROUND.SENDING')
              : t('MARINE_AI.PLAYGROUND.SEND')
          }}
        </button>
      </div>
      <div class="rounded-xl border border-n-weak bg-n-solid-1 p-4">
        <h2 class="text-base font-medium text-n-slate-12">
          {{ t('MARINE_AI.PLAYGROUND.RESPONSE') }}
        </h2>
        <p v-if="!response" class="text-sm text-n-slate-11">
          {{ t('MARINE_AI.PLAYGROUND.EMPTY') }}
        </p>
        <p v-else class="mt-2 whitespace-pre-wrap text-sm text-n-slate-12">
          {{ response }}
        </p>
      </div>
    </div>
  </MarinePageShell>
</template>
