<script setup>
import { useI18n } from 'vue-i18n';

import EmptyStateLayout from 'dashboard/components-next/EmptyStateLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const emit = defineEmits(['click']);

const { t } = useI18n();
</script>

<template>
  <EmptyStateLayout
    :title="t('MARINE_AI.SCENARIOS.EMPTY_STATE.TITLE')"
    :subtitle="t('MARINE_AI.SCENARIOS.EMPTY_STATE.DESCRIPTION')"
    :action-perms="['administrator']"
    :show-backdrop="false"
  >
    <template #actions>
      <Button
        :label="t('MARINE_AI.SCENARIOS.EMPTY_STATE.ACTION')"
        icon="i-lucide-plus"
        @click="emit('click')"
      />
    </template>
  </EmptyStateLayout>
</template>
