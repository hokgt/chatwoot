<script setup>
import { ref, reactive, computed, nextTick, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, url } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import MarineDocumentAPI from 'dashboard/api/marine/document';
import {
  SOP_ACCEPT_HINT,
  validateSopFile,
  isPrimaryCatalogConflict,
} from '../helpers/documentHelpers';

import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Button from 'dashboard/components-next/button/Button.vue';
// Wijaya-owned catalog picker (registered under the marine_ai battery).
import MarineProductFamilySelect from '../../../../../../../custom/wijaya/batteries/marine_ai/frontend/MarineProductFamilySelect.vue';

const props = defineProps({
  assistantId: {
    type: Number,
    required: true,
  },
});

const emit = defineEmits(['close', 'createSuccess']);

const { t } = useI18n();

// Fixed allowlist avoids dynamic i18n-key lookup while preserving helper testability.
const fileErrorMessages = computed(() => ({
  'MARINE_AI.DOCUMENTS.FORM.FILE.INVALID_TYPE': t(
    'MARINE_AI.DOCUMENTS.FORM.FILE.INVALID_TYPE'
  ),
  'MARINE_AI.DOCUMENTS.FORM.FILE.EMPTY': t(
    'MARINE_AI.DOCUMENTS.FORM.FILE.EMPTY'
  ),
  'MARINE_AI.DOCUMENTS.FORM.FILE.TOO_LARGE': t(
    'MARINE_AI.DOCUMENTS.FORM.FILE.TOO_LARGE'
  ),
}));

const dialogRef = ref(null);
const conflictDialogRef = ref(null);
const fileInputRef = ref(null);
const catalogFileInputRef = ref(null);
const isSaving = ref(false);

const initialState = {
  sourceType: 'website',
  name: '',
  externalLink: '',
  content: '',
  sopFile: null,
  catalogFile: null,
  productFamilyCode: '',
};

const state = reactive({ ...initialState });

const sourceTypeOptions = [
  { value: 'website', label: t('MARINE_AI.DOCUMENTS.SOURCE_TYPE.WEBSITE') },
  { value: 'sop', label: t('MARINE_AI.DOCUMENTS.SOURCE_TYPE.SOP') },
  {
    value: 'product_catalog',
    label: t('MARINE_AI.DOCUMENTS.SOURCE_TYPE.PRODUCT_CATALOG'),
  },
];

const isSop = computed(() => state.sourceType === 'sop');
const isProductCatalog = computed(() => state.sourceType === 'product_catalog');
const isWebsite = computed(() => state.sourceType === 'website');

// Website keeps its original URL validation; SOP validates only the selected file;
// product catalog requires both a picked family and a file.
const validationRules = computed(() => {
  if (isProductCatalog.value) {
    return { productFamilyCode: { required }, catalogFile: { required } };
  }
  if (isSop.value) {
    return { sopFile: { required } };
  }
  return { externalLink: { required, url } };
});

const v$ = useVuelidate(validationRules, state);

const formErrors = computed(() => ({
  externalLink: v$.value.externalLink?.$error
    ? t('MARINE_AI.DOCUMENTS.FORM.URL.ERROR')
    : '',
}));

const hasFileError = computed(() => v$.value.sopFile?.$error ?? false);
const hasCatalogFileError = computed(
  () => v$.value.catalogFile?.$error ?? false
);
const hasFamilyError = computed(
  () => v$.value.productFamilyCode?.$error ?? false
);

const openFileDialog = () => {
  nextTick(() => fileInputRef.value?.click());
};

const openCatalogFileDialog = () => {
  nextTick(() => catalogFileInputRef.value?.click());
};

// Clears the staged file AND the native input value so re-selecting the same filename
// still fires a change event and no stale file lingers behind the picker.
const resetFileInput = () => {
  if (fileInputRef.value) fileInputRef.value.value = '';
};

const resetCatalogFileInput = () => {
  if (catalogFileInputRef.value) catalogFileInputRef.value.value = '';
};

const clearSopFile = () => {
  state.sopFile = null;
  resetFileInput();
};

// Product catalog keeps its own file + family state, fully independent from SOP.
const clearCatalog = () => {
  state.catalogFile = null;
  state.productFamilyCode = '';
  resetCatalogFileInput();
};

const handleFileChange = event => {
  const file = event.target.files[0];
  // Any new/invalid selection clears the previously staged file first.
  state.sopFile = null;
  const { valid, errorKey } = validateSopFile(file);
  if (!valid) {
    if (errorKey) useAlert(fileErrorMessages.value[errorKey]);
    resetFileInput();
    return;
  }
  state.sopFile = file;
  if (!state.name) {
    state.name = file.name.replace(/\.(pdf|jpe?g|png)$/i, '');
  }
};

