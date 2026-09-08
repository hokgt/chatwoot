<script setup>
import { computed } from 'vue';

// Battery-owned build label. The Wijaya dev version is injected into the page
// bootstrap by the development_version hook (enrich_app_config -> window
// .globalConfig.WIJAYA_DEV_VERSION), so this component reads it directly instead
// of threading a field through the generic shared global config store.
const version = computed(() => window.globalConfig?.WIJAYA_DEV_VERSION);
</script>

<template>
  <span v-if="version" class="px-2">{{ `Wijaya Dev v${version}` }}</span>
</template>
