<script setup>
import { ref } from 'vue';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import MarineAssistantAPI from 'dashboard/api/marine/assistant';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

const props = defineProps({
  entity: {
    type: Object,
    required: true,
  },
  title: {
    type: String,
    required: true,
  },
  description: {
    type: String,
    required: true,
  },
  confirmButtonLabel: {
    type: String,
    required: true,
  },
  successMessage: {
    type: String,
    required: true,
  },
  errorMessage: {
    type: String,
    required: true,
  },
});

const emit = defineEmits(['deleteSuccess']);

const dialogRef = ref(null);

const handleDialogConfirm = async () => {
  try {
    await MarineAssistantAPI.delete(props.entity.id);
    emit('deleteSuccess');
    useAlert(props.successMessage);
  } catch (error) {
    useAlert(parseAPIErrorResponse(error) || props.errorMessage);
  } finally {
    dialogRef.value?.close();
  }
};

defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="alert"
    :title="title"
    :description="description"
    :confirm-button-label="confirmButtonLabel"
    @confirm="handleDialogConfirm"
  />
</template>