// Product catalog reuses the exact same PDF/JPEG/PNG ≤2 MiB validation as SOP, but
// stages into its own separate state so no file can cross source paths.
const handleCatalogFileChange = event => {
  const file = event.target.files[0];
  state.catalogFile = null;
  const { valid, errorKey } = validateSopFile(file);
  if (!valid) {
    if (errorKey) useAlert(fileErrorMessages.value[errorKey]);
    resetCatalogFileInput();
    return;
  }
  state.catalogFile = file;
  if (!state.name) {
    state.name = file.name.replace(/\.(pdf|jpe?g|png)$/i, '');
  }
};

// Leaving a file-backed source must drop its staged file, native input, and (for catalog)
// the family selection so nothing can be submitted through another source's workflow;
// every switch also resets validation state for the new source.
watch(
  () => state.sourceType,
  (newType, oldType) => {
    if (oldType === 'sop' && newType !== 'sop') clearSopFile();
    if (oldType === 'product_catalog' && newType !== 'product_catalog') {
      clearCatalog();
    }
    v$.value.$reset();
  }
);

const fileSizeLabel = computed(() => {
  if (!state.sopFile) return '';
  return `${(state.sopFile.size / 1024 / 1024).toFixed(2)} MB`;
});

const catalogFileSizeLabel = computed(() => {
  if (!state.catalogFile) return '';
  return `${(state.catalogFile.size / 1024 / 1024).toFixed(2)} MB`;
});

const buildSopFormData = () => {
  const formData = new FormData();
  formData.append('document[source_kind]', 'sop_document');
  formData.append('document[assistant_id]', props.assistantId);
  formData.append('document[name]', state.name || state.sopFile.name);
  formData.append('document[source_file]', state.sopFile);
  return formData;
};

// Always primary_catalog=true; `replace` is false on the first attempt and only true
// after the user explicitly confirms the primary-conflict replacement.
const submitProductCatalog = replace =>
  MarineDocumentAPI.createProductCatalog({
    assistantId: props.assistantId,
    productFamilyCode: state.productFamilyCode,
    name: state.name,
    file: state.catalogFile,
    replace,
  });

const finishCreate = () => {
  useAlert(t('MARINE_AI.DOCUMENTS.CREATE.SUCCESS_MESSAGE'));
  emit('createSuccess');
  dialogRef.value.close();
};

const surfaceError = error => {
  useAlert(
    parseAPIErrorResponse(error) ||
      t('MARINE_AI.DOCUMENTS.CREATE.ERROR_MESSAGE')
  );
};

const handleSubmit = async () => {
  const isFormValid = await v$.value.$validate();
  if (!isFormValid) return;

  isSaving.value = true;
  try {
    if (isProductCatalog.value) {
      await submitProductCatalog(false);
    } else if (isSop.value) {
      await MarineDocumentAPI.create(buildSopFormData());
    } else {
      await MarineDocumentAPI.create({
        assistantId: props.assistantId,
        name: state.name,
        externalLink: state.externalLink,
        content: state.content,
      });
    }
    finishCreate();
  } catch (error) {
    // A primary catalog already exists: never silently replace. Open an explicit
    // confirmation and keep the form (with its staged file/family) open.
    if (isProductCatalog.value && isPrimaryCatalogConflict(error)) {
      conflictDialogRef.value?.open();
      return;
    }
    surfaceError(error);
  } finally {
    isSaving.value = false;
  }
};

