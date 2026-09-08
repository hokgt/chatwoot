<script setup>
import { computed, onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import MarineLLMSettingsAPI from '@wijaya/marine_ai/frontend/api/llmSettings';

import MarinePageShell from '../components/MarinePageShell.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';

const { t } = useI18n();

const isFetching = ref(false);
const isSaving = ref(false);
const isTesting = ref(false);
const testResult = ref(null);

const availableProviders = ref([]);
const apiKeyMasked = ref(null);
const apiKeyPresent = ref(false);
const isEditingApiKey = ref(false);

const state = reactive({
  provider: 'openai',
  model: '',
  endpoint: '',
  api_key: '',
  embedding_model: '',
});

const providerOptions = computed(() =>
  availableProviders.value.map(provider => ({
    value: provider.value,
    label: provider.label,
  }))
);

const currentProviderInfo = computed(
  () =>
    availableProviders.value.find(
      provider => provider.value === state.provider
    ) || {}
);

const supportsEmbeddings = computed(
  () => currentProviderInfo.value.supports_embeddings ?? true
);

const endpointPlaceholder = computed(
  () =>
    currentProviderInfo.value.default_endpoint ||
    t('MARINE_AI.LLM_SETTINGS.ENDPOINT.PLACEHOLDER')
);

const modelPlaceholder = computed(
  () =>
    currentProviderInfo.value.default_model ||
    t('MARINE_AI.LLM_SETTINGS.MODEL.PLACEHOLDER')
);

const applyResponse = data => {
  availableProviders.value = data.available_providers || [];
  state.provider = data.provider;
  state.model = data.model || '';
  state.endpoint = data.endpoint || '';
  state.embedding_model = data.embedding_model || '';
  state.api_key = '';
  apiKeyMasked.value = data.api_key_masked;
  apiKeyPresent.value = data.api_key_present;
  isEditingApiKey.value = !data.api_key_present;
};

const fetchSettings = async () => {
  isFetching.value = true;
  try {
    const { data } = await MarineLLMSettingsAPI.get();
    applyResponse(data);
  } finally {
    isFetching.value = false;
  }
};

const handleProviderChange = value => {
  const previous = availableProviders.value.find(
    provider => provider.value === state.provider
  );
  const next = availableProviders.value.find(
    provider => provider.value === value
  );
  state.provider = value;
  if (!next) return;

  // Only auto-fill defaults when the user hasn't customized away from the
  // previous provider's defaults.
  if (!state.model || state.model === previous?.default_model) {
    state.model = next.default_model || '';
  }
  if (!state.endpoint || state.endpoint === previous?.default_endpoint) {
    state.endpoint = next.default_endpoint || '';
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

const buildPayload = () => ({
  provider: state.provider,
  model: state.model,
  endpoint: state.endpoint,
  embedding_model: supportsEmbeddings.value ? state.embedding_model : '',
  ...(state.api_key ? { api_key: state.api_key } : {}),
});

const handleTest = async () => {
  isTesting.value = true;
  testResult.value = null;
  try {
    const { data } = await MarineLLMSettingsAPI.test(buildPayload());
    testResult.value = data.ok
      ? { success: true, message: t('MARINE_AI.LLM_SETTINGS.TEST.SUCCESS') }
      : {
          success: false,
          message: t('MARINE_AI.LLM_SETTINGS.TEST.ERROR', {
            error: data.error,
          }),
        };
  } catch (error) {
    testResult.value = {
      success: false,
      message: t('MARINE_AI.LLM_SETTINGS.TEST.ERROR', {
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
    const { data } = await MarineLLMSettingsAPI.update(buildPayload());
    applyResponse(data);
    useAlert(t('MARINE_AI.LLM_SETTINGS.SAVE.SUCCESS'));
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) || t('MARINE_AI.LLM_SETTINGS.SAVE.ERROR')
    );
  } finally {
    isSaving.value = false;
  }
};

onMounted(fetchSettings);
</script>

<template>
  <MarinePageShell
    :title="t('MARINE_AI.LLM_SETTINGS.TITLE')"
    :description="t('MARINE_AI.LLM_SETTINGS.DESCRIPTION')"
  >
    <div
      v-if="isFetching"
      class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
    >
      <p class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.SETTINGS.LOADING') }}
      </p>
    </div>

    <div v-else class="flex flex-col gap-6 max-w-2xl">
      <div class="flex flex-col gap-1">
        <label class="mb-0.5 text-sm font-medium text-n-slate-12">
          {{ t('MARINE_AI.LLM_SETTINGS.PROVIDER.LABEL') }}
        </label>
        <ComboBox
          :model-value="state.provider"
          :options="providerOptions"
          :placeholder="t('MARINE_AI.LLM_SETTINGS.PROVIDER.PLACEHOLDER')"
          class="[&>div>button]:bg-n-alpha-black2"
          @update:model-value="handleProviderChange"
        />
      </div>

      <Input
        v-model="state.model"
        :label="t('MARINE_AI.LLM_SETTINGS.MODEL.LABEL')"
        :placeholder="modelPlaceholder"
      />

      <Input
        v-model="state.endpoint"
        :label="t('MARINE_AI.LLM_SETTINGS.ENDPOINT.LABEL')"
        :placeholder="endpointPlaceholder"
        :message="t('MARINE_AI.LLM_SETTINGS.ENDPOINT.HINT')"
        message-type="info"
      />

      <div class="flex flex-col gap-1">
        <label class="mb-0.5 text-sm font-medium text-n-slate-12">
          {{ t('MARINE_AI.LLM_SETTINGS.API_KEY.LABEL') }}
        </label>
        <div
          v-if="apiKeyPresent && !isEditingApiKey"
          class="flex items-center justify-between gap-3 rounded-lg border border-n-weak px-3 py-2"
        >
          <span class="font-mono text-sm text-n-slate-12">
            {{ apiKeyMasked }}
          </span>
          <Button
            sm
            variant="faded"
            color="slate"
            :label="t('MARINE_AI.LLM_SETTINGS.API_KEY.CHANGE')"
            @click="startEditingApiKey"
          />
        </div>
        <div v-else class="flex items-center gap-2">
          <Input
            v-model="state.api_key"
            type="password"
            autocomplete="off"
            :placeholder="t('MARINE_AI.LLM_SETTINGS.API_KEY.PLACEHOLDER')"
            class="flex-1"
          />
          <Button
            v-if="apiKeyPresent"
            sm
            variant="faded"
            color="slate"
            :label="t('MARINE_AI.LLM_SETTINGS.API_KEY.CANCEL')"
            @click="cancelEditingApiKey"
          />
        </div>
        <p class="text-xs text-n-slate-11">
          {{ t('MARINE_AI.LLM_SETTINGS.API_KEY.HINT') }}
        </p>
      </div>

      <Input
        v-if="supportsEmbeddings"
        v-model="state.embedding_model"
        :label="t('MARINE_AI.LLM_SETTINGS.EMBEDDING_MODEL.LABEL')"
        :placeholder="t('MARINE_AI.LLM_SETTINGS.EMBEDDING_MODEL.PLACEHOLDER')"
        :message="t('MARINE_AI.LLM_SETTINGS.EMBEDDING_MODEL.HINT')"
        message-type="info"
      />
      <p
        v-else
        class="rounded-lg bg-n-alpha-1 px-3 py-2 text-xs text-n-slate-11"
      >
        {{ t('MARINE_AI.LLM_SETTINGS.EMBEDDING_MODEL.NOT_SUPPORTED') }}
      </p>

      <div class="flex flex-col gap-2">
        <div class="flex items-center gap-3">
          <Button
            variant="faded"
            color="slate"
            icon="i-lucide-plug-zap"
            :label="
              isTesting
                ? t('MARINE_AI.LLM_SETTINGS.TEST.TESTING')
                : t('MARINE_AI.LLM_SETTINGS.TEST.BUTTON')
            "
            :is-loading="isTesting"
            :disabled="isTesting || isSaving"
            @click="handleTest"
          />
          <Button
            icon="i-lucide-save"
            :label="
              isSaving
                ? t('MARINE_AI.LLM_SETTINGS.SAVE.SAVING')
                : t('MARINE_AI.LLM_SETTINGS.SAVE.BUTTON')
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
              testResult.success ? 'i-lucide-check-circle' : 'i-lucide-x-circle'
            "
            class="size-3.5 shrink-0"
          />
          {{ testResult.message }}
        </div>
      </div>
    </div>
  </MarinePageShell>
</template>
