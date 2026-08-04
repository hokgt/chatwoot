<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import EmptyStateLayout from 'dashboard/components-next/EmptyStateLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  variant: {
    type: String,
    default: 'approved',
    validator: value => ['approved', 'pending'].includes(value),
  },
  hasActiveFilters: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['click', 'clearFilters']);

const { t } = useI18n();

const title = computed(() =>
  props.variant === 'pending'
    ? t('MARINE_AI.FAQS.EMPTY_STATE.NO_PENDING_TITLE')
    : t('MARINE_AI.FAQS.EMPTY_STATE.TITLE')
);

const subtitle = computed(() => t('MARINE_AI.FAQS.EMPTY_STATE.SUBTITLE'));
</script>

<template>
  <EmptyStateLayout
    :title="title"
    :subtitle="subtitle"
    :action-perms="['administrator']"
    :show-backdrop="false"
  >
    <template #actions>
      <Button
        v-if="hasActiveFilters"
        variant="faded"
        color="slate"
        :label="t('MARINE_AI.FAQS.EMPTY_STATE.CLEAR_FILTERS')"
        icon="i-lucide-x"
        @click="emit('clearFilters')"
      />
      <Button
        v-else
        :label="t('MARINE_AI.FAQS.ADD_NEW')"
        icon="i-lucide-plus"
        @click="emit('click')"
      />
    </template>
  </EmptyStateLayout>
</template>
