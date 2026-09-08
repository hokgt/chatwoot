<script setup>
import { computed, h, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { picoSearch } from '@scmmishra/pico-search';
import { useAlert } from 'dashboard/composables';
import { parseAPIErrorResponse } from 'dashboard/store/utils/api';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import MarineScenariosAPI from '@wijaya/marine_ai/frontend/api/scenarios';

import MarinePageLayout from '../components/MarinePageLayout.vue';
import MarineScenariosCard from '../components/MarineScenariosCard.vue';
import MarineAddNewScenariosDialog from '../components/MarineAddNewScenariosDialog.vue';
import ScenarioPageEmptyState from '../components/ScenarioPageEmptyState.vue';
import SuggestedRules from 'dashboard/components-next/captain/assistant/SuggestedRules.vue';
import BulkSelectBar from 'dashboard/components-next/captain/assistant/BulkSelectBar.vue';

const { t } = useI18n();
const route = useRoute();
const { uiSettings, updateUISettings } = useUISettings();
const { formatMessage } = useMessageFormatter();

const assistantId = computed(() => Number(route.params.assistantId));

const loading = ref(false);
const scenarios = ref([]);
const searchQuery = ref('');
const bulkSelectedIds = ref(new Set());
const hoveredCard = ref(null);

const LINK_INSTRUCTION_CLASS =
  '[&_a[href^="tool://"]]:text-n-iris-11 [&_a:not([href^="tool://"])]:text-n-slate-12 [&_a]:pointer-events-none [&_a]:cursor-default';

const renderInstruction = instruction => () =>
  h('span', {
    class: `text-sm text-n-slate-12 py-4 prose prose-sm min-w-0 break-words ${LINK_INSTRUCTION_CLASS}`,
    innerHTML: instruction,
  });

const scenariosExample = [
  {
    id: 1,
    title: 'Prospective Buyer',
    description:
      'Handle customers who are showing interest in purchasing a license',
    instruction:
      'If someone is interested in purchasing a license, ask them for following:\n\n1. How many licenses are they willing to purchase?\n2. Are they migrating from another platform?\n. Once these details are collected, do the following steps\n1. add a private note to with the information you collected using [Add Private Note](tool://add_private_note)\n2. Add label "sales" to the contact using [Add Label to Conversation](tool://add_label_to_conversation)\n3. Reply saying "one of us will reach out soon" and provide an estimated timeline for the response and [Handoff to Human](tool://handoff)',
    tools: ['add_private_note', 'add_label_to_conversation', 'handoff'],
  },
];

const getToolsFromInstruction = instruction => [
  ...new Set(
    [...(instruction?.matchAll(/\(tool:\/\/([^)]+)\)/g) ?? [])].map(m => m[1])
  ),
];

const filteredScenarios = computed(() => {
  const query = searchQuery.value.trim();
  const source = scenarios.value;
  if (!query) return source;
  return picoSearch(source, query, ['title', 'description', 'instruction']);
});

const shouldShowSuggestedRules = computed(() => {
  return uiSettings.value?.marine_show_scenarios_suggestions !== false;
});

const isEmpty = computed(
  () => scenarios.value.length === 0 && !shouldShowSuggestedRules.value
);

const closeSuggestedRules = () => {
  updateUISettings({ marine_show_scenarios_suggestions: false });
};

const handleRuleSelect = id => {
  const selected = new Set(bulkSelectedIds.value);
  selected[selected.has(id) ? 'delete' : 'add'](id);
  bulkSelectedIds.value = selected;
};

const buildSelectedCountLabel = computed(() => {
  const count = scenarios.value.length || 0;
  const isAllSelected = bulkSelectedIds.value.size === count && count > 0;
  return isAllSelected
    ? t('MARINE_AI.SCENARIOS.BULK_ACTION.UNSELECT_ALL', { count })
    : t('MARINE_AI.SCENARIOS.BULK_ACTION.SELECT_ALL', { count });
});

const selectedCountLabel = computed(() => {
  return t('MARINE_AI.SCENARIOS.BULK_ACTION.SELECTED', {
    count: bulkSelectedIds.value.size,
  });
});

const handleRuleHover = (isHovered, id) => {
  hoveredCard.value = isHovered ? id : null;
};

const fetchScenarios = async () => {
  if (!assistantId.value) {
    scenarios.value = [];
    return;
  }
  loading.value = true;
  try {
    const { data } = await MarineScenariosAPI.get({
      assistantId: assistantId.value,
    });
    scenarios.value = data.payload || [];
  } finally {
    loading.value = false;
  }
};

const addScenario = async scenario => {
  try {
    await MarineScenariosAPI.create({
      assistantId: assistantId.value,
      ...scenario,
      tools: getToolsFromInstruction(scenario.instruction),
    });
    useAlert(t('MARINE_AI.SCENARIOS.API.ADD.SUCCESS'));
    await fetchScenarios();
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) || t('MARINE_AI.SCENARIOS.API.ADD.ERROR')
    );
  }
};

const addAllExampleScenarios = async () => {
  try {
    await Promise.all(
      scenariosExample.map(scenario =>
        MarineScenariosAPI.create({
          assistantId: assistantId.value,
          ...scenario,
        })
      )
    );
    useAlert(t('MARINE_AI.SCENARIOS.API.ADD.SUCCESS'));
    await fetchScenarios();
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) || t('MARINE_AI.SCENARIOS.API.ADD.ERROR')
    );
  }
};

