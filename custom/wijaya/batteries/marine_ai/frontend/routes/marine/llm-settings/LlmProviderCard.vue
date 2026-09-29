<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';

import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';

const props = defineProps({
  title: { type: String, required: true },
  subtitle: { type: String, required: true },
  config: { type: Object, required: true },
  providers: { type: Array, default: () => [] },
  apiKeyMasked: { type: String, default: null },
  apiKeyPresent: { type: Boolean, default: false },
  apiKeyInherited: { type: Boolean, default: false },
  modelPlaceholder: { type: String, default: '' },
  isTesting: { type: Boolean, default: false },
  isBusy: { type: Boolean, default: false },
  testResult: { type: Object, default: null },
});

const emit = defineEmits([
  'update:provider',
  'update:model',
  'update:endpoint',
  'update:apiKey',
  'test',
]);

const { t } = useI18n();

const isEditingApiKey = ref(!props.apiKeyPresent);

// After a save/fetch the parent refreshes presence; collapse back to the masked
// display whenever a key is now stored.
watch(
  () => props.apiKeyPresent,
  present => {
    isEditingApiKey.value = !present;
  }
);

const providerOptions = computed(() =>
  props.providers.map(provider => ({
    value: provider.value,
    label: provider.label,
  }))
);

const currentProviderInfo = computed(
  () => props.providers.find(p => p.value === props.config.provider) || {}
);

const resolvedModelPlaceholder = computed(
  () =>
    currentProviderInfo.value.default_model ||
    props.modelPlaceholder ||
    t('MARINE_AI.LLM_SETTINGS.MODEL.PLACEHOLDER')
);

const endpointPlaceholder = computed(
  () =>
    currentProviderInfo.value.default_endpoint ||
    t('MARINE_AI.LLM_SETTINGS.ENDPOINT.PLACEHOLDER')
);

const handleProviderChange = value => {
  const previous = props.providers.find(p => p.value === props.config.provider);
  const next = props.providers.find(p => p.value === value);
  emit('update:provider', value);
  if (!next) return;

  // Only auto-fill defaults when the field is empty or still on the previous
  // provider's default, so a customized value is never clobbered.
  if (!props.config.model || props.config.model === previous?.default_model) {
    emit('update:model', next.default_model || '');
  }
  if (
    !props.config.endpoint ||
    props.config.endpoint === previous?.default_endpoint
  ) {
    emit('update:endpoint', next.default_endpoint || '');
  }
};

const startEditingApiKey = () => {
  isEditingApiKey.value = true;
  emit('update:apiKey', '');
};

const cancelEditingApiKey = () => {
  isEditingApiKey.value = false;
  emit('update:apiKey', '');
};
</script>

<template>
  <section
    class="flex flex-col gap-4 rounded-xl border border-n-weak bg-n-solid-1 p-4"
  >
    <div class="flex flex-col gap-1">
      <h3 class="text-sm font-medium text-n-slate-12">{{ title }}</h3>
      <p class="text-xs text-n-slate-11">{{ subtitle }}</p>
    </div>

    <div class="flex flex-col gap-1">
      <label class="mb-0.5 text-sm font-medium text-n-slate-12">
        {{ t('MARINE_AI.LLM_SETTINGS.PROVIDER.LABEL') }}
      </label>
      <ComboBox
        :model-value="config.provider"
        :options="providerOptions"
        :placeholder="t('MARINE_AI.LLM_SETTINGS.PROVIDER.PLACEHOLDER')"
        class="[&>div>button]:bg-n-alpha-black2"
        @update:model-value="handleProviderChange"
      />
    </div>

    <Input
      :model-value="config.model"
      :label="t('MARINE_AI.LLM_SETTINGS.MODEL.LABEL')"
      :placeholder="resolvedModelPlaceholder"
      @update:model-value="value => emit('update:model', value)"
    />

    <Input
      :model-value="config.endpoint"
      :label="t('MARINE_AI.LLM_SETTINGS.ENDPOINT.LABEL')"
      :placeholder="endpointPlaceholder"
      :message="t('MARINE_AI.LLM_SETTINGS.ENDPOINT.HINT')"
      message-type="info"
      @update:model-value="value => emit('update:endpoint', value)"
    />

    <div class="flex flex-col gap-1">
      <label class="mb-0.5 text-sm font-medium text-n-slate-12">
        {{ t('MARINE_AI.LLM_SETTINGS.API_KEY.LABEL') }}
      </label>
      <div
        v-if="apiKeyPresent && !isEditingApiKey"
        class="flex items-center justify-between gap-3 rounded-lg border border-n-weak px-3 py-2"
      >
        <span class="font-mono text-sm text-n-slate-12">{{
          apiKeyMasked
        }}</span>
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
          :model-value="config.api_key"
          type="password"
          autocomplete="off"
          :placeholder="t('MARINE_AI.LLM_SETTINGS.API_KEY.PLACEHOLDER')"
          class="flex-1"
          @update:model-value="value => emit('update:apiKey', value)"
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
      <p
        v-if="apiKeyPresent && apiKeyInherited && !isEditingApiKey"
        class="text-xs text-n-amber-11"
      >
        {{ t('MARINE_AI.LLM_SETTINGS.API_KEY.INHERITED') }}
      </p>
      <p class="text-xs text-n-slate-11">
        {{ t('MARINE_AI.LLM_SETTINGS.API_KEY.HINT') }}
      </p>
    </div>

    <div class="flex flex-col gap-2">
      <Button
        variant="faded"
        color="slate"
        icon="i-lucide-plug-zap"
        class="self-start"
        :label="
          isTesting
            ? t('MARINE_AI.LLM_SETTINGS.TEST.TESTING')
            : t('MARINE_AI.LLM_SETTINGS.TEST.BUTTON')
        "
        :is-loading="isTesting"
        :disabled="isBusy"
        @click="emit('test')"
      />
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
  </section>
</template>
