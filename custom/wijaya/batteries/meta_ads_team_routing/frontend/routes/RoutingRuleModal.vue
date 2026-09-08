<script setup>
// WIJAYA_CUSTOM meta_ads_team_routing
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStoreGetters, useStore } from 'dashboard/composables/store';
import NextButton from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  mode: {
    type: String,
    default: 'add',
  },
  selectedRule: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['close']);

const getters = useStoreGetters();
const store = useStore();
const { t } = useI18n();

const isEdit = computed(() => props.mode === 'edit');
const teams = computed(() => getters['teams/getTeams'].value);
const uiFlags = computed(() => getters['metaAdsRouting/getUIFlags'].value);
const isSaving = computed(() =>
  isEdit.value ? uiFlags.value.isUpdating : uiFlags.value.isCreating
);

const sourceId = ref('');
const campaignName = ref('');
const teamId = ref('');
const status = ref('active');

onMounted(() => {
  if (isEdit.value) {
    sourceId.value = props.selectedRule.source_id ?? '';
    campaignName.value = props.selectedRule.campaign_name ?? '';
    teamId.value = props.selectedRule.team_id ?? '';
    status.value = props.selectedRule.status ?? 'active';
  }
});

const pageTitle = computed(() =>
  isEdit.value
    ? t('META_ADS_ROUTING.EDIT.TITLE')
    : t('META_ADS_ROUTING.ADD.TITLE')
);

const isInvalid = computed(
  () => !sourceId.value.trim() || !teamId.value || isSaving.value
);

const onClose = () => emit('close');

const submit = async () => {
  const payload = {
    source_id: sourceId.value.trim(),
    campaign_name: campaignName.value.trim(),
    team_id: teamId.value,
    status: status.value,
  };
  try {
    if (isEdit.value) {
      await store.dispatch('metaAdsRouting/update', {
        id: props.selectedRule.id,
        ...payload,
      });
      useAlert(t('META_ADS_ROUTING.EDIT.API.SUCCESS_MESSAGE'));
    } else {
      await store.dispatch('metaAdsRouting/create', payload);
      useAlert(t('META_ADS_ROUTING.ADD.API.SUCCESS_MESSAGE'));
    }
    setTimeout(() => onClose(), 10);
  } catch (error) {
    const fallback = isEdit.value
      ? t('META_ADS_ROUTING.EDIT.API.ERROR_MESSAGE')
      : t('META_ADS_ROUTING.ADD.API.ERROR_MESSAGE');
    useAlert(error?.message || fallback);
  }
};
</script>

<template>
  <div class="flex flex-col h-auto overflow-auto">
    <woot-modal-header :header-title="pageTitle" />
    <form class="flex flex-wrap mx-0" @submit.prevent="submit">
      <woot-input
        v-model="sourceId"
        class="w-full"
        :label="$t('META_ADS_ROUTING.FORM.SOURCE_ID.LABEL')"
        :placeholder="$t('META_ADS_ROUTING.FORM.SOURCE_ID.PLACEHOLDER')"
      />
      <woot-input
        v-model="campaignName"
        class="w-full"
        :label="$t('META_ADS_ROUTING.FORM.CAMPAIGN_NAME.LABEL')"
        :placeholder="$t('META_ADS_ROUTING.FORM.CAMPAIGN_NAME.PLACEHOLDER')"
      />
      <label class="w-full">
        {{ $t('META_ADS_ROUTING.FORM.TEAM.LABEL') }}
        <select v-model="teamId" class="w-full">
          <option value="" disabled>
            {{ $t('META_ADS_ROUTING.FORM.TEAM.PLACEHOLDER') }}
          </option>
          <option v-for="team in teams" :key="team.id" :value="team.id">
            {{ team.name }}
          </option>
        </select>
      </label>
      <label class="w-full">
        {{ $t('META_ADS_ROUTING.FORM.STATUS.LABEL') }}
        <select v-model="status" class="w-full">
          <option value="active">
            {{ $t('META_ADS_ROUTING.STATUS.ACTIVE') }}
          </option>
          <option value="inactive">
            {{ $t('META_ADS_ROUTING.STATUS.INACTIVE') }}
          </option>
        </select>
      </label>
      <div class="flex items-center justify-end w-full gap-2 px-0 py-2">
        <NextButton
          faded
          slate
          type="reset"
          :label="$t('META_ADS_ROUTING.FORM.CANCEL')"
          @click.prevent="onClose"
        />
        <NextButton
          type="submit"
          :label="
            isEdit
              ? $t('META_ADS_ROUTING.FORM.EDIT')
              : $t('META_ADS_ROUTING.FORM.CREATE')
          "
          :disabled="isInvalid"
          :is-loading="isSaving"
        />
      </div>
    </form>
  </div>
</template>
