<script setup>
import { ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import MarineMessageList from './MarineMessageList.vue';
import MarineAssistantAPI from '@wijaya/marine_ai/frontend/api/assistant';

const { assistantId } = defineProps({
  assistantId: {
    type: Number,
    required: true,
  },
});

const { t } = useI18n();
const messages = ref([]);
const newMessage = ref('');
const isLoading = ref(false);

// Opaque signed ephemeral product-flow state for the source-less preview. It lives ONLY in this
// browser-memory ref — never persisted — and is echoed on each request so the preview is
// deterministically multi-turn. It is cleared on reset/assistant switch, and only ever updated by a
// response that still owns the current generation, so a late/stale result cannot repopulate it.
const stateToken = ref(null);

// Bounded prior turns sent with each request so the preview is multi-turn; the backend also
// re-bounds/allowlists this payload. Mirrors the server-side playground history cap.
const MAX_HISTORY_TURNS = 10;

// Monotonic generation token that owns the current transcript/loading state. Every send bumps it
// and captures its value; reset (manual or on assistant switch) bumps it too, invalidating any
// in-flight request so a late success/error/finally cannot mutate the fresh state. Comparing
// generation — not just assistantId — also catches a same-assistant reset and prevents two
// same-assistant requests from overlapping.
let requestGeneration = 0;

const resetConversation = () => {
  requestGeneration += 1;
  messages.value = [];
  newMessage.value = '';
  isLoading.value = false;
  stateToken.value = null;
};

const buildMessageHistory = () =>
  messages.value
    .filter(
      m =>
        (m.sender === 'user' || m.sender === 'assistant') &&
        m.content &&
        !m.handoff &&
        !m.error
    )
    .slice(-MAX_HISTORY_TURNS)
    .map(m => ({ role: m.sender, content: m.content }));

// Watch for assistant ID changes and reset conversation
watch(
  () => assistantId,
  (newId, oldId) => {
    if (oldId && newId !== oldId) {
      resetConversation();
    }
  }
);

const sendMessage = async () => {
  if (!newMessage.value.trim() || isLoading.value) return;

  // Snapshot prior turns before appending the new one, and take ownership of the current
  // generation. A late response is discarded whenever its generation is no longer current —
  // this covers an assistant switch (the watcher resets) and a same-assistant manual reset, and
  // prevents two same-assistant requests from overlapping.
  const messageHistory = buildMessageHistory();
  const requestedAssistantId = assistantId;
  requestGeneration += 1;
  const generation = requestGeneration;

  const userMessage = {
    content: newMessage.value,
    sender: 'user',
    timestamp: new Date().toISOString(),
  };
  messages.value.push(userMessage);
  const currentMessage = newMessage.value;
  newMessage.value = '';

  try {
    isLoading.value = true;
    const { data } = await MarineAssistantAPI.playground({
      assistantId: requestedAssistantId,
      messageContent: currentMessage,
      messageHistory,
      stateToken: stateToken.value,
    });

    if (generation !== requestGeneration) return;

    // Only a response that still owns the current generation may advance the ephemeral state token,
    // so a late/stale result cannot repopulate state after a reset or assistant switch.
    stateToken.value = data.state_token ?? null;

    if (data.action === 'handoff') {
      messages.value.push({
        content: '',
        sender: 'assistant',
        handoff: true,
        actionReason: data.action_reason,
        agentName: data.agent_name,
        timestamp: new Date().toISOString(),
      });
    } else {
      messages.value.push({
        content: data.response,
        sender: 'assistant',
        agentName: data.agent_name,
        catalogPreview: data.catalog_preview ?? null,
        timestamp: new Date().toISOString(),
      });
    }
  } catch (error) {
    if (generation !== requestGeneration) return;
    messages.value.push({
      content: '',
      sender: 'assistant',
      error: true,
      timestamp: new Date().toISOString(),
    });
  } finally {
    if (generation === requestGeneration) isLoading.value = false;
  }
};

const handleEnterKey = event => {
  if (event.isComposing) return;
  event.preventDefault();
  sendMessage();
};
</script>

<template>
  <div
    class="flex flex-col h-full rounded-xl border py-6 border-n-weak text-n-slate-11"
  >
    <div class="mb-8 px-6">
      <div class="flex justify-between items-center mb-1">
        <h3 class="text-lg font-medium">
          {{ t('MARINE_AI.PLAYGROUND.HEADER') }}
        </h3>
        <Button
          ghost
          sm
          slate
          icon="i-lucide-rotate-ccw"
          @click="resetConversation"
        />
      </div>
      <p class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.PLAYGROUND.DESCRIPTION') }}
      </p>
    </div>

    <MarineMessageList :messages="messages" :is-loading="isLoading" />

    <div
      class="flex items-center mx-6 bg-n-background outline outline-1 outline-n-weak rounded-xl p-3"
    >
      <input
        v-model="newMessage"
        class="flex-1 bg-transparent border-none focus:outline-none text-sm mb-0 text-n-slate-12 placeholder:text-n-slate-10"
        :placeholder="t('MARINE_AI.PLAYGROUND.MESSAGE_PLACEHOLDER')"
        @keydown.enter.exact="handleEnterKey"
      />
      <Button
        ghost
        sm
        :disabled="!newMessage.trim()"
        icon="i-lucide-send"
        @click="sendMessage"
      />
    </div>
  </div>
</template>
