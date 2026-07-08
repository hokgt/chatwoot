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

  return {
    assistants,
    loadingAssistants,
    activeAssistant,
    activeAssistantId,
    fetchAssistants,
  };
}
