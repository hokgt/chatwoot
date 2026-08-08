<script setup>
// WIJAYA_CUSTOM erp_lead_sidebar
// Account-admin-only ERPNext connection settings page. The raw API key/secret
// are never returned by the server (only presence + source metadata), so the
// password inputs start blank and a blank input on Save preserves the stored
// value. Mirrors the native settings look via SettingsLayout / BaseSettingsHeader.
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import WijayaErpSettingsAPI from '@wijaya/erp_lead_sidebar/frontend/api/wijayaErpSettings';

import SettingsLayout from 'dashboard/routes/dashboard/settings/SettingsLayout.vue';
import BaseSettingsHeader from 'dashboard/routes/dashboard/settings/components/BaseSettingsHeader.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const { t } = useI18n();

const isFetching = ref(false);
const isSaving = ref(false);
const isTesting = ref(false);
const testResult = ref(null);

const meta = reactive({
  api_key_present: false,
  api_key_source: null,
  api_secret_present: false,
  api_secret_source: null,
});

const isEditingApiKey = ref(false);
const isEditingApiSecret = ref(false);

const state = reactive({
  host: '',
  api_key: '',
  api_secret: '',
});

const apiKeySourceLabel = computed(() =>
  meta.api_key_source === 'env'
    ? t('WIJAYA_ERP_SETTINGS.API_KEY.PRESENT_ENV')
    : t('WIJAYA_ERP_SETTINGS.API_KEY.PRESENT')
);

const apiSecretSourceLabel = computed(() =>
  meta.api_secret_source === 'env'
    ? t('WIJAYA_ERP_SETTINGS.API_SECRET.PRESENT_ENV')
    : t('WIJAYA_ERP_SETTINGS.API_SECRET.PRESENT')
);

const applyResponse = data => {
  state.host = data.host || '';
  state.api_key = '';
  state.api_secret = '';
  meta.api_key_present = data.api_key_present;
  meta.api_key_source = data.api_key_source;
  meta.api_secret_present = data.api_secret_present;
  meta.api_secret_source = data.api_secret_source;
  isEditingApiKey.value = !data.api_key_present;
  isEditingApiSecret.value = !data.api_secret_present;
};

const fetchSettings = async () => {
  isFetching.value = true;
  try {
    const { data } = await WijayaErpSettingsAPI.get();
    applyResponse(data);
  } finally {
    isFetching.value = false;
  }
};

const startEditingApiKey = () => {
  isEditingApiKey.value = true;
  state.api_key = '';
};
const cancelEditingApiKey = () => {
  isEditingApiKey.value = false;
  state.api_key = '';
};
const startEditingApiSecret = () => {
  isEditingApiSecret.value = true;
  state.api_secret = '';
};
const cancelEditingApiSecret = () => {
  isEditingApiSecret.value = false;
  state.api_secret = '';
};

// Blank credential fields are omitted so the server preserves the stored value.
const buildPayload = () => ({
  erp_setting: {
    host: state.host,
    ...(state.api_key ? { api_key: state.api_key } : {}),
    ...(state.api_secret ? { api_secret: state.api_secret } : {}),
  },
});

const handleTest = async () => {
  isTesting.value = true;
  testResult.value = null;
  try {
    const { data } = await WijayaErpSettingsAPI.test(buildPayload());
    testResult.value = data.ok
      ? { success: true, message: t('WIJAYA_ERP_SETTINGS.TEST.SUCCESS') }
      : {
          success: false,
          message: t('WIJAYA_ERP_SETTINGS.TEST.ERROR', { error: data.error }),
        };
  } catch (error) {
    testResult.value = {
      success: false,
      message: t('WIJAYA_ERP_SETTINGS.TEST.ERROR', {
        error: parseAPIErrorResponse(error),
      }),
    };
  } finally {
    isTesting.value = false;
  }
};

const handleSave = async () => {
  isSaving.value = true;
  try {
    const { data } = await WijayaErpSettingsAPI.update(buildPayload());
    applyResponse(data);
    useAlert(t('WIJAYA_ERP_SETTINGS.SAVE.SUCCESS'));
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) || t('WIJAYA_ERP_SETTINGS.SAVE.ERROR')
    );
  } finally {
    isSaving.value = false;
  }
};

onMounted(fetchSettings);
</script>

