<script setup>
import {
  computed,
  onMounted,
  onBeforeUnmount,
  ref,
  watch,
  nextTick,
} from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { debounce } from '@chatwoot/utils';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import MarineDocumentAPI from '@wijaya/marine_ai/frontend/api/document';
import {
  POLL_INTERVAL,
  hasActiveWork,
  nextPollDelay,
} from '../helpers/documentHelpers';

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

// SOP extraction/OCR then indexing can outlast a single refresh, so we poll while any
// document is still processing and stop once every document reaches a terminal state.
// A monotonic request token discards stale in-flight responses (e.g. from a previous
// assistant), and all timers are tracked so nothing fires after unmount.
let pollTimer = null;
let syncTimer = null;
let requestToken = 0;
let pollDelay = POLL_INTERVAL;
let isMounted = true;

const assistantId = computed(() => Number(route.params.assistantId));

const filteredDocuments = computed(() => {
  const query = effectiveQuery.value.trim().toLowerCase();
  if (!query) return documents.value;
  return documents.value.filter(
    document =>
      document.name?.toLowerCase().includes(query) ||
      document.external_link?.toLowerCase().includes(query) ||
      document.source_file?.filename?.toLowerCase().includes(query)
  );
});

const hasActiveFilters = computed(() => !!effectiveQuery.value);
const isEmpty = computed(() => filteredDocuments.value.length === 0);

const stopPolling = () => {
  if (pollTimer) {
    clearTimeout(pollTimer);
    pollTimer = null;
  }
};

const clearTimers = () => {
  stopPolling();
  if (syncTimer) {
    clearTimeout(syncTimer);
    syncTimer = null;
  }
};

const fetchDocuments = async () => {
  if (!assistantId.value) {
    documents.value = [];
    return;
  }
  requestToken += 1;
  const token = requestToken;
  loading.value = true;
  try {
    const { data } = await MarineDocumentAPI.get({
      assistantId: assistantId.value,
    });
    // Drop a stale response from a superseded request (assistant switch) or unmount.
    if (!isMounted || token !== requestToken) return;
    documents.value = data.payload || [];
    pollDelay = POLL_INTERVAL;
  } catch (error) {
    // Transient GET failure: never surface an unhandled rejection or strand a just-
    // created/reprocessed document that is not yet in the local list. Retry every list
    // reconciliation with capped exponential backoff until success or unmount.
    if (!isMounted || token !== requestToken) return;
    pollDelay = nextPollDelay(pollDelay);
    stopPolling();
    pollTimer = setTimeout(fetchDocuments, pollDelay);
  } finally {
    if (isMounted && token === requestToken) loading.value = false;
  }
};

// Healthy list refresh: keep polling while any document is still processing, stop once
// all reach a terminal state.
const schedulePolling = () => {
  stopPolling();
  if (!hasActiveWork(documents.value)) return;
  pollTimer = setTimeout(fetchDocuments, POLL_INTERVAL);
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
    if (syncTimer) clearTimeout(syncTimer);
    syncTimer = setTimeout(async () => {
      syncTimer = null;
      await fetchDocuments();
      if (!isMounted) return;
      const document = documents.value.find(item => item.id === id);
      if (!document) return;
      if (document.sync_status === 'failed') {
        useAlert(
          t('MARINE_AI.DOCUMENTS.SYNC.FAILED_MESSAGE', {
            error: document.metadata?.last_sync_error_code || '',
          })
        );
      } else if (document.sync_status === 'synced') {
        useAlert(t('MARINE_AI.DOCUMENTS.SYNC.SUCCESS_MESSAGE'));
      }
    }, 3000);
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('MARINE_AI.DOCUMENTS.SYNC.ERROR_MESSAGE')
    );
  }
};

// SOP reprocess reuses the sync endpoint, then relies on polling to surface the live
// extraction/indexing progress on the card.
const handleReprocess = async id => {
  try {
    await MarineDocumentAPI.sync(id);
    useAlert(t('MARINE_AI.DOCUMENTS.SOP.REPROCESS.QUEUED_MESSAGE'));
    await fetchDocuments();
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('MARINE_AI.DOCUMENTS.SOP.REPROCESS.ERROR_MESSAGE')
    );
  }
};

const handleAction = ({ action, id }) => {
  const document = documents.value.find(item => item.id === id);
  if (!document) return;
  if (action === 'sync') handleSync(id);
  else if (action === 'reprocess') handleReprocess(id);
  else if (action === 'delete') handleDelete(document);
};

// Reschedule polling from the freshly loaded list: keep polling while any document is
// still processing, stop automatically once all reach a terminal state.
watch(documents, schedulePolling);

watch(assistantId, () => {
  clearTimers();
  // Invalidate any in-flight fetch so a late response from the previous assistant can
  // never overwrite the new assistant's list.
  requestToken += 1;
  pollDelay = POLL_INTERVAL;
  clearFilters();
  fetchDocuments();
});

onMounted(fetchDocuments);
onBeforeUnmount(() => {
  isMounted = false;
  requestToken += 1;
  clearTimers();
});
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
          :name="
            document.name ||
            document.source_file?.filename ||
            document.external_link
          "
          :external-link="document.external_link || ''"
          :source-kind="document.source_kind"
          :source-file="document.source_file"
          :product-family-code="document.product_family_code"
          :primary-catalog="document.primary_catalog"
          :indexing-status="document.metadata?.indexing_status"
          :indexed-chunk-count="document.metadata?.indexed_chunk_count"
          :failure-code="
            document.metadata?.last_sync_error_code ||
            document.metadata?.indexing_error_code
          "
          :assistant="document.assistant"
          :created-at="document.created_at"
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