const updateScenario = async scenario => {
  try {
    await MarineScenariosAPI.update({
      assistantId: assistantId.value,
      id: scenario.id,
      ...scenario,
      tools: getToolsFromInstruction(scenario.instruction),
    });
    useAlert(t('MARINE_AI.SCENARIOS.API.UPDATE.SUCCESS'));
    await fetchScenarios();
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) || t('MARINE_AI.SCENARIOS.API.UPDATE.ERROR')
    );
  }
};

const deleteScenario = async id => {
  try {
    await MarineScenariosAPI.delete({ assistantId: assistantId.value, id });
    useAlert(t('MARINE_AI.SCENARIOS.API.DELETE.SUCCESS'));
    await fetchScenarios();
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) || t('MARINE_AI.SCENARIOS.API.DELETE.ERROR')
    );
  }
};

const bulkDeleteScenarios = async ids => {
  const idsArray = ids || Array.from(bulkSelectedIds.value);
  try {
    await Promise.all(
      idsArray.map(id =>
        MarineScenariosAPI.delete({ assistantId: assistantId.value, id })
      )
    );
    bulkSelectedIds.value = new Set();
    useAlert(t('MARINE_AI.SCENARIOS.API.DELETE.SUCCESS'));
    await fetchScenarios();
  } catch (error) {
    useAlert(
      parseAPIErrorResponse(error) || t('MARINE_AI.SCENARIOS.API.DELETE.ERROR')
    );
  }
};

const handleCreate = () => {
  updateUISettings({ marine_show_scenarios_suggestions: true });
};

watch(assistantId, fetchScenarios);

onMounted(fetchScenarios);
</script>

<template>
  <MarinePageLayout
    :header-title="t('MARINE_AI.SCENARIOS.HEADER')"
    :button-label="t('MARINE_AI.SCENARIOS.ADD.NEW.CREATE')"
    :button-policy="['administrator']"
    :is-fetching="loading"
    :is-empty="isEmpty"
    :show-pagination-footer="false"
    @click="handleCreate"
  >
    <template #search>
      <Input
        v-if="scenarios.length"
        v-model="searchQuery"
        :placeholder="t('MARINE_AI.SCENARIOS.LIST.SEARCH_PLACEHOLDER')"
        class="w-64"
        size="sm"
        type="search"
      />
    </template>

    <template #emptyState>
      <ScenarioPageEmptyState @click="handleCreate" />
    </template>

    <template #body>
      <div v-if="shouldShowSuggestedRules" class="flex mt-7 flex-col gap-4">
        <SuggestedRules
          :title="t('MARINE_AI.SCENARIOS.ADD.SUGGESTED.TITLE')"
          :items="scenariosExample"
          @close="closeSuggestedRules"
          @add="addAllExampleScenarios"
        >
          <template #default="{ item }">
            <div class="flex items-center gap-3 justify-between">
              <span class="text-sm text-n-slate-12">
                {{ item.title }}
              </span>
              <Button
                :label="t('MARINE_AI.SCENARIOS.ADD.SUGGESTED.ADD_SINGLE')"
                ghost
                xs
                slate
                class="!text-sm !text-n-slate-11 flex-shrink-0"
                @click="addScenario(item)"
              />
            </div>
            <div class="flex flex-col">
              <span class="text-sm text-n-slate-11 mt-2">
                {{ item.description }}
              </span>
              <component
                :is="renderInstruction(formatMessage(item.instruction, false))"
              />
              <span class="text-sm text-n-slate-11 font-medium mb-1">
                {{ t('MARINE_AI.SCENARIOS.ADD.SUGGESTED.TOOLS_USED') }}
                {{ item.tools?.map(tool => `@${tool}`).join(', ') }}
              </span>
            </div>
          </template>
        </SuggestedRules>
      </div>
      <div class="flex mt-7 flex-col gap-4">
        <div class="flex justify-between items-center">
          <BulkSelectBar
            v-model="bulkSelectedIds"
            :all-items="scenarios"
            :select-all-label="buildSelectedCountLabel"
            :selected-count-label="selectedCountLabel"
            :delete-label="
              t('MARINE_AI.SCENARIOS.BULK_ACTION.BULK_DELETE_BUTTON')
            "
            @bulk-delete="bulkDeleteScenarios"
          >
            <template #default-actions>
              <MarineAddNewScenariosDialog @add="addScenario" />
            </template>
          </BulkSelectBar>
        </div>
        <div v-if="scenarios.length === 0" class="mt-1 mb-2">
          <span class="text-n-slate-11 text-sm">
            {{ t('MARINE_AI.SCENARIOS.EMPTY_MESSAGE') }}
          </span>
        </div>
        <div v-else-if="filteredScenarios.length === 0" class="mt-1 mb-2">
          <span class="text-n-slate-11 text-sm">
            {{ t('MARINE_AI.SCENARIOS.SEARCH_EMPTY_MESSAGE') }}
          </span>
        </div>
        <div v-else class="flex flex-col gap-2">
          <MarineScenariosCard
            v-for="scenario in filteredScenarios"
            :id="scenario.id"
            :key="scenario.id"
            :title="scenario.title"
            :description="scenario.description"
            :instruction="scenario.instruction"
            :tools="scenario.tools"
            :is-selected="bulkSelectedIds.has(scenario.id)"
            :selectable="
              hoveredCard === scenario.id || bulkSelectedIds.size > 0
            "
            @select="handleRuleSelect"
            @delete="deleteScenario(scenario.id)"
            @update="updateScenario"
            @hover="isHovered => handleRuleHover(isHovered, scenario.id)"
          />
        </div>
      </div>
    </template>
  </MarinePageLayout>
</template>
