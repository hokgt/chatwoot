<script setup>
import { computed, onMounted, ref, nextTick } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useMarineCustomTools } from '../composables/useMarineCustomTools';

import MarinePageShell from '../components/MarinePageShell.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Policy from 'dashboard/components/policy.vue';
import CustomToolCard from './components/CustomToolCard.vue';
import CreateCustomToolDialog from './components/CreateCustomToolDialog.vue';

const { t } = useI18n();

const {
  tools,
  meta,
  uiFlags,
  isFetching,
  fetchTools,
  createTool,
  updateTool,
  deleteTool,
} = useMarineCustomTools();

const createDialogRef = ref(null);
const deleteDialogRef = ref(null);
const selectedTool = ref(null);
const dialogType = ref('');

const isMutating = computed(
  () => uiFlags.value.creatingItem || uiFlags.value.updatingItem
);

const submitHandler = computed(() => {
  if (dialogType.value === 'edit') {
    return payload => updateTool(selectedTool.value.id, payload);
  }
  return payload => createTool(payload);
});

const openCreateDialog = () => {
  dialogType.value = 'create';
  selectedTool.value = null;
  nextTick(() => createDialogRef.value.dialogRef.open());
};

const handleEdit = tool => {
  dialogType.value = 'edit';
  selectedTool.value = tool;
  nextTick(() => createDialogRef.value.dialogRef.open());
};

const handleDelete = tool => {
  selectedTool.value = tool;
  nextTick(() => deleteDialogRef.value.open());
};

const handleAction = ({ action, id }) => {
  const tool = tools.value.find(item => item.id === id);
  if (action === 'edit') {
    handleEdit(tool);
  } else if (action === 'delete') {
    handleDelete(tool);
  }
};

const handleDialogClose = () => {
  dialogType.value = '';
  selectedTool.value = null;
};

const onSubmitSuccess = () => fetchTools(meta.value.page);

const confirmDelete = async () => {
  try {
    await deleteTool(selectedTool.value.id);
    useAlert(t('MARINE_AI.CUSTOM_TOOLS.DELETE.SUCCESS_MESSAGE'));
    selectedTool.value = null;
    await fetchTools(meta.value.page);
  } catch (error) {
    useAlert(t('MARINE_AI.CUSTOM_TOOLS.DELETE.ERROR_MESSAGE'));
  } finally {
    deleteDialogRef.value?.close();
  }
};

onMounted(() => fetchTools());
</script>

<template>
  <MarinePageShell
    :title="t('MARINE_AI.CUSTOM_TOOLS.HEADER')"
    :description="t('MARINE_AI.CUSTOM_TOOLS.DESCRIPTION')"
  >
    <div class="flex justify-end">
      <Policy :permissions="['administrator']">
        <Button
          icon="i-lucide-plus"
          :label="t('MARINE_AI.CUSTOM_TOOLS.ADD_NEW')"
          @click="openCreateDialog"
        />
      </Policy>
    </div>

    <div
      v-if="isFetching"
      class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
    >
      <p class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.CUSTOM_TOOLS.LOADING') }}
      </p>
    </div>

    <div
      v-else-if="!tools.length"
      class="rounded-xl border border-n-weak bg-n-solid-1 p-6 flex flex-col items-center gap-3 text-center"
    >
      <span class="i-lucide-wrench text-2xl text-n-slate-10" />
      <p class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.CUSTOM_TOOLS.EMPTY') }}
      </p>
      <Policy :permissions="['administrator']">
        <Button
          sm
          icon="i-lucide-plus"
          :label="t('MARINE_AI.CUSTOM_TOOLS.ADD_NEW')"
          @click="openCreateDialog"
        />
      </Policy>
    </div>

    <div v-else class="flex flex-col gap-4">
      <CustomToolCard
        v-for="tool in tools"
        :id="tool.id"
        :key="tool.id"
        :title="tool.title"
        :description="tool.description"
        :auth-type="tool.auth_type"
        :created-at="tool.created_at"
        :updated-at="tool.updated_at"
        @action="handleAction"
      />
    </div>

    <CreateCustomToolDialog
      v-if="dialogType"
      ref="createDialogRef"
      :type="dialogType"
      :selected-tool="selectedTool"
      :is-loading="isMutating"
      :submit-handler="submitHandler"
      @success="onSubmitSuccess"
      @close="handleDialogClose"
    />

    <Dialog
      ref="deleteDialogRef"
      type="alert"
      :title="t('MARINE_AI.CUSTOM_TOOLS.DELETE.TITLE')"
      :description="t('MARINE_AI.CUSTOM_TOOLS.DELETE.DESCRIPTION')"
      :confirm-button-label="t('MARINE_AI.CUSTOM_TOOLS.DELETE.CONFIRM')"
      @confirm="confirmDelete"
    />
  </MarinePageShell>
</template>
