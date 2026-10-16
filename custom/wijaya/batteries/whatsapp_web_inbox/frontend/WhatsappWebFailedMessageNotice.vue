<script setup>
// Contextual notice rendered inside the native failed-message UI (MessageError.vue) ONLY
// for a WhatsApp Web (Unofficial) inbox whose send failed because the linked phone is
// disconnected/logged out (the connector 503). It swaps the opaque "503 Service
// Unavailable" for an understandable sentence and a shortcut straight to that exact
// inbox's WhatsApp Web connection/QR panel. For any other inbox or error it renders
// nothing, so unrelated channels keep the native behaviour untouched.
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store';
import { useMessageContext } from 'dashboard/components-next/message/provider.js';
import {
  isWhatsappWebInbox,
  isWhatsappWebDisconnectError,
} from '@wijaya/whatsapp_web_inbox/frontend/helpers/whatsappWebInbox';

const props = defineProps({
  error: { type: String, default: '' },
});

const { t } = useI18n();
const { inboxId } = useMessageContext();

const getInbox = useMapGetter('inboxes/getInbox');
const inbox = computed(() => getInbox.value(inboxId.value) || {});

const showDisconnectNotice = computed(
  () =>
    isWhatsappWebInbox(inbox.value) && isWhatsappWebDisconnectError(props.error)
);

// settings_inbox_show resolves the WhatsApp Web connection panel tab for this exact
// inbox; accountId is inherited from the current route.
const qrRoute = computed(() => ({
  name: 'settings_inbox_show',
  params: { inboxId: inboxId.value, tab: 'whatsapp-web' },
}));
</script>

<!-- eslint-disable-next-line vue/no-root-v-if -->
<template>
  <span
    v-if="showDisconnectNotice"
    class="flex items-center gap-1.5 text-xs text-n-ruby-11"
    data-testid="whatsapp-web-disconnect-notice"
  >
    <span>{{ t('WHATSAPP_WEB_INBOX.FAILED_MESSAGE.DISCONNECTED') }}</span>
    <router-link :to="qrRoute" class="underline font-medium">
      {{ t('WHATSAPP_WEB_INBOX.FAILED_MESSAGE.RESCAN_QR') }}
    </router-link>
  </span>
</template>
