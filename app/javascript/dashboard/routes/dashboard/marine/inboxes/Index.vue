<script setup>
import { computed, onMounted, ref, watch, nextTick } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import MarineInboxesAPI from 'dashboard/api/marine/inboxes';

import MarinePageLayout from '../components/MarinePageLayout.vue';
import MarineInboxCard from '../components/MarineInboxCard.vue';
import ConnectInboxDialog from '../components/ConnectInboxDialog.vue';
import InboxPageEmptyState from '../components/InboxPageEmptyState.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const { t } = useI18n();
const route = useRoute();

const loading = ref(false);
const inboxes = ref([]);
const dialogType = ref('');
const selectedInbox = ref(null);
const connectDialog = ref(null);
const deleteDialog = ref(null);

const assistantId = computed(() => Number(route.params.assistantId));

const fetchInboxes = async () => {
  if (!assistantId.value) {
    inboxes.value = [];
    return;
  }
  loading.value = true;
  try {
    const { data } = await MarineInboxesAPI.get({
      assistantId: assistantId.value,
    });
    inboxes.value = data.payload || [];
  } finally {
    loading.value = false;
  }
};

const handleCreate = () => {
  dialogType.value = 'create';
  nextTick(() => connectDialog.value.dialogRef.open());
};

const handleCreateClose = async () => {
  dialogType.value = '';
  await fetchInboxes();
};

const handleDelete = inbox => {
  selectedInbox.value = inbox;
  nextTick(() => deleteDialog.value.open());
};

const confirmDelete = async () => {
  try {
    await MarineInboxesAPI.delete({
      assistantId: assistantId.value,
      inboxId: selectedInbox.value.id,
    });
    useAlert(t('MARINE_AI.INBOXES.DELETE.SUCCESS'));
    selectedInbox.value = null;
    await fetchInboxes();
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) || t('MARINE_AI.INBOXES.DELETE.ERROR')
    );
  } finally {
    deleteDialog.value?.close();
  }
};

const handleAction = ({ action, id }) => {
  const inbox = inboxes.value.find(item => item.id === id);
  if (!inbox) return;
  if (action === 'delete') handleDelete(inbox);
};

watch(assistantId, fetchInboxes);

onMounted(fetchInboxes);
</script>

<template>
  <MarinePageLayout
    :header-title="t('MARINE_AI.INBOXES.HEADER')"
    :button-label="t('MARINE_AI.INBOXES.ADD_NEW')"
    :button-policy="['administrator']"
    :is-fetching="loading"
    :is-empty="inboxes.length === 0"
    :show-pagination-footer="false"
    @click="handleCreate"
  >
    <template #emptyState>
      <InboxPageEmptyState @click="handleCreate" />
    </template>

    <template #body>
      <div class="flex flex-col gap-4">
        <MarineInboxCard
          v-for="inbox in inboxes"
          :id="inbox.id"
          :key="inbox.id"
          :inbox="inbox"
          @action="handleAction"
        />
      </div>
    </template>

    <ConnectInboxDialog
      v-if="dialogType === 'create'"
      ref="connectDialog"
      :assistant-id="assistantId"
      @close="handleCreateClose"
    />

    <Dialog
      ref="deleteDialog"
      type="alert"
      :title="t('MARINE_AI.INBOXES.DELETE.TITLE')"
      :description="t('MARINE_AI.INBOXES.DELETE.DESCRIPTION')"
      :confirm-button-label="t('MARINE_AI.INBOXES.DELETE.CONFIRM')"
      :cancel-button-label="t('MARINE_AI.INBOXES.DELETE.CANCEL')"
      @confirm="confirmDelete"
    />
  </MarinePageLayout>
</template>
