<script setup>
import { computed } from 'vue';

const props = defineProps({
  referral: { type: Object, default: () => ({}) },
});

const imageUrl = computed(() => props.referral?.imageUrl || null);
const headline = computed(() => props.referral?.headline || 'Ad');
const sourceUrl = computed(() => props.referral?.sourceUrl || null);

const shouldRender = computed(() => imageUrl.value || headline.value || sourceUrl.value);
</script>

<template>
  <div
    v-if="shouldRender"
    class="mb-1 max-w-[min(17.5rem,80vw)] overflow-hidden rounded-xl bg-n-slate-3 p-2 text-xs text-n-slate-12"
  >
    <img
      v-if="imageUrl"
      :src="imageUrl"
      alt="Ad image"
      class="h-48 w-full rounded-lg object-cover"
    />
    <div class="rounded-b-lg bg-n-solid-1 px-2 py-1.5">
      <div class="line-clamp-2 break-words text-sm leading-5 text-n-blue-text">
        {{ headline }}
      </div>
      <a
        v-if="sourceUrl"
        :href="sourceUrl"
        target="_blank"
        rel="noopener noreferrer"
        class="mt-0.5 block truncate text-xs leading-4 text-n-slate-11 hover:underline"
      >
        {{ sourceUrl }}
      </a>
    </div>
  </div>
</template>
