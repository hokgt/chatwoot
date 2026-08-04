<script setup>
// WIJAYA_CUSTOM meta_ads_team_routing
import { useAlert } from 'dashboard/composables';
import { computed, onBeforeMount, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStoreGetters, useStore } from 'dashboard/composables/store';
import { picoSearch } from '@scmmishra/pico-search';

import RoutingRuleModal from './RoutingRuleModal.vue';
import BaseSettingsHeader from 'dashboard/routes/dashboard/settings/components/BaseSettingsHeader.vue';
import SettingsLayout from 'dashboard/routes/dashboard/settings/SettingsLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import {
  BaseTable,
  BaseTableRow,
  BaseTableCell,
} from 'dashboard/components-next/table';

const getters = useStoreGetters();
const store = useStore();
const { t } = useI18n();

const loading = ref({});
const showAddPopup = ref(false);
const showEditPopup = ref(false);
const showDeleteConfirmationPopup = ref(false);
const selectedRule = ref({});
const searchQuery = ref('');

const records = computed(() => getters['metaAdsRouting/getRoutingRules'].value);
const uiFlags = computed(() => getters['metaAdsRouting/getUIFlags'].value);

const filteredRecords = computed(() => {
  const query = searchQuery.value.trim();
  if (!query) return records.value;
  return picoSearch(records.value, query, [
    { name: 'source_id', weight: 4 },
    'campaign_name',
    'team_name',
  ]);
});

const tableHeaders = computed(() => [
  t('META_ADS_ROUTING.LIST.TABLE_HEADER.SOURCE_ID'),
  t('META_ADS_ROUTING.LIST.TABLE_HEADER.CAMPAIGN_NAME'),
  t('META_ADS_ROUTING.LIST.TABLE_HEADER.TEAM'),
  t('META_ADS_ROUTING.LIST.TABLE_HEADER.STATUS'),
  t('META_ADS_ROUTING.LIST.TABLE_HEADER.ACTION'),
]);

const deleteMessage = computed(() => ` ${selectedRule.value.source_id}?`);

const openAddPopup = () => {
  showAddPopup.value = true;
};
const hideAddPopup = () => {
  showAddPopup.value = false;
};

const openEditPopup = rule => {
  selectedRule.value = rule;
  showEditPopup.value = true;
};
const hideEditPopup = () => {
  showEditPopup.value = false;
};

const openDeletePopup = rule => {
  selectedRule.value = rule;
  showDeleteConfirmationPopup.value = true;
};
const closeDeletePopup = () => {
  showDeleteConfirmationPopup.value = false;
};

const deleteRule = async id => {
  try {
    await store.dispatch('metaAdsRouting/delete', id);
    useAlert(t('META_ADS_ROUTING.DELETE.API.SUCCESS_MESSAGE'));
  } catch (error) {
    useAlert(error?.message || t('META_ADS_ROUTING.DELETE.API.ERROR_MESSAGE'));
  } finally {
    loading.value[selectedRule.value.id] = false;
  }
};

const confirmDeletion = () => {
  loading.value[selectedRule.value.id] = true;
  closeDeletePopup();
  deleteRule(selectedRule.value.id);
};

onBeforeMount(() => {
  store.dispatch('metaAdsRouting/get');
  store.dispatch('teams/get');
});
</script>

<template>
  <SettingsLayout
    :is-loading="uiFlags.isFetching"
    :loading-message="$t('META_ADS_ROUTING.LOADING')"
    :no-records-found="!records.length"
    :no-records-message="$t('META_ADS_ROUTING.LIST.404')"
  >
    <template #header>
      <BaseSettingsHeader
        v-model:search-query="searchQuery"
        :title="$t('META_ADS_ROUTING.HEADER')"
        :description="$t('META_ADS_ROUTING.DESCRIPTION')"
        :search-placeholder="$t('META_ADS_ROUTING.SEARCH_PLACEHOLDER')"
      >
        <template v-if="records?.length" #count>
          <span class="text-body-main text-n-slate-11">
            {{ $t('META_ADS_ROUTING.COUNT', { n: records.length }) }}
          </span>
        </template>
        <template #actions>
          <Button
            :label="$t('META_ADS_ROUTING.HEADER_BTN_TXT')"
            size="sm"
            @click="openAddPopup"
          />
        </template>
      </BaseSettingsHeader>
    </template>
    <template #body>
      <BaseTable
        :headers="tableHeaders"
        :items="filteredRecords"
        :no-data-message="
          searchQuery
            ? $t('META_ADS_ROUTING.NO_RESULTS')
            : $t('META_ADS_ROUTING.LIST.404')
        "
      >
        <template #row="{ items }">
          <BaseTableRow v-for="rule in items" :key="rule.id" :item="rule">
            <template #default>
              <BaseTableCell>
                <span class="text-body-main text-n-slate-12">
                  {{ rule.source_id }}
                </span>
              </BaseTableCell>

              <BaseTableCell>
                <span class="text-body-main text-n-slate-11">
                  {{ rule.campaign_name }}
                </span>
              </BaseTableCell>

              <BaseTableCell>
                <span class="text-body-main text-n-slate-12">
                  {{ rule.team_name }}
                </span>
              </BaseTableCell>

              <BaseTableCell>
                <span
                  class="text-body-main"
                  :class="
                    rule.status === 'active'
                      ? 'text-n-teal-11'
                      : 'text-n-slate-10'
                  "
                >
                  {{
                    rule.status === 'active'
                      ? $t('META_ADS_ROUTING.STATUS.ACTIVE')
                      : $t('META_ADS_ROUTING.STATUS.INACTIVE')
                  }}
                </span>
              </BaseTableCell>

              <BaseTableCell align="end">
                <div class="flex gap-3 justify-end flex-shrink-0">
                  <Button
                    v-tooltip.top="$t('META_ADS_ROUTING.FORM.EDIT')"
                    icon="i-woot-edit-pen"
                    slate
                    sm
                    :is-loading="loading[rule.id]"
                    @click="openEditPopup(rule)"
                  />
                  <Button
                    v-tooltip.top="$t('META_ADS_ROUTING.DELETE.CONFIRM.YES')"
                    icon="i-woot-bin"
                    slate
                    sm
                    class="hover:enabled:text-n-ruby-11 hover:enabled:bg-n-ruby-2"
                    :is-loading="loading[rule.id]"
                    @click="openDeletePopup(rule)"
                  />
                </div>
              </BaseTableCell>
            </template>
          </BaseTableRow>
        </template>
      </BaseTable>
    </template>

    <woot-modal v-model:show="showAddPopup" :on-close="hideAddPopup">
      <RoutingRuleModal mode="add" @close="hideAddPopup" />
    </woot-modal>

    <woot-modal v-model:show="showEditPopup" :on-close="hideEditPopup">
      <RoutingRuleModal
        mode="edit"
        :selected-rule="selectedRule"
        @close="hideEditPopup"
      />
    </woot-modal>

    <woot-delete-modal
      v-model:show="showDeleteConfirmationPopup"
      :on-close="closeDeletePopup"
      :on-confirm="confirmDeletion"
      :title="$t('META_ADS_ROUTING.DELETE.CONFIRM.TITLE')"
      :message="$t('META_ADS_ROUTING.DELETE.CONFIRM.MESSAGE')"
      :message-value="deleteMessage"
      :confirm-text="$t('META_ADS_ROUTING.DELETE.CONFIRM.YES')"
      :reject-text="$t('META_ADS_ROUTING.DELETE.CONFIRM.NO')"
    />
  </SettingsLayout>
</template>
