<script setup>
import { onMounted, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import MarineScenariosAPI from 'dashboard/api/marine/scenarios';
import { useMarineAssistants } from '../composables/useMarineAssistants';
import MarinePageShell from '../components/MarinePageShell.vue';

const { t } = useI18n();
const { activeAssistantId, fetchAssistants, createDefaultAssistant } =
  useMarineAssistants();

const loading = ref(false);
const saving = ref(false);
const scenarios = ref([]);
const errorMessage = ref('');
const editingId = ref(null);
const confirmingDeleteId = ref(null);

const blankForm = () => ({
  title: '',
  description: '',
  instruction: '',
  enabled: true,
});
const form = reactive(blankForm());

const resetForm = () => {
  Object.assign(form, blankForm());
  editingId.value = null;
  errorMessage.value = '';
};

const fetchScenarios = async () => {
  loading.value = true;
  try {
    await fetchAssistants();
    if (!activeAssistantId.value) {
      scenarios.value = [];
      return;
    }
    const { data } = await MarineScenariosAPI.get({
      assistantId: activeAssistantId.value,
    });
    scenarios.value = data.payload || [];
  } finally {
    loading.value = false;
  }
};

const setupAssistant = async () => {
  saving.value = true;
  try {
    await createDefaultAssistant();
    await fetchScenarios();
  } finally {
    saving.value = false;
  }
};

const startEdit = scenario => {
  editingId.value = scenario.id;
  errorMessage.value = '';
  form.title = scenario.title;
  form.description = scenario.description;
  form.instruction = scenario.instruction;
  form.enabled = scenario.enabled;
};

const saveScenario = async () => {
  if (
    !activeAssistantId.value ||
    !form.title.trim() ||
    !form.instruction.trim()
  )
    return;
  saving.value = true;
  errorMessage.value = '';
  try {
    const payload = {
      assistantId: activeAssistantId.value,
      title: form.title,
      description: form.description,
      instruction: form.instruction,
      enabled: form.enabled,
    };
    if (editingId.value) {
      await MarineScenariosAPI.update({ id: editingId.value, ...payload });
    } else {
      await MarineScenariosAPI.create(payload);
    }
    resetForm();
    await fetchScenarios();
  } catch (error) {
    errorMessage.value =
      error?.response?.data?.message || t('MARINE_AI.SCENARIOS.SAVE_ERROR');
  } finally {
    saving.value = false;
  }
};

const deleteScenario = async scenario => {
  await MarineScenariosAPI.delete({
    assistantId: activeAssistantId.value,
    id: scenario.id,
  });
  confirmingDeleteId.value = null;
  if (editingId.value === scenario.id) resetForm();
  await fetchScenarios();
};

onMounted(fetchScenarios);
</script>

<template>
  <MarinePageShell
    :title="t('MARINE_AI.SCENARIOS.TITLE')"
    :description="t('MARINE_AI.SCENARIOS.DESCRIPTION')"
  >
    <div
      v-if="!activeAssistantId && !loading"
      class="rounded-xl border border-n-weak bg-n-solid-1 p-4 space-y-3"
    >
      <p class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.EMPTY_ASSISTANT.DESCRIPTION') }}
      </p>
      <button
        type="button"
        class="rounded-lg bg-n-brand px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
        :disabled="saving"
        @click="setupAssistant"
      >
        {{ t('MARINE_AI.EMPTY_ASSISTANT.CREATE') }}
      </button>
    </div>
    <div v-else class="space-y-4">
      <form
        class="rounded-xl border border-n-weak bg-n-solid-1 p-4 space-y-3"
        @submit.prevent="saveScenario"
      >
        <h2 class="text-base font-medium text-n-slate-12">
          {{
            editingId
              ? t('MARINE_AI.SCENARIOS.EDIT')
              : t('MARINE_AI.SCENARIOS.ADD')
          }}
        </h2>
        <input
          v-model="form.title"
          class="w-full rounded-lg border border-n-weak bg-n-alpha-black1 p-3 text-sm text-n-slate-12"
          :placeholder="t('MARINE_AI.SCENARIOS.TITLE_LABEL')"
        />
        <input
          v-model="form.description"
          class="w-full rounded-lg border border-n-weak bg-n-alpha-black1 p-3 text-sm text-n-slate-12"
          :placeholder="t('MARINE_AI.SCENARIOS.DESCRIPTION_LABEL')"
        />
        <textarea
          v-model="form.instruction"
          rows="5"
          class="w-full rounded-lg border border-n-weak bg-n-alpha-black1 p-3 text-sm text-n-slate-12"
          :placeholder="t('MARINE_AI.SCENARIOS.INSTRUCTION_LABEL')"
        />
        <label class="flex items-center gap-2 text-sm text-n-slate-11">
          <input v-model="form.enabled" type="checkbox" />
          {{ t('MARINE_AI.SCENARIOS.ENABLED_LABEL') }}
        </label>
        <p v-if="errorMessage" class="text-sm text-n-ruby-11">
          {{ errorMessage }}
        </p>
        <div class="flex gap-2">
          <button
            type="submit"
            class="rounded-lg bg-n-brand px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
            :disabled="saving || !form.title.trim() || !form.instruction.trim()"
          >
            {{ saving ? t('MARINE_AI.SAVING') : t('MARINE_AI.SCENARIOS.SAVE') }}
          </button>
          <button
            v-if="editingId"
            type="button"
            class="rounded-lg border border-n-weak px-4 py-2 text-sm font-medium text-n-slate-12"
            @click="resetForm"
          >
            {{ t('MARINE_AI.SCENARIOS.CANCEL') }}
          </button>
        </div>
      </form>

      <div class="rounded-xl border border-n-weak bg-n-solid-1 p-4">
        <p v-if="loading" class="text-sm text-n-slate-11">
          {{ t('MARINE_AI.SCENARIOS.LOADING') }}
        </p>
        <p v-else-if="scenarios.length === 0" class="text-sm text-n-slate-11">
          {{ t('MARINE_AI.SCENARIOS.EMPTY') }}
        </p>
        <ul v-else class="space-y-2">
          <li
            v-for="scenario in scenarios"
            :key="scenario.id"
            class="rounded-lg border border-n-weak p-3"
          >
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <div class="font-medium text-n-slate-12">
                  {{ scenario.title }}
                </div>
                <p
                  v-if="scenario.description"
                  class="text-sm text-n-slate-11 mt-0.5"
                >
                  {{ scenario.description }}
                </p>
                <p class="text-sm text-n-slate-11 mt-1 whitespace-pre-line">
                  {{ scenario.instruction }}
                </p>
                <div
                  v-if="scenario.tools && scenario.tools.length"
                  class="mt-2 flex flex-wrap gap-1"
                >
                  <span
                    v-for="tool in scenario.tools"
                    :key="tool"
                    class="rounded-full bg-n-alpha-2 px-2 py-0.5 text-xs font-medium text-n-slate-11"
                  >
                    {{ tool }}
                  </span>
                </div>
              </div>
              <span
                class="shrink-0 rounded-full px-2 py-0.5 text-xs font-medium"
                :class="
                  scenario.enabled
                    ? 'bg-n-teal-3 text-n-teal-11'
                    : 'bg-n-alpha-2 text-n-slate-11'
                "
              >
                {{
                  scenario.enabled
                    ? t('MARINE_AI.SCENARIOS.STATUS_ENABLED')
                    : t('MARINE_AI.SCENARIOS.STATUS_DISABLED')
                }}
              </span>
            </div>
            <div class="mt-2 flex gap-2">
              <button
                type="button"
                class="rounded-md border border-n-weak px-2.5 py-1 text-xs font-medium text-n-slate-12"
                @click="startEdit(scenario)"
              >
                {{ t('MARINE_AI.SCENARIOS.EDIT_ACTION') }}
              </button>
              <template v-if="confirmingDeleteId === scenario.id">
                <button
                  type="button"
                  class="rounded-md border border-n-weak px-2.5 py-1 text-xs font-medium text-n-ruby-11"
                  @click="deleteScenario(scenario)"
                >
                  {{ t('MARINE_AI.SCENARIOS.CONFIRM_DELETE') }}
                </button>
                <button
                  type="button"
                  class="rounded-md border border-n-weak px-2.5 py-1 text-xs font-medium text-n-slate-12"
                  @click="confirmingDeleteId = null"
                >
                  {{ t('MARINE_AI.SCENARIOS.CANCEL') }}
                </button>
              </template>
              <button
                v-else
                type="button"
                class="rounded-md border border-n-weak px-2.5 py-1 text-xs font-medium text-n-ruby-11"
                @click="confirmingDeleteId = scenario.id"
              >
                {{ t('MARINE_AI.SCENARIOS.DELETE') }}
              </button>
            </div>
          </li>
        </ul>
      </div>
    </div>
  </MarinePageShell>
</template>
