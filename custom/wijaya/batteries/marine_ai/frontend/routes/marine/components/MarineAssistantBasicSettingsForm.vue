<script setup>
import { reactive, computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import {
  required,
  minLength,
  minValue,
  maxValue,
  integer,
} from '@vuelidate/validators';

import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Editor from 'dashboard/components-next/Editor/Editor.vue';

const props = defineProps({
  assistant: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['submit']);

const { t } = useI18n();

const initialState = {
  name: '',
  description: '',
  productName: '',
  memoryIdleTimeoutHours: 2,
  features: {
    conversationFaqs: false,
    memories: false,
    contactAttributes: false,
  },
};

const state = reactive({ ...initialState });

const validationRules = {
  name: { required, minLength: minLength(1) },
  description: { required, minLength: minLength(1) },
  productName: { required, minLength: minLength(1) },
  memoryIdleTimeoutHours: {
    required,
    integer,
    minValue: minValue(1),
    maxValue: maxValue(24),
  },
};

const v$ = useVuelidate(validationRules, state);

const getErrorMessage = field => {
  return v$.value[field].$error ? v$.value[field].$errors[0].$message : '';
};

const formErrors = computed(() => ({
  name: getErrorMessage('name'),
  description: getErrorMessage('description'),
  productName: getErrorMessage('productName'),
  memoryIdleTimeoutHours: getErrorMessage('memoryIdleTimeoutHours'),
}));

const updateStateFromAssistant = assistant => {
  const { config = {} } = assistant;
  state.name = assistant.name;
  state.description = assistant.description;
  state.productName = config.product_name;
  const timeout = Number(config.memory_idle_timeout_hours);
  state.memoryIdleTimeoutHours =
    Number.isInteger(timeout) && timeout >= 1 && timeout <= 24 ? timeout : 2;
  state.features = {
    conversationFaqs: config.feature_faq || false,
    memories: config.feature_memory || false,
    contactAttributes: config.feature_contact_attributes || false,
  };
};

const handleBasicInfoUpdate = async () => {
  const result = await Promise.all([
    v$.value.name.$validate(),
    v$.value.description.$validate(),
    v$.value.productName.$validate(),
    v$.value.memoryIdleTimeoutHours.$validate(),
  ]).then(results => results.every(Boolean));
  if (!result) return;

  const payload = {
    name: state.name,
    description: state.description,
    config: {
      ...props.assistant.config,
      product_name: state.productName,
      feature_faq: state.features.conversationFaqs,
      feature_memory: state.features.memories,
      feature_contact_attributes: state.features.contactAttributes,
      memory_idle_timeout_hours: Number(state.memoryIdleTimeoutHours),
    },
  };

  emit('submit', payload);
};

watch(
  () => props.assistant,
  newAssistant => {
    if (newAssistant) updateStateFromAssistant(newAssistant);
  },
  { immediate: true }
);
</script>

<template>
  <div class="flex flex-col gap-6">
    <Input
      v-model="state.name"
      :label="t('MARINE_AI.ASSISTANTS.FORM.NAME.LABEL')"
      :placeholder="t('MARINE_AI.ASSISTANTS.FORM.NAME.PLACEHOLDER')"
      :message="formErrors.name"
      :message-type="formErrors.name ? 'error' : 'info'"
    />

    <Input
      v-model="state.productName"
      :label="t('MARINE_AI.ASSISTANTS.FORM.PRODUCT_NAME.LABEL')"
      :placeholder="t('MARINE_AI.ASSISTANTS.FORM.PRODUCT_NAME.PLACEHOLDER')"
      :message="formErrors.productName"
      :message-type="formErrors.productName ? 'error' : 'info'"
    />

    <Editor
      v-model="state.description"
      :label="t('MARINE_AI.ASSISTANTS.FORM.DESCRIPTION.LABEL')"
      :placeholder="t('MARINE_AI.ASSISTANTS.FORM.DESCRIPTION.PLACEHOLDER')"
      :message="formErrors.description"
      :message-type="formErrors.description ? 'error' : 'info'"
      class="z-0"
    />

    <Input
      v-model="state.memoryIdleTimeoutHours"
      type="number"
      min="1"
      max="24"
      :label="t('MARINE_AI.ASSISTANTS.FORM.MEMORY_IDLE_TIMEOUT.LABEL')"
      :placeholder="
        t('MARINE_AI.ASSISTANTS.FORM.MEMORY_IDLE_TIMEOUT.PLACEHOLDER')
      "
      :message="
        formErrors.memoryIdleTimeoutHours ||
        t('MARINE_AI.ASSISTANTS.FORM.MEMORY_IDLE_TIMEOUT.HELP')
      "
      :message-type="formErrors.memoryIdleTimeoutHours ? 'error' : 'info'"
    />

    <div class="flex flex-col gap-2">
      <label class="text-sm font-medium text-n-slate-12">
        {{ t('MARINE_AI.ASSISTANTS.FORM.FEATURES.TITLE') }}
      </label>
      <div class="flex flex-col gap-2">
        <label class="flex items-center gap-2">
          <input v-model="state.features.conversationFaqs" type="checkbox" />
          {{ t('MARINE_AI.ASSISTANTS.FORM.FEATURES.ALLOW_CONVERSATION_FAQS') }}
        </label>
        <label class="flex items-center gap-2">
          <input v-model="state.features.memories" type="checkbox" />
          {{ t('MARINE_AI.ASSISTANTS.FORM.FEATURES.ALLOW_MEMORIES') }}
        </label>
        <label class="flex items-center gap-2">
          <input v-model="state.features.contactAttributes" type="checkbox" />
          {{ t('MARINE_AI.ASSISTANTS.FORM.FEATURES.ALLOW_CONTACT_ATTRIBUTES') }}
        </label>
      </div>
    </div>

    <div>
      <Button
        :label="t('MARINE_AI.ASSISTANTS.FORM.UPDATE')"
        @click="handleBasicInfoUpdate"
      />
    </div>
  </div>
</template>
