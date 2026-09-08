<script setup>
import { ref, reactive, computed, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import InboxesAPI from 'dashboard/api/inboxes';
import MarineInboxesAPI from '@wijaya/marine_ai/frontend/api/inboxes';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  assistantId: {
    type: Number,
    required: true,
  },
});

const emit = defineEmits(['close']);

const { t } = useI18n();

const dialogRef = ref(null);
const isSaving = ref(false);
const allInboxes = ref([]);
const connectedInboxes = ref([]);

const state = reactive({ inboxId: null });

const validationRules = {
  inboxId: { required },
};

const v$ = useVuelidate(validationRules, state);

const inboxList = computed(() => {
  const connectedIds = connectedInboxes.value.map(inbox => inbox.id);
  return allInboxes.value
    .filter(inbox => !connectedIds.includes(inbox.id))
    .map(inbox => ({
      value: inbox.id,
      label: inbox.name,
    }));
});

const formErrors = computed(() => ({
  inboxId: v$.value.inboxId.$error
    ? t('MARINE_AI.INBOXES.FORM.INBOX.ERROR')
    : '',
}));

const fetchInboxes = async () => {
  const [{ data: allData }, { data: connectedData }] = await Promise.all([
    InboxesAPI.get(),
    MarineInboxesAPI.get({ assistantId: props.assistantId }),
  ]);
  allInboxes.value = allData.payload || [];
  connectedInboxes.value = connectedData.payload || [];
};

const handleSubmit = async () => {
  const isFormValid = await v$.value.$validate();
  if (!isFormValid) return;

  isSaving.value = true;
  try {
    await MarineInboxesAPI.create({
      assistantId: props.assistantId,
      inboxId: state.inboxId,
    });
    useAlert(t('MARINE_AI.INBOXES.CREATE.SUCCESS'));
    dialogRef.value.close();
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) || t('MARINE_AI.INBOXES.CREATE.ERROR')
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

onMounted(fetchInboxes);

defineExpose({ dialogRef });
</script>

<template>
  <Dialog
    ref="dialogRef"
    type="create"
    :title="t('MARINE_AI.INBOXES.CREATE.TITLE')"
    :description="t('MARINE_AI.INBOXES.FORM_DESCRIPTION')"
    :show-cancel-button="false"
    :show-confirm-button="false"
    @close="handleClose"
  >
    <form class="flex flex-col gap-4" @submit.prevent="handleSubmit">
      <div class="flex flex-col gap-1">
        <label for="inbox" class="mb-0.5 text-sm font-medium text-n-slate-12">
          {{ t('MARINE_AI.INBOXES.FORM.INBOX.LABEL') }}
        </label>
        <ComboBox
          id="inbox"
          v-model="state.inboxId"
          :options="inboxList"
          :has-error="!!formErrors.inboxId"
          :placeholder="t('MARINE_AI.INBOXES.FORM.INBOX.PLACEHOLDER')"
          class="[&>div>button]:bg-n-alpha-black2 [&>div>button:not(.focused)]:dark:outline-n-weak [&>div>button:not(.focused)]:hover:!outline-n-slate-6"
          :message="formErrors.inboxId"
        />
      </div>

      <div class="flex items-center justify-between w-full gap-3">
        <Button
          type="button"
          variant="faded"
          color="slate"
          :label="t('MARINE_AI.INBOXES.DELETE.CANCEL')"
          class="w-full bg-n-alpha-2 text-n-blue-11 hover:bg-n-alpha-3"
          @click="handleCancel"
        />
        <Button
          type="submit"
          :label="t('MARINE_AI.INBOXES.ADD_NEW')"
          class="w-full"
          :is-loading="isSaving"
          :disabled="isSaving"
        />
      </div>
    </form>
    <template #footer />
  </Dialog>
</template>
