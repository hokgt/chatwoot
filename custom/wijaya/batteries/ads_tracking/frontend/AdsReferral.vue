<script setup>
import { computed } from 'vue';

const props = defineProps({
  referral: { type: Object, default: () => ({}) },
});

const headline = computed(() => props.referral?.headline || null);
const body = computed(() => props.referral?.body || null);
const imageUrl = computed(() => props.referral?.imageUrl || null);
const thumbnailUrl = computed(() => props.referral?.thumbnailUrl || null);
const videoUrl = computed(() => props.referral?.videoUrl || null);
const sourceUrl = computed(() => props.referral?.sourceUrl || null);

// Prefer thumbnailUrl, fall back to imageUrl for the preview image.
const mediaUrl = computed(() => thumbnailUrl.value || imageUrl.value);

const isVideo = computed(() => {
  const mediaType = (props.referral?.mediaType || '').toString().toLowerCase();
  return mediaType === 'video' || Boolean(videoUrl.value);
});

// For video ads prefer the video URL, otherwise fall back through the
// remaining links so the action always opens the most relevant destination.
const openUrl = computed(() => {
  if (isVideo.value && videoUrl.value) return videoUrl.value;
  return sourceUrl.value || imageUrl.value || thumbnailUrl.value || null;
});

const sponsoredLabel = computed(() => 'Sponsored');
const actionLabel = computed(() => (isVideo.value ? 'Watch ad' : 'View ad'));

const shouldRender = computed(
  () => mediaUrl.value || headline.value || body.value || openUrl.value
);
</script>

<template>
  <template v-if="shouldRender">
    <component
      :is="openUrl ? 'a' : 'div'"
      :href="openUrl || undefined"
      :target="openUrl ? '_blank' : undefined"
      :rel="openUrl ? 'noopener noreferrer' : undefined"
      class="group mb-1 block max-w-[min(17.5rem,80vw)] overflow-hidden rounded-xl border border-n-weak bg-n-slate-3 text-xs text-n-slate-12 no-underline transition-shadow hover:shadow-md"
    >
      <div v-if="mediaUrl" class="relative">
        <img
          :src="mediaUrl"
          :alt="headline || 'Advertisement'"
          class="h-44 w-full object-cover"
        />
        <span
          v-if="isVideo"
          class="absolute inset-0 flex items-center justify-center"
          aria-hidden="true"
        >
          <span
            class="flex size-10 items-center justify-center rounded-full bg-black/55"
          >
            <span class="i-lucide-play size-5 text-white" />
          </span>
        </span>
      </div>
      <div class="flex flex-col gap-0.5 px-2.5 py-2">
        <span
          class="text-[0.625rem] font-medium uppercase tracking-wide text-n-slate-10"
        >
          {{ sponsoredLabel }}
        </span>
        <span
          v-if="headline"
          class="line-clamp-2 break-words text-sm font-medium leading-5 text-n-slate-12"
        >
          {{ headline }}
        </span>
        <span
          v-if="body"
          class="line-clamp-3 break-words text-xs leading-4 text-n-slate-11"
        >
          {{ body }}
        </span>
        <span
          v-if="openUrl"
          class="mt-1 inline-flex items-center gap-1 text-xs font-medium text-n-blue-text group-hover:underline"
        >
          {{ actionLabel }}
          <span class="i-lucide-external-link size-3" />
        </span>
      </div>
    </component>
  </template>
</template>
