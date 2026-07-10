<script setup>
import { ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import MarineMessageList from './MarineMessageList.vue';
import MarineAssistantAPI from 'dashboard/api/marine/assistant';

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

const resetConversation = () => {
  messages.value = [];
  newMessage.value = '';
};

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
      assistantId,
      messageContent: currentMessage,
    });

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
        timestamp: new Date().toISOString(),
      });
    }
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error('Error getting assistant response:', error);
  } finally {
    isLoading.value = false;
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
