<script setup>
import { ref, reactive, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, url } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import MarineDocumentAPI from 'dashboard/api/marine/document';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  assistantId: {
    type: Number,
    required: true,
  },
});

const emit = defineEmits(['close', 'createSuccess']);

const { t } = useI18n();

const dialogRef = ref(null);
const isSaving = ref(false);

const initialState = {
  name: '',
  externalLink: '',
  content: '',
};

const state = reactive({ ...initialState });

const validationRules = {
  externalLink: { required, url },
};

const v$ = useVuelidate(validationRules, state);

const formErrors = computed(() => ({
  externalLink: v$.value.externalLink.$error
    ? t('MARINE_AI.DOCUMENTS.FORM.URL.ERROR')
    : '',
}));

const handleSubmit = async () => {
  const isFormValid = await v$.value.$validate();
  if (!isFormValid) return;

  isSaving.value = true;
  try {
    await MarineDocumentAPI.create({
      assistantId: props.assistantId,
      name: state.name,
      externalLink: state.externalLink,
      content: state.content,
    });
    useAlert(t('MARINE_AI.DOCUMENTS.CREATE.SUCCESS_MESSAGE'));
    emit('createSuccess');
    dialogRef.value.close();
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('MARINE_AI.DOCUMENTS.CREATE.ERROR_MESSAGE')
    );
  } finally {
    isSaving.value = false;
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
    :title="t('MARINE_AI.DOCUMENTS.CREATE.TITLE')"
    :description="t('MARINE_AI.DOCUMENTS.FORM_DESCRIPTION')"
    :show-cancel-button="false"
    :show-confirm-button="false"
    @close="handleClose"
  >
    <form class="flex flex-col gap-4" @submit.prevent="handleSubmit">
      <Input
        v-model="state.name"
        :label="t('MARINE_AI.DOCUMENTS.FORM.NAME.LABEL')"
        :placeholder="t('MARINE_AI.DOCUMENTS.FORM.NAME.PLACEHOLDER')"
      />
      <Input
        v-model="state.externalLink"
        :label="t('MARINE_AI.DOCUMENTS.FORM.URL.LABEL')"
        :placeholder="t('MARINE_AI.DOCUMENTS.FORM.URL.PLACEHOLDER')"
        :message="formErrors.externalLink"
        :message-type="formErrors.externalLink ? 'error' : 'info'"
      />
      <TextArea
        v-model="state.content"
        :label="t('MARINE_AI.DOCUMENTS.FORM.CONTENT.LABEL')"
        :placeholder="t('MARINE_AI.DOCUMENTS.FORM.CONTENT.PLACEHOLDER')"
        :rows="5"
      />
      <div class="flex items-center justify-between w-full gap-3">
        <Button
          type="button"
          variant="faded"
          color="slate"
          :label="t('MARINE_AI.DOCUMENTS.DELETE.CANCEL')"
          class="w-full bg-n-alpha-2 text-n-blue-11 hover:bg-n-alpha-3"
          @click="handleCancel"
        />
        <Button
          type="submit"
          :label="t('MARINE_AI.DOCUMENTS.ADD_NEW')"
          class="w-full"
          :is-loading="isSaving"
          :disabled="isSaving"
        />
      </div>
    </form>
    <template #footer />
  </Dialog>
</template>
