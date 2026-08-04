<script setup>
import { ref, computed } from 'vue';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import CustomToolForm from './CustomToolForm.vue';

const props = defineProps({
  selectedTool: {
    type: Object,
    default: () => ({}),
  },
  type: {
    type: String,
    default: 'create',
    validator: value => ['create', 'edit'].includes(value),
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
  submitHandler: {
    type: Function,
    required: true,
  },
});

const emit = defineEmits(['close', 'success']);
const { t } = useI18n();

const dialogRef = ref(null);

const i18nKey = computed(
  () => `MARINE_AI.CUSTOM_TOOLS.${props.type.toUpperCase()}`
);

const handleSubmit = async toolDetails => {
  try {
    await props.submitHandler({ ...toolDetails });
    useAlert(t(`${i18nKey.value}.SUCCESS_MESSAGE`));
    emit('success');
    dialogRef.value.close();
  } catch (error) {
    const errorMessage =
      parseAPIErrorResponse(error) || t(`${i18nKey.value}.ERROR_MESSAGE`);
    useAlert(errorMessage);
  }
};

const handleClose = () => {
  emit('close');
};

const handleCancel = () => {
  dialogRef.value.close();
};

defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="2xl"
    :title="$t(`${i18nKey}.TITLE`)"
    :description="$t('MARINE_AI.CUSTOM_TOOLS.FORM_DESCRIPTION')"
    :show-cancel-button="false"
    :show-confirm-button="false"
    @close="handleClose"
  >
    <CustomToolForm
      :mode="type"
      :tool="selectedTool"
      :is-loading="isLoading"
      @submit="handleSubmit"
      @cancel="handleCancel"
    />
    <template #footer />
  </Dialog>
</template>
