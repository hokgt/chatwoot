<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import MarineAssistantAPI from 'dashboard/api/marine/assistant';
import MarinePreferencesAPI from 'dashboard/api/marine/preferences';
import { useMarineAssistants } from '../composables/useMarineAssistants';

import Button from 'dashboard/components-next/button/Button.vue';
import MarinePageLayout from '../components/MarinePageLayout.vue';
import MarineSettingsHeader from '../components/MarineSettingsHeader.vue';
import MarineAssistantBasicSettingsForm from '../components/MarineAssistantBasicSettingsForm.vue';
import MarineAssistantSystemSettingsForm from '../components/MarineAssistantSystemSettingsForm.vue';
import MarineAssistantControlItems from '../components/MarineAssistantControlItems.vue';
import MarineDeleteDialog from '../components/MarineDeleteDialog.vue';
// WIJAYA_CUSTOM_START marine_ai_provisioning
import MarineProvisioningSection from '../../../../../../../custom/wijaya/batteries/marine_ai/frontend/MarineProvisioningSection.vue';
// WIJAYA_CUSTOM_END marine_ai_provisioning

const { t } = useI18n();
const route = useRoute();
const router = useRouter();

const { assistants, fetchAssistants } = useMarineAssistants();

const assistant = ref(null);
const isFetching = ref(false);
const deleteAssistantDialog = ref(null);
const preferences = ref({
  enabled: true,
  hub: 'local',
  remote_hub: false,
  account_id: null,
  default_model: null,
  models: {},
  features: {},
});

const assistantId = computed(() => Number(route.params.assistantId));

const yesNo = value =>
  value ? t('MARINE_AI.SETTINGS.ENABLED') : t('MARINE_AI.SETTINGS.DISABLED');

const statusRows = computed(() => {
  const features = preferences.value.features || {};
  return [
    {
      key: 'status',
      label: t('MARINE_AI.SETTINGS.STATUS'),
      value: yesNo(preferences.value.enabled),
    },
    {
      key: 'hub',
      label: t('MARINE_AI.SETTINGS.HUB'),
      value: t('MARINE_AI.SETTINGS.HUB_LOCAL'),
    },
    {
      key: 'account',
      label: t('MARINE_AI.SETTINGS.ACCOUNT'),
      value: preferences.value.account_id ?? t('MARINE_AI.SETTINGS.NONE'),
    },
    {
      key: 'model',
      label: t('MARINE_AI.SETTINGS.DEFAULT_MODEL'),
      value: preferences.value.default_model || t('MARINE_AI.SETTINGS.NONE'),
    },
    {
      key: 'assistant',
      label: t('MARINE_AI.SETTINGS.FEATURE_ASSISTANT'),
      value: yesNo(features.assistant),
    },
    {
      key: 'knowledge_base',
      label: t('MARINE_AI.SETTINGS.FEATURE_KNOWLEDGE_BASE'),
      value: yesNo(features.knowledge_base),
    },
    {
      key: 'handoff',
      label: t('MARINE_AI.SETTINGS.FEATURE_HANDOFF'),
      value: yesNo(features.handoff),
    },
  ];
});

const controlItems = computed(() => [
  {
    name: t('MARINE_AI.SETTINGS.CONTROL_ITEMS.OPTIONS.GUARDRAILS.TITLE'),
    description: t(
      'MARINE_AI.SETTINGS.CONTROL_ITEMS.OPTIONS.GUARDRAILS.DESCRIPTION'
    ),
    routeName: 'marine_assistants_guardrails_index',
  },
  {
    name: t(
      'MARINE_AI.SETTINGS.CONTROL_ITEMS.OPTIONS.RESPONSE_GUIDELINES.TITLE'
    ),
    description: t(
      'MARINE_AI.SETTINGS.CONTROL_ITEMS.OPTIONS.RESPONSE_GUIDELINES.DESCRIPTION'
    ),
    routeName: 'marine_assistants_guidelines_index',
  },
]);

const fetchAssistant = async () => {
  if (!assistantId.value) return;
  isFetching.value = true;
  try {
    const { data } = await MarineAssistantAPI.show(assistantId.value);
    assistant.value = data;
  } finally {
    isFetching.value = false;
  }
};

const fetchPreferences = async () => {
  const { data } = await MarinePreferencesAPI.get();
  if (data) {
    preferences.value = { ...preferences.value, ...data };
  }
};

const handleSubmit = async updatedAssistant => {
  try {
    await MarineAssistantAPI.update(assistantId.value, {
      assistant: updatedAssistant,
    });
    useAlert(t('MARINE_AI.ASSISTANTS.EDIT.SUCCESS_MESSAGE'));
    await fetchAssistant();
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) ||
        t('MARINE_AI.ASSISTANTS.EDIT.ERROR_MESSAGE')
    );
  }
};

const handleDelete = () => {
  deleteAssistantDialog.value.dialogRef.open();
};

