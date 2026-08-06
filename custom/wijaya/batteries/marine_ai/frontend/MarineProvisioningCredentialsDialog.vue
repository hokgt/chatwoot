<script setup>
import { ref } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
// Battery-contained translations registered as LOCAL vue-i18n messages (no core
// marine.json dependency).
import messages from './i18n/en.json';

// One-time credential popup. Intentionally does NOT bind ESC or backdrop-click
// handlers: it can only be dismissed with the explicit acknowledge button. The
// password lives here purely as a prop passed from the parent's in-memory ref and
// is never fetched from or stored by the backend.
defineProps({
  credentials: {
    type: Object,
    required: true,
  },
  // Held only in the parent's memory and passed down; cleared on acknowledge.
  password: {
    type: String,
    default: '',
  },
});

const emit = defineEmits(['acknowledge']);

const isOpen = ref(false);
// The close button stays disabled until the admin explicitly ticks the checkbox,
// so acknowledgment requires a deliberate action, not just clicking close.
const confirmed = ref(false);

const open = () => {
  confirmed.value = false;
  isOpen.value = true;
};

const acknowledge = () => {
  if (!confirmed.value) return;
  isOpen.value = false;
  emit('acknowledge');
};

defineExpose({ open });

const { t } = useI18n({
  useScope: 'local',
  messages: { en: messages },
  fallbackLocale: 'en',
});
</script>

<template>
  <div
    v-if="isOpen"
    class="fixed inset-0 z-50 flex items-center justify-center bg-n-alpha-black2 p-4"
  >
    <div
      class="flex w-full max-w-md flex-col gap-4 rounded-xl bg-n-solid-2 p-6 shadow-lg"
      role="dialog"
      aria-modal="true"
    >
      <div class="flex flex-col gap-1">
        <h3 class="text-base font-medium text-n-slate-12">
          {{ t('MARINE_AI.PROVISIONING.CREDENTIALS_DIALOG.TITLE') }}
        </h3>
        <p class="text-sm text-n-ruby-11">
          {{ t('MARINE_AI.PROVISIONING.CREDENTIALS_DIALOG.WARNING') }}
        </p>
      </div>
      <dl class="grid grid-cols-1 gap-2 text-sm">
        <div
          v-for="row in [
            {
              key: 'HOST',
              value: credentials.host,
            },
            { key: 'PORT', value: credentials.port },
            { key: 'DATABASE', value: credentials.database_name },
            { key: 'USERNAME', value: credentials.login_username },
            { key: 'SSL_MODE', value: credentials.ssl_mode },
          ]"
          :key="row.key"
          class="flex items-center justify-between gap-3 rounded-lg border border-n-weak px-3 py-2"
        >
          <dt class="text-n-slate-11">
            {{ t(`MARINE_AI.PROVISIONING.CREDENTIALS_DIALOG.${row.key}`) }}
          </dt>
          <dd class="font-medium text-n-slate-12 break-all">{{ row.value }}</dd>
        </div>
        <div
          class="flex items-center justify-between gap-3 rounded-lg border border-n-ruby-6 px-3 py-2"
        >
          <dt class="text-n-slate-11">
            {{ t('MARINE_AI.PROVISIONING.CREDENTIALS_DIALOG.PASSWORD') }}
          </dt>
          <dd class="font-mono font-medium text-n-slate-12 break-all">
            {{ password }}
          </dd>
        </div>
      </dl>
      <label class="flex items-start gap-2 text-sm text-n-slate-11">
        <input v-model="confirmed" type="checkbox" class="mt-0.5" />
        <span>
          {{
            t('MARINE_AI.PROVISIONING.CREDENTIALS_DIALOG.ACKNOWLEDGE_CHECKBOX')
          }}
        </span>
      </label>
      <div class="flex justify-end">
        <Button
          :label="t('MARINE_AI.PROVISIONING.CREDENTIALS_DIALOG.ACKNOWLEDGE')"
          :disabled="!confirmed"
          @click="acknowledge"
        />
      </div>
    </div>
  </div>
</template>
