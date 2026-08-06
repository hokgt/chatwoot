<script setup>
import { computed, onMounted, ref, watch, nextTick } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { debounce } from '@chatwoot/utils';
import { useAlert } from 'dashboard/composables';
import MarineResponseAPI from 'dashboard/api/marine/response';

import MarinePageLayout from '../components/MarinePageLayout.vue';
import MarineResponseCard from '../components/MarineResponseCard.vue';
import CreateResponseDialog from '../components/CreateResponseDialog.vue';
import ResponsePageEmptyState from '../components/ResponsePageEmptyState.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const { t } = useI18n();
const route = useRoute();
const router = useRouter();

const loading = ref(false);
const responses = ref([]);
const searchQuery = ref('');
const effectiveQuery = ref('');
const statusFilter = ref(route.meta?.defaultStatus || 'all');

const dialogType = ref('');
const selectedResponse = ref(null);
const createDialog = ref(null);
const deleteDialog = ref(null);

const statusTabs = ['all', 'pending', 'approved'];

const assistantId = computed(() => route.params.assistantId);

const statusTabLabel = value => {
  if (value === 'pending') return t('MARINE_AI.FAQS.STATUS_PENDING');
  if (value === 'approved') return t('MARINE_AI.FAQS.STATUS_APPROVED');
  return t('MARINE_AI.FAQS.STATUS_ALL');
};

const filteredResponses = computed(() => {
  const query = effectiveQuery.value.trim().toLowerCase();
  if (!query) return responses.value;
  return responses.value.filter(
    response =>
      response.question?.toLowerCase().includes(query) ||
      response.answer?.toLowerCase().includes(query)
  );
});

const hasActiveFilters = computed(() => !!effectiveQuery.value);
const isEmpty = computed(() => filteredResponses.value.length === 0);

const fetchResponses = async () => {
  if (!assistantId.value) {
    responses.value = [];
    return;
  }
  loading.value = true;
  try {
    const { data } = await MarineResponseAPI.get({
      assistantId: assistantId.value,
      status: statusFilter.value === 'all' ? undefined : statusFilter.value,
    });
    responses.value = data.payload || [];
  } finally {
    loading.value = false;
  }
};

const setStatusFilter = async value => {
  statusFilter.value = value;
  await fetchResponses();
};

const debouncedSearch = debounce(() => {
  effectiveQuery.value = searchQuery.value;
}, 300);

const clearFilters = () => {
  searchQuery.value = '';
  effectiveQuery.value = '';
};

const handleCreate = () => {
  dialogType.value = 'create';
  selectedResponse.value = null;
  nextTick(() => createDialog.value.dialogRef.open());
};

const handleEdit = response => {
  dialogType.value = 'edit';
  selectedResponse.value = response;
  nextTick(() => createDialog.value.dialogRef.open());
};

const handleCreateClose = async () => {
  dialogType.value = '';
  selectedResponse.value = null;
  await fetchResponses();
};

const approveResponse = async response => {
  await MarineResponseAPI.approve(response.id);
  await fetchResponses();
};

const handleDelete = response => {
  selectedResponse.value = response;
  nextTick(() => deleteDialog.value.open());
};

const confirmDelete = async () => {
  try {
    await MarineResponseAPI.delete(selectedResponse.value.id);
    useAlert(t('MARINE_AI.FAQS.DELETE.SUCCESS'));
    selectedResponse.value = null;
    await fetchResponses();
  } finally {
    deleteDialog.value?.close();
  }
};

const handleAction = ({ action, id }) => {
  const response = responses.value.find(item => item.id === id);
  if (!response) return;
  if (action === 'approve') approveResponse(response);
  else if (action === 'edit') handleEdit(response);
  else if (action === 'delete') handleDelete(response);
};

const handleNavigationAction = ({ id, type }) => {
  if (type === 'Conversation') {
    router.push({
      name: 'inbox_conversation',
      params: { conversation_id: id },
    });
  }
};

watch(assistantId, () => {
  clearFilters();
  fetchResponses();
});

onMounted(fetchResponses);
</script>

<template>
  <MarinePageLayout
    :header-title="t('MARINE_AI.FAQS.HEADER')"
    :button-label="t('MARINE_AI.FAQS.ADD_NEW')"
    :button-policy="['administrator']"
    :is-fetching="loading"
    :is-empty="isEmpty"
    :show-pagination-footer="false"
    @click="handleCreate"
  >
    <template #search>
      <Input
        v-model="searchQuery"
        :placeholder="t('MARINE_AI.FAQS.SEARCH_PLACEHOLDER')"
        class="w-64"
        size="sm"
        type="search"
        @input="debouncedSearch"
      />
    </template>

    <template #controls>
      <div class="flex gap-2 mb-4">
        <button
          v-for="tab in statusTabs"
          :key="tab"
          type="button"
          class="rounded-lg border px-3 py-1.5 text-sm font-medium"
          :class="
            statusFilter === tab
              ? 'border-n-brand bg-n-brand text-white'
              : 'border-n-weak text-n-slate-11'
          "
          @click="setStatusFilter(tab)"
        >
          {{ statusTabLabel(tab) }}
        </button>
      </div>
    </template>

    <template #emptyState>
      <ResponsePageEmptyState
        :variant="statusFilter === 'pending' ? 'pending' : 'approved'"
        :has-active-filters="hasActiveFilters"
        @click="handleCreate"
        @clear-filters="clearFilters"
      />
    </template>

    <template #body>
      <div class="flex flex-col gap-4">
        <MarineResponseCard
          v-for="response in filteredResponses"
          :id="response.id"
          :key="response.id"
          :question="response.question"
          :answer="response.answer"
          :status="response.status"
          :assistant="response.assistant"
          :documentable="response.documentable"
          :created-at="response.created_at"
          :updated-at="response.updated_at"
          @action="handleAction"
          @navigate="handleNavigationAction"
        />
      </div>
    </template>

    <CreateResponseDialog
      v-if="dialogType"
      ref="createDialog"
      :type="dialogType"
      :selected-response="selectedResponse"
      @close="handleCreateClose"
    />

    <Dialog
      ref="deleteDialog"
      type="alert"
      :title="t('MARINE_AI.FAQS.DELETE.TITLE')"
      :description="t('MARINE_AI.FAQS.DELETE.MESSAGE')"
      :confirm-button-label="t('MARINE_AI.FAQS.DELETE.CONFIRM')"
      :cancel-button-label="t('MARINE_AI.FAQS.DELETE.CANCEL')"
      @confirm="confirmDelete"
    />
  </MarinePageLayout>
</template>