const handleDeleteSuccess = async () => {
  await fetchAssistants();
  const remainingAssistants = assistants.value.filter(
    a => a.id !== assistantId.value
  );

  if (remainingAssistants.length > 0) {
    router.push({
      name: 'marine_assistants_settings_index',
      params: {
        accountId: route.params.accountId,
        assistantId: remainingAssistants[0].id,
      },
    });
  } else {
    router.push({
      name: 'marine_assistants_create_index',
      params: { accountId: route.params.accountId },
    });
  }
};

watch(assistantId, fetchAssistant);

onMounted(() => {
  fetchAssistant();
  fetchPreferences();
});
</script>

<template>
  <MarinePageLayout
    :is-fetching="isFetching"
    :show-pagination-footer="false"
    :show-know-more="false"
  >
    <template #body>
      <div class="gap-6 lg:gap-16 pb-8 grid grid-cols-2">
        <div class="flex flex-col gap-6">
          <div class="flex flex-col gap-6">
            <MarineSettingsHeader
              :heading="t('MARINE_AI.SETTINGS.BASIC_SETTINGS.TITLE')"
              :description="t('MARINE_AI.SETTINGS.BASIC_SETTINGS.DESCRIPTION')"
            />
            <MarineAssistantBasicSettingsForm
              :assistant="assistant"
              @submit="handleSubmit"
            />
          </div>
          <span class="h-px w-full bg-n-weak mt-2" />
          <div class="flex flex-col gap-6">
            <MarineSettingsHeader
              :heading="t('MARINE_AI.SETTINGS.SYSTEM_SETTINGS.TITLE')"
              :description="t('MARINE_AI.SETTINGS.SYSTEM_SETTINGS.DESCRIPTION')"
            />
            <MarineAssistantSystemSettingsForm
              :assistant="assistant"
              @submit="handleSubmit"
            />
          </div>
          <span class="h-px w-full bg-n-weak mt-2" />
          <div class="flex items-end justify-between w-full gap-4">
            <div class="flex flex-col gap-2">
              <h6 class="text-n-slate-12 text-base font-medium">
                {{ t('MARINE_AI.SETTINGS.DELETE.TITLE') }}
              </h6>
              <span class="text-n-slate-11 text-sm">
                {{ t('MARINE_AI.SETTINGS.DELETE.DESCRIPTION') }}
              </span>
            </div>
            <div class="flex-shrink-0">
              <Button
                :label="
                  t('MARINE_AI.SETTINGS.DELETE.BUTTON_TEXT', {
                    assistantName: assistant?.name,
                  })
                "
                color="ruby"
                class="max-w-56 !w-fit"
                @click="handleDelete"
              />
            </div>
          </div>
        </div>
        <div class="flex flex-col gap-6">
          <div class="flex flex-col gap-6">
            <MarineSettingsHeader
              :heading="t('MARINE_AI.SETTINGS.CONTROL_ITEMS.TITLE')"
              :description="t('MARINE_AI.SETTINGS.CONTROL_ITEMS.DESCRIPTION')"
            />
            <div class="flex flex-col gap-6">
              <MarineAssistantControlItems
                v-for="item in controlItems"
                :key="item.name"
                :control-item="item"
              />
            </div>
          </div>
          <span class="h-px w-full bg-n-weak mt-2" />
          <div class="flex flex-col gap-6">
            <MarineSettingsHeader
              :heading="t('MARINE_AI.SETTINGS.STATUS_TITLE')"
              :description="t('MARINE_AI.SETTINGS.STATUS_HINT')"
            />
            <dl class="mt-3 grid gap-2 text-sm sm:grid-cols-2">
              <div
                v-for="row in statusRows"
                :key="row.key"
                class="flex items-center justify-between gap-3 rounded-lg border border-n-weak px-3 py-2"
              >
                <dt class="text-n-slate-11">{{ row.label }}</dt>
                <dd class="font-medium text-n-slate-12">{{ row.value }}</dd>
              </div>
            </dl>
          </div>
        </div>
      </div>
      <!-- WIJAYA_CUSTOM_START marine_ai_provisioning -->
      <span class="h-px w-full bg-n-weak" />
      <div class="pb-8 pt-6">
        <MarineProvisioningSection />
      </div>
      <!-- WIJAYA_CUSTOM_END marine_ai_provisioning -->
    </template>
    <MarineDeleteDialog
      v-if="assistant"
      ref="deleteAssistantDialog"
      :entity="assistant"
      :title="t('MARINE_AI.ASSISTANTS.DELETE.TITLE')"
      :description="t('MARINE_AI.ASSISTANTS.DELETE.DESCRIPTION')"
      :confirm-button-label="t('MARINE_AI.ASSISTANTS.DELETE.CONFIRM')"
      :success-message="t('MARINE_AI.ASSISTANTS.DELETE.SUCCESS_MESSAGE')"
      :error-message="t('MARINE_AI.ASSISTANTS.DELETE.ERROR_MESSAGE')"
      @delete-success="handleDeleteSuccess"
    />
  </MarinePageLayout>
</template>
