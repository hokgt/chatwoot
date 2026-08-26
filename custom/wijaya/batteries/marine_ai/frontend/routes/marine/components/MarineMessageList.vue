<script setup>
import { useI18n } from 'vue-i18n';
import { ref, watch, nextTick } from 'vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import { useMessageFormatter } from 'shared/composables/useMessageFormatter';

const props = defineProps({
  messages: {
    type: Array,
    required: true,
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
});

const messageContainer = ref(null);

const { t } = useI18n();
const { formatMessage } = useMessageFormatter();

const isUserMessage = sender => sender === 'user';

const getMessageAlignment = sender =>
  isUserMessage(sender) ? 'justify-end' : 'justify-start';

const getMessageDirection = sender =>
  isUserMessage(sender) ? 'flex-row-reverse' : 'flex-row';

const getAvatarName = sender =>
  isUserMessage(sender)
    ? t('MARINE_AI.PLAYGROUND.USER')
    : t('MARINE_AI.PLAYGROUND.ASSISTANT');

const getMessageStyle = sender =>
  isUserMessage(sender)
    ? 'bg-n-solid-blue text-n-slate-12 rounded-br-sm rounded-bl-xl rounded-t-xl'
    : 'bg-n-solid-iris text-n-slate-12 rounded-bl-sm rounded-br-xl rounded-t-xl';

// Human-readable, read-only file size for the catalog preview card. Bytes are already an
// allowlisted, nonsecret document metadatum; this only formats, it never links to the blob.
const formatFileSize = bytes => {
  if (typeof bytes !== 'number' || bytes < 0) return '';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
};

const scrollToBottom = async () => {
  await nextTick();
  if (messageContainer.value) {
    messageContainer.value.scrollTop = messageContainer.value.scrollHeight;
  }
};

watch(() => props.messages.length, scrollToBottom);
</script>

<template>
  <div
    ref="messageContainer"
    class="flex-1 overflow-y-auto mb-4 px-6 space-y-6"
  >
    <div
      v-for="(message, index) in messages"
      :key="index"
      class="flex"
      :class="getMessageAlignment(message.sender)"
    >
      <div
        class="flex items-end gap-1.5 max-w-[90%] md:max-w-[60%]"
        :class="getMessageDirection(message.sender)"
      >
        <Avatar
          :name="getAvatarName(message.sender)"
          rounded-full
          :size="24"
          class="shrink-0"
        />
        <div
          v-if="message.handoff"
          class="bg-n-amber-3 border border-n-amber-6 rounded-lg p-3"
        >
          <p class="text-sm font-medium text-n-amber-11">
            {{ t('MARINE_AI.PLAYGROUND.HANDOFF') }}
          </p>
          <p class="text-xs text-n-amber-11">
            {{ t('MARINE_AI.PLAYGROUND.HANDOFF_HINT') }}
          </p>
          <p v-if="message.actionReason" class="text-xs text-n-slate-11">
            {{
              t('MARINE_AI.PLAYGROUND.HANDOFF_REASON', {
                reason: message.actionReason,
              })
            }}
          </p>
        </div>
        <div
          v-else-if="message.error"
          class="bg-n-ruby-3 border border-n-ruby-6 rounded-lg p-3"
        >
          <p class="text-sm text-n-ruby-11">
            {{ t('MARINE_AI.PLAYGROUND.ERROR') }}
          </p>
        </div>
        <div v-else class="flex flex-col gap-2 max-w-full min-w-0">
          <div
            class="px-4 py-3 text-sm [overflow-wrap:break-word]"
            :class="getMessageStyle(message.sender)"
          >
            <div v-html="formatMessage(message.content)" />
          </div>
          <!-- Read-only, NON-downloadable catalog preview card: only allowlisted, nonsecret
               document metadata (family, filename, MIME, size). Deliberately renders NO link,
               button, or download action — the source-less preview never delivers a file. -->
          <div
            v-if="message.catalogPreview"
            data-testid="catalog-preview-card"
            class="rounded-lg border border-n-weak bg-n-background p-3"
          >
            <div class="flex items-center gap-2">
              <span class="i-lucide-file-text text-n-slate-11 shrink-0" />
              <p class="text-sm font-medium text-n-slate-12 truncate">
                {{ message.catalogPreview.family_name }}
              </p>
            </div>
            <p class="mt-1 text-xs text-n-slate-11 truncate">
              {{ message.catalogPreview.filename }}
            </p>
            <p class="text-xs text-n-slate-10">
              {{
                t('MARINE_AI.PLAYGROUND.CATALOG_PREVIEW.FILE_META', {
                  type: message.catalogPreview.content_type,
                  size: formatFileSize(message.catalogPreview.byte_size),
                })
              }}
            </p>
            <p class="mt-2 text-xs italic text-n-slate-10">
              {{ t('MARINE_AI.PLAYGROUND.CATALOG_PREVIEW.READ_ONLY_HINT') }}
            </p>
          </div>
        </div>
      </div>
    </div>
    <div v-if="isLoading" class="flex justify-start">
      <div class="flex items-start gap-1.5">
        <Avatar :name="getAvatarName('assistant')" rounded-full :size="24" />
        <div
          class="max-w-sm rounded-lg p-3 text-sm bg-n-solid-iris text-n-slate-12"
        >
          <div class="flex gap-1">
            <div class="w-2 h-2 rounded-full bg-n-iris-10 animate-bounce" />
            <div
              class="w-2 h-2 rounded-full bg-n-iris-10 animate-bounce [animation-delay:0.2s]"
            />
            <div
              class="w-2 h-2 rounded-full bg-n-iris-10 animate-bounce [animation-delay:0.4s]"
            />
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
