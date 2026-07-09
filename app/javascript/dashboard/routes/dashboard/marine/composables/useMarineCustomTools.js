import { ref, computed } from 'vue';
import MarineCustomToolsAPI from 'dashboard/api/marine/customTools';

// State + actions for Marine custom tools. Mirrors the Captain custom tools
// store surface (list/create/update/delete/test) but uses the Marine composable
// pattern instead of Vuex, keeping Marine self-contained and free of any
// premium/feature-flag gate.
export function useMarineCustomTools() {
  const tools = ref([]);
  const meta = ref({ totalCount: 0, page: 1 });
  const uiFlags = ref({
    fetchingList: false,
    creatingItem: false,
    updatingItem: false,
    deletingItem: false,
  });

  const isFetching = computed(() => uiFlags.value.fetchingList);

  const fetchTools = async (page = 1) => {
    uiFlags.value.fetchingList = true;
    try {
      const { data } = await MarineCustomToolsAPI.get({ page });
      tools.value = data.payload || [];
      meta.value = {
        totalCount: data.meta?.total_count ?? tools.value.length,
        page: data.meta?.page ?? page,
      };
    } finally {
      uiFlags.value.fetchingList = false;
    }
    return tools.value;
  };

  const createTool = async payload => {
    uiFlags.value.creatingItem = true;
    try {
      const { data } = await MarineCustomToolsAPI.create(payload);
      return data;
    } finally {
      uiFlags.value.creatingItem = false;
    }
  };

  const updateTool = async (id, payload) => {
    uiFlags.value.updatingItem = true;
    try {
      const { data } = await MarineCustomToolsAPI.update(id, payload);
      return data;
    } finally {
      uiFlags.value.updatingItem = false;
    }
  };

  const deleteTool = async id => {
    uiFlags.value.deletingItem = true;
    try {
      await MarineCustomToolsAPI.delete(id);
    } finally {
      uiFlags.value.deletingItem = false;
    }
    return id;
  };

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
