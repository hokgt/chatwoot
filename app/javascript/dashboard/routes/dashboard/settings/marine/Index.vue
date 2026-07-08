<script setup>
import { useI18n } from 'vue-i18n';

const { t } = useI18n();
</script>

<template>
  <div class="flex flex-col gap-4 p-4">
    <div>
      <h1 class="text-xl font-semibold text-n-slate-12">
        {{ t('MARINE_SETTINGS.TITLE') }}
      </h1>
      <p class="text-sm text-n-slate-11">
        {{ t('MARINE_SETTINGS.DESCRIPTION') }}
      </p>
    </div>
  </div>
</template>
