<script setup>
import { computed, ref } from 'vue';

const props = defineProps({
  referral: { type: Object, default: () => ({}) },
  attachments: { type: Array, default: () => [] },
});

const headline = computed(() => props.referral?.headline || null);
const body = computed(() => props.referral?.body || null);
const imageUrl = computed(() => props.referral?.imageUrl || null);
const thumbnailUrl = computed(() => props.referral?.thumbnailUrl || null);
const videoUrl = computed(() => props.referral?.videoUrl || null);
const sourceUrl = computed(() => props.referral?.sourceUrl || null);

// Prefer thumbnailUrl, fall back to imageUrl for the preview image.
const mediaUrl = computed(() => thumbnailUrl.value || imageUrl.value);

// Only absolute http(s) URLs may be used as media sources or external actions
// so that javascript:/data: and other unsafe schemes can never be emitted.
// Parsing without a base rejects relative paths outright — a referral URL is
// always an absolute destination, never something resolved against our origin.
const isSafeHttpUrl = value => {
  if (!value) return false;
  try {
    const { protocol } = new URL(value);
    return protocol === 'http:' || protocol === 'https:';
  } catch {
    return false;
  }
};

const isVideo = computed(() => {
  const mediaType = (props.referral?.mediaType || '').toString().toLowerCase();
  return mediaType === 'video' || Boolean(videoUrl.value);
});

// Inline playback uses only the ad video the server safely downloaded and stored
// as a normal Message attachment (associated via the Chatwoot-owned
// videoAttachmentId, never a raw Meta URL). A Facebook page/Reel URL, a missing
// URL, or a failed download produces no such attachment, so we fall back to the
// thumbnail + Watch ad card. The raw referral.videoUrl is never a <video> src.
const videoFailed = ref(false);
const storedVideoUrl = computed(() => {
  const attachmentId = props.referral?.videoAttachmentId;
  if (!attachmentId) return null;

  const match = props.attachments.find(
    attachment =>
      attachment?.id === attachmentId &&
      (attachment?.fileType || '').toString().toLowerCase() === 'video'
  );
  return match?.dataUrl || null;
});
const showInlineVideo = computed(
  () => Boolean(storedVideoUrl.value) && !videoFailed.value
);
const onVideoError = () => {
  videoFailed.value = true;
};

// External action used by the fallback card. For video referrals the video URL
// (e.g. the Reel page) is the meaningful destination once inline playback
// fails, so it stays ahead of sourceUrl to preserve the prior fallback target.
const openUrl = computed(() => {
  const candidates = isVideo.value
    ? [videoUrl.value, sourceUrl.value, imageUrl.value, thumbnailUrl.value]
    : [sourceUrl.value, imageUrl.value, thumbnailUrl.value];
  return candidates.find(isSafeHttpUrl) || null;
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
      :is="!showInlineVideo && openUrl ? 'a' : 'div'"
      :href="!showInlineVideo && openUrl ? openUrl : undefined"
      :target="!showInlineVideo && openUrl ? '_blank' : undefined"
      :rel="!showInlineVideo && openUrl ? 'noopener noreferrer' : undefined"
      class="ads-referral-card group mb-1 block overflow-hidden rounded-xl border border-n-weak bg-n-slate-3 text-xs text-n-slate-12 no-underline transition-shadow hover:shadow-md"
    >
      <div v-if="showInlineVideo" class="relative">
        <video
          :src="storedVideoUrl"
          :poster="mediaUrl || undefined"
          controls
          playsinline
          preload="metadata"
          data-test-id="ads-referral-video"
          class="h-44 w-full bg-black object-contain"
          @error="onVideoError"
        />
      </div>
      <div v-else-if="mediaUrl" class="relative">
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
          v-if="!showInlineVideo && openUrl"
          class="mt-1 inline-flex items-center gap-1 text-xs font-medium text-n-blue-text group-hover:underline"
        >
          {{ actionLabel }}
          <span class="i-lucide-external-link size-3" />
        </span>
      </div>
    </component>
  </template>
</template>

<style scoped>
.ads-referral-card {
  width: min(17.5rem, 80vw);
}
</style>
