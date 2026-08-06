import { ref, computed } from 'vue';
import MarineAssistantAPI from 'dashboard/api/marine/assistant';

// Shared helper for Marine feature pages. Each page needs a Marine assistant
// context to load its sub-resources (FAQs, documents, inboxes, ...). This
// resolves the account's Marine assistants and exposes the first one as the
// active assistant, mirroring how Captain lands on the first assistant.
export function useMarineAssistants() {
  const assistants = ref([]);
  const loadingAssistants = ref(false);

  const activeAssistant = computed(() => assistants.value[0] || null);
  const activeAssistantId = computed(() => activeAssistant.value?.id ?? null);

  const fetchAssistants = async () => {
    loadingAssistants.value = true;
    try {
      const { data } = await MarineAssistantAPI.get();
      assistants.value = data.payload || [];
    } finally {
      loadingAssistants.value = false;
    }
    return assistants.value;
  };

  const createDefaultAssistant = async () => {
    const { data } = await MarineAssistantAPI.create({
      assistant: {
        name: 'Marine Assistant',
        description: 'Wijaya local Marine AI assistant',
        config: {
          instructions:
            'Answer from Marine knowledge base. Hand off to an agent when confidence is low.',
          handoff_message:
            'I will connect you to one of our agents for further assistance.',
          temperature: '0.2',
        },
      },
    });
    await fetchAssistants();
    return data;
  };

  return {
    assistants,
    loadingAssistants,
    activeAssistant,
    activeAssistantId,
    fetchAssistants,
    createDefaultAssistant,
  };
}