<template>
  <SettingsLayout
    :is-loading="isFetching"
    :loading-message="$t('WIJAYA_ERP_SETTINGS.LOADING')"
  >
    <template #header>
      <BaseSettingsHeader
        :title="$t('WIJAYA_ERP_SETTINGS.TITLE')"
        :description="$t('WIJAYA_ERP_SETTINGS.DESCRIPTION')"
      />
    </template>
    <template #body>
      <div class="flex flex-col gap-6 max-w-2xl">
        <Input
          v-model="state.host"
          :label="$t('WIJAYA_ERP_SETTINGS.HOST.LABEL')"
          :placeholder="$t('WIJAYA_ERP_SETTINGS.HOST.PLACEHOLDER')"
          :message="$t('WIJAYA_ERP_SETTINGS.HOST.HINT')"
          message-type="info"
        />

        <div class="flex flex-col gap-1">
          <label class="mb-0.5 text-sm font-medium text-n-slate-12">
            {{ $t('WIJAYA_ERP_SETTINGS.API_KEY.LABEL') }}
          </label>
          <div
            v-if="meta.api_key_present && !isEditingApiKey"
            class="flex items-center justify-between gap-3 rounded-lg border border-n-weak px-3 py-2"
          >
            <span class="text-sm text-n-slate-11">
              {{ apiKeySourceLabel }}
            </span>
            <Button
              sm
              variant="faded"
              color="slate"
              :label="$t('WIJAYA_ERP_SETTINGS.API_KEY.CHANGE')"
              @click="startEditingApiKey"
            />
          </div>
          <div v-else class="flex items-center gap-2">
            <Input
              v-model="state.api_key"
              type="password"
              autocomplete="off"
              :placeholder="$t('WIJAYA_ERP_SETTINGS.API_KEY.PLACEHOLDER')"
              class="flex-1"
            />
            <Button
              v-if="meta.api_key_present"
              sm
              variant="faded"
              color="slate"
              :label="$t('WIJAYA_ERP_SETTINGS.API_KEY.CANCEL')"
              @click="cancelEditingApiKey"
            />
          </div>
          <p class="text-xs text-n-slate-11">
            {{ $t('WIJAYA_ERP_SETTINGS.API_KEY.HINT') }}
          </p>
        </div>

        <div class="flex flex-col gap-1">
          <label class="mb-0.5 text-sm font-medium text-n-slate-12">
            {{ $t('WIJAYA_ERP_SETTINGS.API_SECRET.LABEL') }}
          </label>
          <div
            v-if="meta.api_secret_present && !isEditingApiSecret"
            class="flex items-center justify-between gap-3 rounded-lg border border-n-weak px-3 py-2"
          >
            <span class="text-sm text-n-slate-11">
              {{ apiSecretSourceLabel }}
            </span>
            <Button
              sm
              variant="faded"
              color="slate"
              :label="$t('WIJAYA_ERP_SETTINGS.API_SECRET.CHANGE')"
              @click="startEditingApiSecret"
            />
          </div>
          <div v-else class="flex items-center gap-2">
            <Input
              v-model="state.api_secret"
              type="password"
              autocomplete="off"
              :placeholder="$t('WIJAYA_ERP_SETTINGS.API_SECRET.PLACEHOLDER')"
              class="flex-1"
            />
            <Button
              v-if="meta.api_secret_present"
              sm
              variant="faded"
              color="slate"
              :label="$t('WIJAYA_ERP_SETTINGS.API_SECRET.CANCEL')"
              @click="cancelEditingApiSecret"
            />
          </div>
          <p class="text-xs text-n-slate-11">
            {{ $t('WIJAYA_ERP_SETTINGS.API_SECRET.HINT') }}
          </p>
        </div>

        <div class="flex flex-col gap-2">
          <div class="flex items-center gap-3">
            <Button
              variant="faded"
              color="slate"
              icon="i-lucide-plug-zap"
              :label="
                isTesting
                  ? $t('WIJAYA_ERP_SETTINGS.TEST.TESTING')
                  : $t('WIJAYA_ERP_SETTINGS.TEST.BUTTON')
              "
              :is-loading="isTesting"
              :disabled="isTesting || isSaving"
              @click="handleTest"
            />
            <Button
              icon="i-lucide-save"
              :label="
                isSaving
                  ? $t('WIJAYA_ERP_SETTINGS.SAVE.SAVING')
                  : $t('WIJAYA_ERP_SETTINGS.SAVE.BUTTON')
              "
              :is-loading="isSaving"
              :disabled="isSaving || isTesting"
              @click="handleSave"
            />
          </div>
          <div
            v-if="testResult"
            class="flex items-center gap-2 px-3 py-2 text-xs rounded-lg"
            :class="
              testResult.success
                ? 'bg-n-teal-2 text-n-teal-11'
                : 'bg-n-ruby-2 text-n-ruby-11'
            "
          >
            <span
              :class="
                testResult.success
                  ? 'i-lucide-check-circle'
                  : 'i-lucide-x-circle'
              "
              class="size-3.5 shrink-0"
            />
            {{ testResult.message }}
          </div>
        </div>
      </div>
    </template>
  </SettingsLayout>
</template>
