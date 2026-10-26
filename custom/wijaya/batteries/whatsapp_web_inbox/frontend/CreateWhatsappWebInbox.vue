<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import getUuid from 'widget/helpers/uuid';
import PageHeader from 'dashboard/routes/dashboard/settings/SettingsSubPageHeader.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import whatsappWebAPI from '@wijaya/whatsapp_web_inbox/frontend/api/whatsappWeb';
import { useConnectorPolling } from '@wijaya/whatsapp_web_inbox/frontend/composables/useConnectorPolling';
import { connectionStatusLabel } from '@wijaya/whatsapp_web_inbox/frontend/helpers/connectionStatus';

const { t } = useI18n();
const router = useRouter();

// Stable client idempotency token: generated once, reused verbatim on every retry so a
// duplicate create can never provision a second inbox.
const requestToken = ref(getUuid());

const name = ref('');
const acknowledged = ref(false);
const isCreating = ref(false);
const created = ref(false);
const inboxId = ref(null);
const status = ref('pending');
const provisioningState = ref('pending');
const connectorAvailable = ref(true);
const qrDataUrl = ref(null);
const errorMessage = ref('');

const canSubmit = computed(
  () => !!name.value.trim() && acknowledged.value && !isCreating.value
);

const isConnected = computed(() => status.value === 'connected');
const isProvisioned = computed(() => provisioningState.value === 'provisioned');

// Guards so the connector `connect` call fires exactly once during pairing: a freshly
// provisioned session sits at 'disconnected' and only produces a QR after we ask it to
// connect. connectRequested prevents concurrent/repeated calls; connectError stops any
// auto-retry loop so a failure never floods the connector — the user retries intentionally.
const connectRequested = ref(false);
const connectError = ref(false);

const QR_STATES = ['unconfigured', 'waiting_for_qr', 'connecting', 'pending'];
const needsQr = s => QR_STATES.includes(s);

const statusLabel = computed(() =>
  connectionStatusLabel(t, status.value, connectorAvailable.value)
);

const applyDto = data => {
  status.value = data.status || 'pending';
  provisioningState.value = data.provisioning_state || 'pending';
  connectorAvailable.value = data.connector_available !== false;
};

const refreshQr = async () => {
  const { data } = await whatsappWebAPI.qr(inboxId.value);
  connectorAvailable.value = data.connector_available !== false;
  qrDataUrl.value = data.available ? data.data_url : null;
};

// Assigned from the poller below; declared first so poll() can reference it without a
// use-before-define cycle.
let stopPolling = () => {};

// Ask the connector to start pairing. Called at most once (connectRequested guard); a
// throttle (429) is transient so it re-arms, any other failure surfaces an actionable
// error and halts auto-retry until the user explicitly retries.
const ensureConnected = async () => {
  if (connectRequested.value) return;
  connectRequested.value = true;
  try {
    const { data } = await whatsappWebAPI.connect(inboxId.value);
    applyDto(data);
  } catch (error) {
    if (error.response?.status === 429) {
      connectRequested.value = false;
      return;
    }
    connectError.value = true;
    errorMessage.value = t('WHATSAPP_WEB_INBOX.CREATE.CONNECT_ERROR');
  }
};

const retryConnect = () => {
  connectRequested.value = false;
  connectError.value = false;
  errorMessage.value = '';
  ensureConnected();
};

const poll = async () => {
  if (!inboxId.value) return;
  try {
    const { data } = await whatsappWebAPI.status(inboxId.value);
    applyDto(data);
    // Pairing only begins once the mapping is provisioned; the connector then reports
    // 'disconnected' until we explicitly connect. Fire connect once, then let polling
    // carry the session through connecting -> waiting_for_qr -> connected.
    if (
      connectorAvailable.value &&
      isProvisioned.value &&
      status.value === 'disconnected' &&
      !connectRequested.value &&
      !connectError.value
    ) {
      await ensureConnected();
    }
    if (connectorAvailable.value && needsQr(status.value)) {
      await refreshQr();
    } else {
      qrDataUrl.value = null;
    }
    if (isConnected.value) {
      stopPolling();
    }
  } catch (error) {
    if (error.response?.status === 429) return; // throttled — skip this tick
    connectorAvailable.value = false;
  }
};

const { start: startPolling, stop } = useConnectorPolling(poll, {
  interval: 3000,
  hiddenInterval: 15000,
});
stopPolling = stop;

const createInbox = async () => {
  if (!canSubmit.value) return;
  isCreating.value = true;
  errorMessage.value = '';
  try {
    const { data } = await whatsappWebAPI.create({
      name: name.value.trim(),
      request_token: requestToken.value,
      acknowledged: acknowledged.value,
    });
    inboxId.value = data.inbox_id;
    applyDto(data);
    created.value = true;
    startPolling();
  } catch (error) {
    errorMessage.value =
      error.response?.status === 503
        ? t('WHATSAPP_WEB_INBOX.CREATE.CONNECTOR_UNAVAILABLE')
        : t('WHATSAPP_WEB_INBOX.CREATE.ERROR');
  } finally {
    isCreating.value = false;
  }
};

