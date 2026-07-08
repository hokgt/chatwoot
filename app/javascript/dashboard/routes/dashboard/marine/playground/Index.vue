<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import MarineAssistantAPI from 'dashboard/api/marine/assistant';
import { useMarineAssistants } from '../composables/useMarineAssistants';
import MarinePageShell from '../components/MarinePageShell.vue';

const { t } = useI18n();
const { activeAssistant, activeAssistantId, fetchAssistants } =
  useMarineAssistants();
const message = ref('');
const result = ref(null);
const sending = ref(false);

const isHandoff = computed(() => result.value?.action === 'handoff');
const replyText = computed(() =>
  isHandoff.value ? '' : result.value?.response || ''
);

onMounted(fetchAssistants);

const sendMessage = async () => {
  if (!message.value.trim() || !activeAssistantId.value) return;
  sending.value = true;
  try {
    const { data } = await MarineAssistantAPI.playground({
      assistantId: activeAssistantId.value,
      messageContent: message.value,
    });
    result.value = data || null;
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
        <p v-if="!result" class="text-sm text-n-slate-11">
          {{ t('MARINE_AI.PLAYGROUND.EMPTY') }}
        </p>
        <div
          v-else-if="isHandoff"
          class="mt-2 rounded-lg border border-n-amber-6 bg-n-amber-3 p-3"
        >
          <p class="text-sm font-medium text-n-amber-11">
            {{ t('MARINE_AI.PLAYGROUND.HANDOFF') }}
          </p>
          <p class="mt-1 text-xs text-n-amber-11">
            {{ t('MARINE_AI.PLAYGROUND.HANDOFF_HINT') }}
          </p>
          <p v-if="result.action_reason" class="mt-1 text-xs text-n-slate-11">
            {{
              t('MARINE_AI.PLAYGROUND.HANDOFF_REASON', {
                reason: result.action_reason,
              })
            }}
          </p>
        </div>
        <div v-else class="mt-2 space-y-1">
          <p
            v-if="result.agent_name"
            class="text-xs font-medium text-n-slate-11"
          >
            {{ result.agent_name }}
          </p>
          <p class="whitespace-pre-wrap text-sm text-n-slate-12">
            {{ replyText }}
          </p>
        </div>
      </div>
    </div>
  </MarinePageShell>
</template>
