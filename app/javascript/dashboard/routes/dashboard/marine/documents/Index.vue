<script setup>
import { computed, onMounted, ref, watch, nextTick } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { debounce } from '@chatwoot/utils';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import MarineDocumentAPI from 'dashboard/api/marine/document';

import MarinePageLayout from '../components/MarinePageLayout.vue';
import MarineDocumentCard from '../components/MarineDocumentCard.vue';
import CreateDocumentDialog from '../components/CreateDocumentDialog.vue';
import DocumentPageEmptyState from '../components/DocumentPageEmptyState.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const { t } = useI18n();
const route = useRoute();

const loading = ref(false);
const documents = ref([]);
const searchQuery = ref('');
const effectiveQuery = ref('');

const dialogType = ref('');
const selectedDocument = ref(null);
const createDialog = ref(null);
const deleteDialog = ref(null);

const assistantId = computed(() => Number(route.params.assistantId));

const filteredDocuments = computed(() => {
  const query = effectiveQuery.value.trim().toLowerCase();
  if (!query) return documents.value;
  return documents.value.filter(
    document =>
      document.name?.toLowerCase().includes(query) ||
      document.external_link?.toLowerCase().includes(query)
  );
});

const hasActiveFilters = computed(() => !!effectiveQuery.value);
const isEmpty = computed(() => filteredDocuments.value.length === 0);

const fetchDocuments = async () => {
  if (!assistantId.value) {
    documents.value = [];
    return;
  }
  loading.value = true;
  try {
    const { data } = await MarineDocumentAPI.get({
      assistantId: assistantId.value,
    });
    documents.value = data.payload || [];
  } finally {
    loading.value = false;
  }
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
  nextTick(() => createDialog.value.dialogRef.open());
};

const handleCreateClose = async () => {
  dialogType.value = '';
  await fetchDocuments();
};

const handleDelete = document => {
  selectedDocument.value = document;
  nextTick(() => deleteDialog.value.open());
};

const confirmDelete = async () => {
  try {
    await MarineDocumentAPI.delete(selectedDocument.value.id);
    useAlert(t('MARINE_AI.DOCUMENTS.DELETE.SUCCESS'));
    selectedDocument.value = null;
    await fetchDocuments();
  } catch (error) {
    useAlert(parseAPIErrorResponse(error));
  } finally {
    deleteDialog.value?.close();
  }
};

const handleSync = async id => {
  try {
    await MarineDocumentAPI.sync(id);
    useAlert(t('MARINE_AI.DOCUMENTS.SYNC.QUEUED_MESSAGE'));
    await fetchDocuments();
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('MARINE_AI.DOCUMENTS.SYNC.ERROR_MESSAGE')
    );
  }
};

const handleAction = ({ action, id }) => {
  const document = documents.value.find(item => item.id === id);
  if (!document) return;
  if (action === 'sync') handleSync(id);
  else if (action === 'delete') handleDelete(document);
};

watch(assistantId, () => {
  clearFilters();
  fetchDocuments();
});

onMounted(fetchDocuments);
</script>

<template>
  <MarinePageLayout
    :header-title="t('MARINE_AI.DOCUMENTS.HEADER')"
    :button-label="t('MARINE_AI.DOCUMENTS.ADD_NEW')"
    :button-policy="['administrator']"
    :is-fetching="loading"
    :is-empty="isEmpty"
    :show-pagination-footer="false"
    @click="handleCreate"
  >
    <template #search>
      <Input
        v-model="searchQuery"
        :placeholder="t('MARINE_AI.DOCUMENTS.SEARCH_PLACEHOLDER')"
        class="w-64"
        size="sm"
        type="search"
        @input="debouncedSearch"
      />
    </template>

    <template #emptyState>
      <DocumentPageEmptyState
        :has-active-filters="hasActiveFilters"
        @click="handleCreate"
        @clear-filters="clearFilters"
      />
    </template>

    <template #body>
      <div class="flex flex-col gap-4">
        <MarineDocumentCard
          v-for="document in filteredDocuments"
          :id="document.id"
          :key="document.id"
          :name="document.name || document.external_link"
          :external-link="document.external_link"
          :assistant="document.assistant"
          :created-at="document.created_at"
          :status="document.status"
          :sync-status="document.sync_status"
          @action="handleAction"
        />
      </div>
    </template>

    <CreateDocumentDialog
      v-if="dialogType === 'create'"
      ref="createDialog"
      :assistant-id="assistantId"
      @close="handleCreateClose"
    />

    <Dialog
      ref="deleteDialog"
      type="alert"
      :title="t('MARINE_AI.DOCUMENTS.DELETE.TITLE')"
      :description="t('MARINE_AI.DOCUMENTS.DELETE.MESSAGE')"
      :confirm-button-label="t('MARINE_AI.DOCUMENTS.DELETE.CONFIRM')"
      :cancel-button-label="t('MARINE_AI.DOCUMENTS.DELETE.CANCEL')"
      @confirm="confirmDelete"
    />
  </MarinePageLayout>
</template>
