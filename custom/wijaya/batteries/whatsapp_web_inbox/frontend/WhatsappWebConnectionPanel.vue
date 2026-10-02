<script setup>
import { ref, computed, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import NextButton from 'dashboard/components-next/button/Button.vue';
import whatsappWebAPI from '@wijaya/whatsapp_web_inbox/frontend/api/whatsappWeb';
import { useConnectorPolling } from '@wijaya/whatsapp_web_inbox/frontend/composables/useConnectorPolling';
import { connectionStatusLabel } from '@wijaya/whatsapp_web_inbox/frontend/helpers/connectionStatus';

const props = defineProps({
  inbox: {
    type: Object,
    required: true,
  },
});

const { t } = useI18n();

const inboxId = computed(() => props.inbox.id);
const status = ref('pending');
const provisioningState = ref('pending');
const connectorAvailable = ref(true);
const waJidMasked = ref(null);
const qrDataUrl = ref(null);
const busy = ref(false);
const errorMessage = ref('');
const showLogoutConfirm = ref(false);

const isProvisioned = computed(() => provisioningState.value === 'provisioned');
const isConnected = computed(() => status.value === 'connected');
const canRetry = computed(() => !isProvisioned.value);

const QR_STATES = ['unconfigured', 'waiting_for_qr', 'connecting', 'pending'];

const statusLabel = computed(() =>
  connectionStatusLabel(t, status.value, connectorAvailable.value)
);

const applyDto = data => {
  status.value = data.status || 'pending';
  provisioningState.value = data.provisioning_state || 'pending';
  connectorAvailable.value = data.connector_available !== false;
  if (data.wa_jid_masked !== undefined) waJidMasked.value = data.wa_jid_masked;
};

const refreshQr = async () => {
  const { data } = await whatsappWebAPI.qr(inboxId.value);
  connectorAvailable.value = data.connector_available !== false;
  qrDataUrl.value = data.available ? data.data_url : null;
};

const poll = async () => {
  try {
    const { data } = await whatsappWebAPI.status(inboxId.value);
    applyDto(data);
    if (
      connectorAvailable.value &&
      !isConnected.value &&
      QR_STATES.includes(status.value)
    ) {
      await refreshQr();
    } else {
      qrDataUrl.value = null;
    }
  } catch (error) {
    if (error.response?.status === 429) return;
    connectorAvailable.value = false;
  }
};

const { start: startPolling } = useConnectorPolling(poll, {
  interval: 5000,
  hiddenInterval: 20000,
});

// Run a control action, surfacing only a sanitized error, then refresh once.
const runControl = async action => {
  if (busy.value) return;
  busy.value = true;
  errorMessage.value = '';
  try {
    const { data } = await action();
    applyDto(data);
    await poll();
  } catch (error) {
    if (error.response?.status !== 429) {
      errorMessage.value = t('WHATSAPP_WEB_INBOX.PANEL.ERROR');
    }
  } finally {
    busy.value = false;
  }
};

const onRefresh = () => runControl(() => whatsappWebAPI.status(inboxId.value));
const onReconnect = () =>
  runControl(() => whatsappWebAPI.reconnect(inboxId.value));
const onRetry = () => runControl(() => whatsappWebAPI.retry(inboxId.value));

const onLogoutConfirmed = () => {
  showLogoutConfirm.value = false;
  runControl(() => whatsappWebAPI.logout(inboxId.value));
};

onMounted(() => {
  startPolling();
});
</script>

<template>
  <div class="flex flex-col gap-4 max-w-2xl" data-testid="whatsapp-web-panel">
    <div>
      <h3 class="text-base font-medium m-0">
        {{ t('WHATSAPP_WEB_INBOX.PANEL.TITLE') }}
      </h3>
      <p class="text-sm text-n-slate-11 m-0">
        {{ t('WHATSAPP_WEB_INBOX.PANEL.DESCRIPTION') }}
      </p>
    </div>

    <div class="flex items-center gap-2 text-sm">
      <span class="font-medium">{{
        t('WHATSAPP_WEB_INBOX.STATUS.LABEL')
      }}</span>
      <span data-testid="connection-status">{{ statusLabel }}</span>
    </div>

    <div
      v-if="waJidMasked"
      class="flex items-center gap-2 text-sm"
      data-testid="linked-number"
    >
      <span class="font-medium">{{
        t('WHATSAPP_WEB_INBOX.PANEL.LINKED_NUMBER')
      }}</span>
      <span>{{ waJidMasked }}</span>
    </div>

    <div
      v-if="!connectorAvailable"
      class="p-4 rounded-lg bg-n-slate-3 text-sm"
      data-testid="connector-unavailable"
    >
      {{ t('WHATSAPP_WEB_INBOX.PANEL.UNAVAILABLE') }}
    </div>

    <img
      v-if="connectorAvailable && !isConnected && qrDataUrl"
      :src="qrDataUrl"
      :alt="t('WHATSAPP_WEB_INBOX.QR.ALT')"
      class="w-56 h-56 rounded-lg border border-n-weak bg-white p-2"
      data-testid="qr-image"
    />

    <p v-if="errorMessage" class="text-sm text-ruby-600 m-0">
      {{ errorMessage }}
    </p>

    <div class="flex flex-wrap gap-2">
      <NextButton
        faded
        slate
        :is-loading="busy"
        :label="t('WHATSAPP_WEB_INBOX.PANEL.REFRESH')"
        @click="onRefresh"
      />
      <NextButton
        v-if="isProvisioned"
        faded
        blue
        :disabled="busy"
        :label="t('WHATSAPP_WEB_INBOX.PANEL.RECONNECT')"
        @click="onReconnect"
      />
      <NextButton
        v-if="canRetry"
        faded
        blue
        :disabled="busy"
        :label="t('WHATSAPP_WEB_INBOX.PANEL.RETRY')"
        @click="onRetry"
      />
      <NextButton
        v-if="isProvisioned"
        faded
        ruby
        :disabled="busy"
        :label="t('WHATSAPP_WEB_INBOX.PANEL.LOGOUT')"
        @click="showLogoutConfirm = true"
      />
    </div>

    <!-- Destructive logout confirmation -->
    <div
      v-if="showLogoutConfirm"
      class="flex flex-col gap-3 p-4 rounded-lg border border-n-weak bg-n-background"
      data-testid="logout-confirm"
    >
      <p class="font-semibold m-0">
        {{ t('WHATSAPP_WEB_INBOX.PANEL.LOGOUT_CONFIRM.TITLE') }}
      </p>
      <p class="text-sm m-0">
        {{ t('WHATSAPP_WEB_INBOX.PANEL.LOGOUT_CONFIRM.BODY') }}
      </p>
      <div class="flex gap-2">
        <NextButton
          solid
          ruby
          :label="t('WHATSAPP_WEB_INBOX.PANEL.LOGOUT_CONFIRM.CONFIRM')"
          @click="onLogoutConfirmed"
        />
        <NextButton
          faded
          slate
          :label="t('WHATSAPP_WEB_INBOX.PANEL.LOGOUT_CONFIRM.CANCEL')"
          @click="showLogoutConfirm = false"
        />
      </div>
    </div>
  </div>
</template>
