<script setup>
import { onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import MarineLLMSettingsAPI from '@wijaya/marine_ai/frontend/api/llmSettings';

import MarinePageShell from '../components/MarinePageShell.vue';
import LlmProviderCard from './LlmProviderCard.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const { t } = useI18n();

const isFetching = ref(false);
const isSaving = ref(false);
const availableProviders = ref([]);

// One reactive block per model. `masked`/`present` mirror the backend view; the
// two blocks are fully independent so each card edits its own credentials.
const createCard = () =>
  reactive({
    provider: 'openai',
    model: '',
    endpoint: '',
    api_key: '',
    api_mode: 'chat_completions',
    masked: null,
    present: false,
    inherited: false,
    testing: false,
    testResult: null,
  });

const decision = createCard();
const response = createCard();

const applyCard = (card, data = {}) => {
  card.provider = data.provider || 'openai';
  card.model = data.model || '';
  card.endpoint = data.api_endpoint || '';
  card.api_key = '';
  card.api_mode = data.api_mode || 'chat_completions';
  card.masked = data.api_key_masked;
  card.present = data.api_key_present;
  card.inherited = data.api_key_inherited || false;
};

const applyResponse = data => {
  availableProviders.value = data.available_providers || [];
  applyCard(decision, data.decision_maker_config);
  applyCard(response, data.response_generator_config);
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

// The API mode is a Decision Maker concept only; the Response Generator is fixed
// to chat completions and never sends a mode.
const buildCardPayload = (card, { includeMode = false } = {}) => ({
  provider: card.provider,
  model: card.model,
  api_endpoint: card.endpoint,
  ...(includeMode ? { api_mode: card.api_mode } : {}),
  ...(card.api_key ? { api_key: card.api_key } : {}),
});

const handleTest = async (target, card) => {
  card.testing = true;
  card.testResult = null;
  try {
    const { data } = await MarineLLMSettingsAPI.test({
      target,
      config: buildCardPayload(card, {
        includeMode: target === 'decision_maker',
      }),
    });
    card.testResult = data.ok
      ? { success: true, message: t('MARINE_AI.LLM_SETTINGS.TEST.SUCCESS') }
      : {
          success: false,
          message: t('MARINE_AI.LLM_SETTINGS.TEST.ERROR', {
            error: data.error,
          }),
        };
  } catch (error) {
    card.testResult = {
      success: false,
      message: t('MARINE_AI.LLM_SETTINGS.TEST.ERROR', {
        error: parseAPIErrorResponse(error),
      }),
    };
  } finally {
    card.testing = false;
  }
};

const handleSave = async () => {
  isSaving.value = true;
  try {
    const { data } = await MarineLLMSettingsAPI.update({
      decision_maker_config: buildCardPayload(decision, { includeMode: true }),
      response_generator_config: buildCardPayload(response),
    });
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

    <div v-else class="flex flex-col gap-4">
      <div class="grid gap-4 lg:grid-cols-2 items-start">
        <LlmProviderCard
          :title="t('MARINE_AI.LLM_SETTINGS.DECISION_MAKER.TITLE')"
          :subtitle="t('MARINE_AI.LLM_SETTINGS.DECISION_MAKER.SUBTITLE')"
          :config="decision"
          :providers="availableProviders"
          :api-key-masked="decision.masked"
          :api-key-present="decision.present"
          :api-key-inherited="decision.inherited"
          :model-placeholder="
            t('MARINE_AI.LLM_SETTINGS.DECISION_MAKER.MODEL_PLACEHOLDER')
          "
          show-api-mode
          :is-testing="decision.testing"
          :is-busy="decision.testing || isSaving"
          :test-result="decision.testResult"
          @update:provider="value => (decision.provider = value)"
          @update:model="value => (decision.model = value)"
          @update:endpoint="value => (decision.endpoint = value)"
          @update:api-key="value => (decision.api_key = value)"
          @update:api-mode="value => (decision.api_mode = value)"
          @test="handleTest('decision_maker', decision)"
        />
        <LlmProviderCard
          :title="t('MARINE_AI.LLM_SETTINGS.RESPONSE_GENERATOR.TITLE')"
          :subtitle="t('MARINE_AI.LLM_SETTINGS.RESPONSE_GENERATOR.SUBTITLE')"
          :config="response"
          :providers="availableProviders"
          :api-key-masked="response.masked"
          :api-key-present="response.present"
          :is-testing="response.testing"
          :is-busy="response.testing || isSaving"
          :test-result="response.testResult"
          @update:provider="value => (response.provider = value)"
          @update:model="value => (response.model = value)"
          @update:endpoint="value => (response.endpoint = value)"
          @update:api-key="value => (response.api_key = value)"
          @test="handleTest('response_generator', response)"
        />
      </div>

      <div class="flex items-center">
        <Button
          icon="i-lucide-save"
          :label="
            isSaving
              ? t('MARINE_AI.LLM_SETTINGS.SAVE.SAVING')
              : t('MARINE_AI.LLM_SETTINGS.SAVE.BUTTON')
          "
          :is-loading="isSaving"
          :disabled="isSaving || decision.testing || response.testing"
          @click="handleSave"
        />
      </div>
    </div>
  </MarinePageShell>
</template>
