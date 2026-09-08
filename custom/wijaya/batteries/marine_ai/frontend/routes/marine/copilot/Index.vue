<script setup>
import { onMounted, ref, nextTick } from 'vue';
import { useI18n } from 'vue-i18n';
import MarineCopilotThreadsAPI from '@wijaya/marine_ai/frontend/api/copilotThreads';
import MarineCopilotMessagesAPI from '@wijaya/marine_ai/frontend/api/copilotMessages';
import { useMarineAssistants } from '../composables/useMarineAssistants';
import MarinePageShell from '../components/MarinePageShell.vue';

const { t } = useI18n();
const { activeAssistantId, fetchAssistants, createDefaultAssistant } =
  useMarineAssistants();

const loading = ref(false);
const sending = ref(false);
const savingAssistant = ref(false);
const threads = ref([]);
const activeThread = ref(null);
const messages = ref([]);
const question = ref('');
const messagesEnd = ref(null);

const scrollToBottom = async () => {
  await nextTick();
  messagesEnd.value?.scrollIntoView({ behavior: 'smooth' });
};

const fetchThreads = async () => {
  if (!activeAssistantId.value) {
    threads.value = [];
    return;
  }
  const { data } = await MarineCopilotThreadsAPI.get({
    assistantId: activeAssistantId.value,
  });
  threads.value = data.payload || [];
};

const openThread = async thread => {
  activeThread.value = thread;
  const { data } = await MarineCopilotThreadsAPI.show({
    assistantId: activeAssistantId.value,
    id: thread.id,
  });
  messages.value = data.messages || [];
  scrollToBottom();
};

const startNewThread = () => {
  activeThread.value = null;
  messages.value = [];
};

const initialize = async () => {
  loading.value = true;
  try {
    await fetchAssistants();
    await fetchThreads();
  } finally {
    loading.value = false;
  }
};

const setupAssistant = async () => {
  savingAssistant.value = true;
  try {
    await createDefaultAssistant();
    await fetchThreads();
  } finally {
    savingAssistant.value = false;
  }
};

const sendQuestion = async () => {
  const text = question.value.trim();
  if (!text || !activeAssistantId.value || sending.value) return;
  sending.value = true;
  try {
    if (activeThread.value) {
      const { data } = await MarineCopilotMessagesAPI.create({
        assistantId: activeAssistantId.value,
        threadId: activeThread.value.id,
        message: text,
      });
      messages.value = data.payload || [];
    } else {
      const { data } = await MarineCopilotThreadsAPI.create({
        assistantId: activeAssistantId.value,
        message: text,
      });
      activeThread.value = data;
      messages.value = data.messages || [];
      await fetchThreads();
    }
    question.value = '';
    scrollToBottom();
  } finally {
    sending.value = false;
  }
};

onMounted(initialize);
</script>

<template>
  <MarinePageShell
    :title="t('MARINE_AI.COPILOT.TITLE')"
    :description="t('MARINE_AI.COPILOT.DESCRIPTION')"
  >
    <div
      v-if="!activeAssistantId && !loading"
      class="rounded-xl border border-n-weak bg-n-solid-1 p-4 space-y-3"
    >
      <p class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.EMPTY_ASSISTANT.DESCRIPTION') }}
      </p>
      <button
        type="button"
        class="rounded-lg bg-n-brand px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
        :disabled="savingAssistant"
        @click="setupAssistant"
      >
        {{ t('MARINE_AI.EMPTY_ASSISTANT.CREATE') }}
      </button>
    </div>
    <div v-else class="grid grid-cols-1 gap-4 md:grid-cols-[240px_1fr]">
      <aside class="rounded-xl border border-n-weak bg-n-solid-1 p-3 space-y-2">
        <button
          type="button"
          class="w-full rounded-lg bg-n-brand px-3 py-2 text-sm font-medium text-white"
          @click="startNewThread"
        >
          {{ t('MARINE_AI.COPILOT.NEW_THREAD') }}
        </button>
        <p v-if="threads.length === 0" class="text-xs text-n-slate-11 px-1">
          {{ t('MARINE_AI.COPILOT.NO_THREADS') }}
        </p>
        <ul class="space-y-1">
          <li v-for="thread in threads" :key="thread.id">
            <button
              type="button"
              class="w-full truncate rounded-md px-2 py-1.5 text-left text-sm"
              :class="
                activeThread && activeThread.id === thread.id
                  ? 'bg-n-alpha-2 text-n-slate-12'
                  : 'text-n-slate-11 hover:bg-n-alpha-1'
              "
              @click="openThread(thread)"
            >
              {{ thread.title }}
            </button>
          </li>
        </ul>
      </aside>

      <section
        class="flex min-h-[420px] flex-col rounded-xl border border-n-weak bg-n-solid-1"
      >
        <div class="flex-1 space-y-3 overflow-auto p-4">
          <p v-if="messages.length === 0" class="text-sm text-n-slate-11">
            {{ t('MARINE_AI.COPILOT.EMPTY') }}
          </p>
          <div
            v-for="msg in messages"
            :key="msg.id"
            class="rounded-lg p-3"
            :class="
              msg.message_type === 'user'
                ? 'bg-n-alpha-2 text-n-slate-12'
                : 'border border-n-weak text-n-slate-12'
            "
          >
            <p class="whitespace-pre-wrap text-sm">
              {{ msg.message.content }}
            </p>
            <div
              v-if="msg.message.citations && msg.message.citations.length"
              class="mt-2 flex flex-wrap gap-1"
            >
              <a
                v-for="citation in msg.message.citations"
                :key="`${citation.type}-${citation.id}`"
                :href="citation.url"
                class="rounded-full bg-n-teal-3 px-2 py-0.5 text-xs font-medium text-n-teal-11"
              >
                {{
                  citation.type === 'conversation'
                    ? citation.title
                    : citation.name
                }}
              </a>
            </div>
          </div>
          <div ref="messagesEnd" />
        </div>
        <form
          class="flex items-end gap-2 border-t border-n-weak p-3"
          @submit.prevent="sendQuestion"
        >
          <textarea
            v-model="question"
            rows="2"
            class="flex-1 rounded-lg border border-n-weak bg-n-alpha-black1 p-2 text-sm text-n-slate-12"
            :placeholder="t('MARINE_AI.COPILOT.PLACEHOLDER')"
            @keydown.enter.exact.prevent="sendQuestion"
          />
          <button
            type="submit"
            class="rounded-lg bg-n-brand px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
            :disabled="sending || !question.trim()"
          >
            {{
              sending
                ? t('MARINE_AI.COPILOT.SENDING')
                : t('MARINE_AI.COPILOT.SEND')
            }}
          </button>
        </form>
      </section>
    </div>
  </MarinePageShell>
</template>
