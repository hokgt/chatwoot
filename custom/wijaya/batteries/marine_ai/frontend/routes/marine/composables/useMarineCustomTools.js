import { ref, computed } from 'vue';

// Marine custom tools have been removed to eliminate all direct outbound
// connectivity between Marine AI and ERP. This composable is kept as a no-op
// stub so any remaining importers resolve without error.
export function useMarineCustomTools() {
  const tools = ref([]);
  const meta = ref({ totalCount: 0, page: 1 });
  const uiFlags = ref({
    fetchingList: false,
    creatingItem: false,
    updatingItem: false,
    deletingItem: false,
  });

  const isFetching = computed(() => false);

  const fetchTools = async () => tools.value;
  const createTool = async () => null;
  const updateTool = async () => null;
  const deleteTool = async id => id;

  return {
    tools,
    meta,
    uiFlags,
    isFetching,
    fetchTools,
    createTool,
    updateTool,
    deleteTool,
  };
}