// Confirmed replacement: retry the same upload with replace=true.
const handleConflictConfirm = async () => {
  conflictDialogRef.value?.close();
  isSaving.value = true;
  try {
    await submitProductCatalog(true);
    finishCreate();
  } catch (error) {
    surfaceError(error);
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
      <div class="flex flex-col gap-1">
        <label
          for="marineDocumentSourceType"
          class="mb-0.5 text-sm font-medium text-n-slate-12"
        >
          {{ t('MARINE_AI.DOCUMENTS.SOURCE_TYPE.LABEL') }}
        </label>
        <select
          id="marineDocumentSourceType"
          v-model="state.sourceType"
          class="w-full px-3 py-2.5 text-sm rounded-xl border outline-none bg-n-alpha-black2 border-n-weak text-n-slate-12 focus:border-n-brand"
        >
          <option
            v-for="option in sourceTypeOptions"
            :key="option.value"
            :value="option.value"
          >
            {{ option.label }}
          </option>
        </select>
      </div>

      <Input
        v-model="state.name"
        :label="t('MARINE_AI.DOCUMENTS.FORM.NAME.LABEL')"
        :placeholder="t('MARINE_AI.DOCUMENTS.FORM.NAME.PLACEHOLDER')"
      />

      <template v-if="isWebsite">
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
      </template>

      <template v-else-if="isProductCatalog">
        <MarineProductFamilySelect
          v-model="state.productFamilyCode"
          :has-error="hasFamilyError"
        />
        <div class="flex flex-col gap-2">
          <label class="text-sm font-medium text-n-slate-12">
            {{ t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.FILE.LABEL') }}
          </label>
          <input
            ref="catalogFileInputRef"
            type="file"
            :accept="SOP_ACCEPT_HINT"
            class="hidden"
            @change="handleCatalogFileChange"
          />
          <Button
            type="button"
            :color="hasCatalogFileError ? 'ruby' : 'slate'"
            :variant="hasCatalogFileError ? 'outline' : 'solid'"
            class="!w-full !h-auto !justify-between !py-4"
            @click="openCatalogFileDialog"
          >
            <template #default>
              <div class="flex gap-2 items-center">
                <div
                  class="flex justify-center items-center w-10 h-10 rounded-lg bg-n-slate-3"
                >
                  <i class="text-xl i-ph-file-text text-n-slate-11" />
                </div>
                <div class="flex flex-col flex-1 gap-1 items-start">
                  <p class="m-0 text-sm font-medium text-n-slate-12">
                    {{
                      state.catalogFile
                        ? state.catalogFile.name
                        : t('MARINE_AI.DOCUMENTS.FORM.FILE.CHOOSE_FILE')
                    }}
                  </p>
                  <p class="m-0 text-xs text-n-slate-11">
                    {{
                      state.catalogFile
                        ? catalogFileSizeLabel
                        : t('MARINE_AI.DOCUMENTS.FORM.FILE.HELP_TEXT')
                    }}
                  </p>
                </div>
              </div>
              <i class="i-lucide-upload text-n-slate-11" />
            </template>
          </Button>
          <p v-if="hasCatalogFileError" class="text-xs text-n-ruby-9">
            {{ t('MARINE_AI.DOCUMENTS.FORM.FILE.REQUIRED') }}
          </p>
        </div>
      </template>

      <div v-else class="flex flex-col gap-2">
        <label class="text-sm font-medium text-n-slate-12">
          {{ t('MARINE_AI.DOCUMENTS.FORM.FILE.LABEL') }}
        </label>
        <input
          ref="fileInputRef"
          type="file"
          :accept="SOP_ACCEPT_HINT"
          class="hidden"
          @change="handleFileChange"
        />
        <Button
          type="button"
          :color="hasFileError ? 'ruby' : 'slate'"
          :variant="hasFileError ? 'outline' : 'solid'"
          class="!w-full !h-auto !justify-between !py-4"
          @click="openFileDialog"
        >
          <template #default>
            <div class="flex gap-2 items-center">
              <div
                class="flex justify-center items-center w-10 h-10 rounded-lg bg-n-slate-3"
              >
                <i class="text-xl i-ph-file-text text-n-slate-11" />
              </div>
              <div class="flex flex-col flex-1 gap-1 items-start">
                <p class="m-0 text-sm font-medium text-n-slate-12">
                  {{
                    state.sopFile
                      ? state.sopFile.name
                      : t('MARINE_AI.DOCUMENTS.FORM.FILE.CHOOSE_FILE')
                  }}
                </p>
                <p class="m-0 text-xs text-n-slate-11">
                  {{
                    state.sopFile
                      ? fileSizeLabel
                      : t('MARINE_AI.DOCUMENTS.FORM.FILE.HELP_TEXT')
                  }}
                </p>
              </div>
            </div>
            <i class="i-lucide-upload text-n-slate-11" />
          </template>
        </Button>
        <p v-if="hasFileError" class="text-xs text-n-ruby-9">
          {{ t('MARINE_AI.DOCUMENTS.FORM.FILE.REQUIRED') }}
        </p>
      </div>

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

  <Dialog
    ref="conflictDialogRef"
    type="alert"
    :title="t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.CONFLICT.TITLE')"
    :description="t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.CONFLICT.MESSAGE')"
    :confirm-button-label="
      t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.CONFLICT.CONFIRM')
    "
    :cancel-button-label="
      t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.CONFLICT.CANCEL')
    "
    @confirm="handleConflictConfirm"
  />
</template>
