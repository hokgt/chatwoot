<script setup>
import { useI18n } from 'vue-i18n';
import MarinePageShell from '../components/MarinePageShell.vue';

const { t } = useI18n();
</script>

<template>
  <MarinePageShell
    :title="t('MARINE_AI.SCENARIOS.TITLE')"
    :description="t('MARINE_AI.SCENARIOS.DESCRIPTION')"
  >
    <div class="rounded-xl border border-n-weak bg-n-solid-1 p-4">
      <p class="text-sm text-n-slate-11">
        {{ t('MARINE_AI.SCENARIOS.EMPTY') }}
      </p>
    </div>
  </MarinePageShell>
</template>