const goToAgents = () => {
  router.replace({
    name: 'settings_inboxes_add_agents',
    params: { page: 'new', inbox_id: inboxId.value },
  });
};
</script>

<template>
  <div class="h-full w-full p-6 col-span-6">
    <PageHeader
      :header-title="t('WHATSAPP_WEB_INBOX.CREATE.TITLE')"
      :header-content="t('WHATSAPP_WEB_INBOX.CREATE.DESCRIPTION')"
    />

    <!-- Step 1: creation form with mandatory risk acknowledgement -->
    <form
      v-if="!created"
      class="flex flex-col gap-4 max-w-2xl"
      @submit.prevent="createInbox"
    >
      <div
        class="flex flex-col gap-2 p-4 rounded-lg border border-ruby-300 bg-ruby-50 dark:border-ruby-700 dark:bg-ruby-900/30"
      >
        <p class="font-semibold text-ruby-800 dark:text-ruby-200 m-0">
          {{ t('WHATSAPP_WEB_INBOX.CREATE.WARNING.TITLE') }}
        </p>
        <p class="text-sm text-ruby-700 dark:text-ruby-200 m-0">
          {{ t('WHATSAPP_WEB_INBOX.CREATE.WARNING.BODY') }}
        </p>
      </div>

      <label class="flex flex-col gap-1">
        <span class="text-sm font-medium">{{
          t('WHATSAPP_WEB_INBOX.CREATE.INBOX_NAME_LABEL')
        }}</span>
        <input
          v-model="name"
          type="text"
          class="w-full"
          :placeholder="t('WHATSAPP_WEB_INBOX.CREATE.INBOX_NAME_PLACEHOLDER')"
        />
      </label>

      <label class="flex items-start gap-2 cursor-pointer">
        <input v-model="acknowledged" type="checkbox" class="mt-1" />
        <span class="text-sm">{{
          t('WHATSAPP_WEB_INBOX.CREATE.WARNING.ACK')
        }}</span>
      </label>

      <p v-if="errorMessage" class="text-sm text-ruby-600 m-0">
        {{ errorMessage }}
      </p>

      <div>
        <NextButton
          type="submit"
          solid
          blue
          :is-loading="isCreating"
          :disabled="!canSubmit"
          :label="t('WHATSAPP_WEB_INBOX.CREATE.SUBMIT')"
        />
      </div>
    </form>

    <!-- Step 2: live pairing -->
    <div v-else class="flex flex-col gap-4 max-w-2xl">
      <div class="flex items-center gap-2 text-sm">
        <span class="font-medium">{{
          t('WHATSAPP_WEB_INBOX.STATUS.LABEL')
        }}</span>
        <span data-testid="connection-status">{{ statusLabel }}</span>
      </div>

      <div
        v-if="!connectorAvailable"
        class="p-4 rounded-lg bg-n-slate-3 text-sm"
      >
        {{ t('WHATSAPP_WEB_INBOX.CREATE.CONNECTOR_UNAVAILABLE') }}
      </div>

      <!-- Connected: success + native continue -->
      <div v-else-if="isConnected" class="flex flex-col gap-3">
        <div
          class="p-4 rounded-lg border border-green-300 bg-green-50 dark:border-green-700 dark:bg-green-900/30"
        >
          <p class="font-semibold text-green-800 dark:text-green-200 m-0">
            {{ t('WHATSAPP_WEB_INBOX.CONNECTED.TITLE') }}
          </p>
          <p class="text-sm text-green-700 dark:text-green-200 m-0">
            {{ t('WHATSAPP_WEB_INBOX.CONNECTED.BODY') }}
          </p>
        </div>
        <div>
          <NextButton
            solid
            blue
            :label="t('WHATSAPP_WEB_INBOX.CONNECTED.CONTINUE')"
            @click="goToAgents"
          />
        </div>
      </div>

      <!-- Pairing could not be started: actionable, intentional retry (no auto-spin) -->
      <div v-else-if="connectError" class="flex flex-col gap-3">
        <p class="text-sm text-ruby-600 m-0">
          {{ t('WHATSAPP_WEB_INBOX.CREATE.CONNECT_ERROR') }}
        </p>
        <div>
          <NextButton
            solid
            blue
            :label="t('WHATSAPP_WEB_INBOX.CREATE.RETRY_CONNECT')"
            data-testid="retry-connect"
            @click="retryConnect"
          />
        </div>
      </div>

      <!-- Awaiting / scanning QR -->
      <div v-else class="flex flex-col gap-3">
        <p class="text-sm m-0">
          {{ t('WHATSAPP_WEB_INBOX.QR.INSTRUCTIONS') }}
        </p>
        <img
          v-if="qrDataUrl"
          :src="qrDataUrl"
          :alt="t('WHATSAPP_WEB_INBOX.QR.ALT')"
          class="w-56 h-56 rounded-lg border border-n-weak bg-white p-2"
          data-testid="qr-image"
        />
        <p v-else class="text-sm text-n-slate-11 m-0">
          {{ t('WHATSAPP_WEB_INBOX.QR.WAITING') }}
        </p>
      </div>
    </div>
  </div>
</template>
