<script setup>
import { ref, reactive, computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import MarineResponseAPI from 'dashboard/api/marine/response';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  selectedResponse: {
    type: Object,
    default: () => ({}),
  },
  type: {
    type: String,
    default: 'create',
    validator: value => ['create', 'edit'].includes(value),
  },
});

const emit = defineEmits(['close']);

const { t } = useI18n();
const route = useRoute();

const dialogRef = ref(null);
const isSaving = ref(false);

const i18nKey = computed(() => `MARINE_AI.FAQS.${props.type.toUpperCase()}`);

const initialState = {
  question: '',
  answer: '',
};

const state = reactive({ ...initialState });

const validationRules = {
  question: { required, minLength: minLength(1) },
  answer: { required, minLength: minLength(1) },
};

const v$ = useVuelidate(validationRules, state);

const formErrors = computed(() => ({
  question: v$.value.question.$error
    ? t('MARINE_AI.FAQS.FORM.QUESTION.ERROR')
    : '',
  answer: v$.value.answer.$error ? t('MARINE_AI.FAQS.FORM.ANSWER.ERROR') : '',
}));

watch(
  () => props.selectedResponse,
  newResponse => {
    if (props.type === 'edit' && newResponse) {
      state.question = newResponse.question || '';
      state.answer = newResponse.answer || '';
    }
  },
  { immediate: true }
);

const handleSubmit = async () => {
  const isFormValid = await v$.value.$validate();
  if (!isFormValid) return;

  isSaving.value = true;
  try {
    if (props.type === 'edit') {
      await MarineResponseAPI.update(props.selectedResponse.id, {
        question: state.question,
        answer: state.answer,
      });
    } else {
      await MarineResponseAPI.create({
        assistantId: route.params.assistantId,
        question: state.question,
        answer: state.answer,
      });
    }
    useAlert(t(`${i18nKey.value}.SUCCESS_MESSAGE`));
    dialogRef.value.close();
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) || t(`${i18nKey.value}.ERROR_MESSAGE`)
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
    :title="$t(`${i18nKey}.TITLE`)"
    :description="$t('MARINE_AI.FAQS.FORM_DESCRIPTION')"
    :show-cancel-button="false"
    :show-confirm-button="false"
    @close="handleClose"
  >
    <form class="flex flex-col gap-4" @submit.prevent="handleSubmit">
      <Input
        v-model="state.question"
        :label="t('MARINE_AI.FAQS.FORM.QUESTION.LABEL')"
        :placeholder="t('MARINE_AI.FAQS.FORM.QUESTION.PLACEHOLDER')"
        :message="formErrors.question"
        :message-type="formErrors.question ? 'error' : 'info'"
      />
      <TextArea
        v-model="state.answer"
        :label="t('MARINE_AI.FAQS.FORM.ANSWER.LABEL')"
        :placeholder="t('MARINE_AI.FAQS.FORM.ANSWER.PLACEHOLDER')"
        :message="formErrors.answer"
        :message-type="formErrors.answer ? 'error' : 'info'"
        :rows="5"
      />
      <div class="flex items-center justify-between w-full gap-3">
        <Button
          type="button"
          variant="faded"
          color="slate"
          :label="t('MARINE_AI.FAQS.DELETE.CANCEL')"
          class="w-full bg-n-alpha-2 text-n-blue-11 hover:bg-n-alpha-3"
          @click="handleCancel"
        />
        <Button
          type="submit"
          :label="
            t(
              type === 'edit'
                ? 'MARINE_AI.FAQS.OPTIONS.EDIT_RESPONSE'
                : 'MARINE_AI.FAQS.ADD_NEW'
            )
          "
          class="w-full"
          :is-loading="isSaving"
          :disabled="isSaving"
        />
      </div>
    </form>
    <template #footer />
  </Dialog>
</template>
