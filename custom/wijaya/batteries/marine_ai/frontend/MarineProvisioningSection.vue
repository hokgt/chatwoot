<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { useStoreGetters } from 'dashboard/composables/store';
import MarineProvisioningAPI from './provisioning';

import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import MarineSettingsHeader from 'dashboard/routes/dashboard/marine/components/MarineSettingsHeader.vue';
import MarineProvisioningCredentialsDialog from './MarineProvisioningCredentialsDialog.vue';
// Battery-contained translations: this feature does not touch the core marine.json.
// Messages are registered as LOCAL vue-i18n messages for this component only.
import messages from './i18n/en.json';

const { t } = useI18n({
  useScope: 'local',
  messages: { en: messages },
  fallbackLocale: 'en',
});
const { isAdmin } = useAdmin();
const getters = useStoreGetters();

// Provisioning is installation-wide, so mirror the backend gate exactly: only a
// Chatwoot installation SuperAdmin who is ALSO an account administrator may see or
// fetch this section. The backend policy is the real authority; this only hides UI.
const isSuperAdmin = computed(
  () => getters.getCurrentUser.value?.type === 'SuperAdmin'
);
const canManageProvisioning = computed(
  () => isAdmin.value && isSuperAdmin.value
);

const status = ref({
  status: 'not_provisioned',
  provisioning_configured: false,
});
const isFetching = ref(false);
const isCreating = ref(false);
const isWorking = ref(false);

const form = ref({ databaseName: '', loginUsername: '', password: '' });

// The submitted password is retained ONLY here, in memory, until the one-time
// popup is acknowledged. It is never persisted and never re-fetched.
const pendingPassword = ref('');
const pendingCredentials = ref(null);
const credentialsDialog = ref(null);

const confirmDialog = ref(null);
const confirmConfig = ref({ title: '', body: '', action: null });

const privileges = ref(null);

const isProvisioned = computed(() => status.value.status === 'active');
const needsCleanup = computed(
  () => status.value.status === 'needs_manual_cleanup'
);
const isConfigured = computed(() => status.value.provisioning_configured);

// Downgrade is only valid from the admin state; Revoke is idempotent but pointless
// once already revoked. Mirror the backend state guards in the UI.
const canDowngrade = computed(() => status.value.privilege_level === 'admin');
const canRevoke = computed(() => status.value.privilege_level !== 'revoked');

const statusLabel = computed(() => {
  const map = {
    active: 'MARINE_AI.PROVISIONING.STATUS.ACTIVE',
    needs_manual_cleanup: 'MARINE_AI.PROVISIONING.STATUS.NEEDS_MANUAL_CLEANUP',
    not_provisioned: 'MARINE_AI.PROVISIONING.STATUS.NOT_PROVISIONED',
  };
  return t(map[status.value.status] || map.not_provisioned);
});

const privilegeLevelLabel = computed(() => {
  const level = status.value.privilege_level;
  return level
    ? t(`MARINE_AI.PROVISIONING.PRIVILEGE_LEVELS.${level}`)
    : t('MARINE_AI.PROVISIONING.STATUS.NOT_PROVISIONED');
});

const errorMessage = error =>
  error?.response?.data?.error ||
  t('MARINE_AI.PROVISIONING.ALERTS.GENERIC_ERROR');

const fetchStatus = async () => {
  isFetching.value = true;
  try {
    const { data } = await MarineProvisioningAPI.getStatus();
    status.value = data;
  } catch (error) {
    useAlert(errorMessage(error));
  } finally {
    isFetching.value = false;
  }
};

const handleCreate = async () => {
  isCreating.value = true;
  try {
    const { data } = await MarineProvisioningAPI.create(form.value);
    // Move the password into the one-time popup and drop it from the form fields.
    pendingPassword.value = form.value.password;
    pendingCredentials.value = data.credentials;
    form.value = { databaseName: '', loginUsername: '', password: '' };
    status.value = data.status;
    // The dialog child is behind `v-if="pendingCredentials"`, so it only mounts
    // AFTER the assignment above flushes. Wait for that DOM update before calling
    // open(), otherwise `credentialsDialog.value` is still null in this same tick.
    await nextTick();
    credentialsDialog.value?.open();
  } catch (error) {
    useAlert(errorMessage(error));
  } finally {
    isCreating.value = false;
  }
};

const clearPendingSecret = () => {
  pendingPassword.value = '';
  pendingCredentials.value = null;
};

const handleAcknowledge = () => {
  // Clear the in-memory password once the admin confirms they've stored it.
  clearPendingSecret();
  useAlert(t('MARINE_AI.PROVISIONING.ALERTS.CREATE_SUCCESS'));
};

const openConfirm = (title, body, action) => {
  confirmConfig.value = { title, body, action };
  confirmDialog.value?.open();
};

const runConfirmed = async () => {
  const action = confirmConfig.value.action;
  if (!action) return;
  isWorking.value = true;
  try {
    await action();
  } finally {
    isWorking.value = false;
    confirmDialog.value?.close();
  }
};

const handleDowngrade = () =>
  openConfirm(
    t('MARINE_AI.PROVISIONING.CONFIRM.DOWNGRADE_TITLE'),
    t('MARINE_AI.PROVISIONING.CONFIRM.DOWNGRADE_BODY'),
    async () => {
      try {
        const { data } = await MarineProvisioningAPI.downgrade();
        status.value = data;
        privileges.value = null;
        useAlert(t('MARINE_AI.PROVISIONING.ALERTS.DOWNGRADE_SUCCESS'));
      } catch (error) {
        useAlert(errorMessage(error));
      }
    }
  );

const handleRevoke = () =>
  openConfirm(
    t('MARINE_AI.PROVISIONING.CONFIRM.REVOKE_TITLE'),
    t('MARINE_AI.PROVISIONING.CONFIRM.REVOKE_BODY'),
    async () => {
      try {
        const { data } = await MarineProvisioningAPI.revokeAll();
        status.value = data;
        privileges.value = null;
        useAlert(t('MARINE_AI.PROVISIONING.ALERTS.REVOKE_SUCCESS'));
      } catch (error) {
        useAlert(errorMessage(error));
      }
    }
  );

const handleShowPrivileges = async () => {
  isWorking.value = true;
  try {
    const { data } = await MarineProvisioningAPI.privileges();
    privileges.value = data;
  } catch (error) {
    useAlert(errorMessage(error));
  } finally {
    isWorking.value = false;
  }
};

const M = 'MARINE_AI.PROVISIONING.PRIVILEGES.MATRIX';

const yesNo = value => t(value ? `${M}.YES` : `${M}.NO`);

// A single table privilege is reported across ALL vs ANY marine_ai tables, so a
// bare "Yes" can't hide the fact that only some tables are covered.
const allAny = priv =>
  priv
    ? `${t(`${M}.ALL`)}: ${yesNo(priv.all)} · ${t(`${M}.ANY`)}: ${yesNo(priv.any)}`
    : yesNo(false);

// The Chatwoot CONNECT check can come back unknown (null) when the catalog query
// itself failed. Surface that explicitly rather than a fabricated Yes/No.
const chatwootConnectValue = db =>
  db.chatwoot_connect_check_error || db.chatwoot_connect === null
    ? t(`${M}.UNKNOWN`)
    : yesNo(db.chatwoot_connect);

const privilegeRows = computed(() => {
  const p = privileges.value;
  if (!p) return [];
  const role = p.role || {};
  const memberships = p.memberships || {};
  const db = p.database || {};
  const tables = p.tables || {};
  const functions = p.functions || {};
  const sequences = p.sequences || {};
  const ssl = p.ssl || {};
  const rows = [
    { label: t(`${M}.CAN_LOGIN`), value: yesNo(role.can_login) },
    { label: t(`${M}.SUPERUSER`), value: yesNo(role.superuser) },
    { label: t(`${M}.CREATE_ROLE`), value: yesNo(role.create_role) },
    { label: t(`${M}.CREATE_DB`), value: yesNo(role.create_db) },
    { label: t(`${M}.REPLICATION`), value: yesNo(role.replication) },
    { label: t(`${M}.BYPASS_RLS`), value: yesNo(role.bypass_rls) },
    { label: t(`${M}.MEMBERSHIPS`), value: String(memberships.count ?? 0) },
    {
      label: `${t(`${M}.DATABASE`)} · ${t(`${M}.CONNECT`)}`,
      value: yesNo(db.connect),
    },
    {
      label: `${t(`${M}.DATABASE`)} · ${t(`${M}.CREATE`)}`,
      value: yesNo(db.create),
    },
    {
      label: `${t(`${M}.DATABASE`)} · ${t(`${M}.TEMPORARY`)}`,
      value: yesNo(db.temporary),
    },
    { label: t(`${M}.CHATWOOT_CONNECT`), value: chatwootConnectValue(db) },
  ];
  (p.schemas || []).forEach(schema => {
    rows.push({
      label: `${t(`${M}.SCHEMA`, { name: schema.name })} · ${t(`${M}.USAGE`)}`,
      value: yesNo(schema.usage),
    });
    rows.push({
      label: `${t(`${M}.SCHEMA`, { name: schema.name })} · ${t(`${M}.CREATE`)}`,
      value: yesNo(schema.create),
    });
  });
  rows.push({
    label: `${t(`${M}.TABLES`, { schema: tables.schema })} · ${t(`${M}.TABLE_COUNT`)}`,
    value: String(tables.total ?? 0),
  });
  ['SELECT', 'INSERT', 'UPDATE', 'DELETE'].forEach(priv => {
    rows.push({
      label: `${t(`${M}.TABLES`, { schema: tables.schema })} · ${t(`${M}.${priv}`)}`,
      value: allAny(tables[priv.toLowerCase()]),
    });
  });
  rows.push({
    label: `${t(`${M}.TABLES`, { schema: tables.schema })} · ${t(`${M}.TRUNCATE`)}`,
    value: `${t(`${M}.ANY`)}: ${yesNo(tables.truncate?.any)}`,
  });
  rows.push({
    label: t(`${M}.FUNCTIONS_EXECUTE`),
    value: yesNo(functions.execute_any),
  });
  rows.push({
    label: t(`${M}.SEQUENCES_PRIVS`),
    value: yesNo(
      sequences.usage_any || sequences.select_any || sequences.update_any
    ),
  });
  rows.push({
    label: t(`${M}.OWNED_OBJECTS`),
    value: String(p.owned_objects ?? 0),
  });
  rows.push({
    label: t(`${M}.SSL_IN_USE`),
    value: ssl.in_use === null ? t(`${M}.UNKNOWN`) : yesNo(ssl.in_use),
  });
  rows.push({
    label: t(`${M}.SSL_CONFIGURED`),
    value: ssl.configured_mode || t(`${M}.UNKNOWN`),
  });
  return rows;
});

onMounted(() => {
  if (canManageProvisioning.value) fetchStatus();
});

// Never let the plaintext password outlive the component. The one-time popup secret
// is cleared, and the form password (which may legitimately linger for retry after a
// normal create error) is explicitly blanked on destroy.
onUnmounted(() => {
  clearPendingSecret();
  form.value.password = '';
});
</script>

<template>
  <div v-if="canManageProvisioning" class="flex flex-col gap-8">
    <div class="flex flex-col gap-4">
      <MarineSettingsHeader
        :heading="t('MARINE_AI.PROVISIONING.TITLE')"
        :description="t('MARINE_AI.PROVISIONING.DESCRIPTION')"
      />

      <div
        v-if="!isConfigured"
        class="rounded-lg border border-n-amber-6 bg-n-amber-2 px-3 py-2 text-sm text-n-amber-11"
      >
        {{ t('MARINE_AI.PROVISIONING.NOT_CONFIGURED') }}
      </div>

      <dl class="grid gap-2 text-sm sm:grid-cols-2">
        <div
          class="flex items-center justify-between gap-3 rounded-lg border border-n-weak px-3 py-2"
        >
          <dt class="text-n-slate-11">
            {{ t('MARINE_AI.PROVISIONING.STATUS.TITLE') }}
          </dt>
          <dd
            class="font-medium"
            :class="needsCleanup ? 'text-n-ruby-11' : 'text-n-slate-12'"
          >
            {{ statusLabel }}
          </dd>
        </div>
        <div
          v-if="isProvisioned || needsCleanup"
          class="flex items-center justify-between gap-3 rounded-lg border border-n-weak px-3 py-2"
        >
          <dt class="text-n-slate-11">
            {{ t('MARINE_AI.PROVISIONING.STATUS.DATABASE_NAME') }}
          </dt>
          <dd class="font-medium text-n-slate-12 break-all">
            {{ status.database_name }}
          </dd>
        </div>
        <div
          v-if="isProvisioned || needsCleanup"
          class="flex items-center justify-between gap-3 rounded-lg border border-n-weak px-3 py-2"
        >
          <dt class="text-n-slate-11">
            {{ t('MARINE_AI.PROVISIONING.STATUS.LOGIN_USERNAME') }}
          </dt>
          <dd class="font-medium text-n-slate-12 break-all">
            {{ status.login_username }}
          </dd>
        </div>
        <div
          v-if="isProvisioned"
          class="flex items-center justify-between gap-3 rounded-lg border border-n-weak px-3 py-2"
        >
          <dt class="text-n-slate-11">
            {{ t('MARINE_AI.PROVISIONING.STATUS.PRIVILEGE_LEVEL') }}
          </dt>
          <dd class="font-medium text-n-slate-12">{{ privilegeLevelLabel }}</dd>
        </div>
      </dl>

      <form
        v-if="!isProvisioned && !needsCleanup"
        class="flex flex-col gap-4"
        @submit.prevent="handleCreate"
      >
        <label class="flex flex-col gap-1 text-sm">
          <span class="text-n-slate-11">
            {{ t('MARINE_AI.PROVISIONING.FORM.DATABASE_NAME_LABEL') }}
          </span>
          <input
            v-model="form.databaseName"
            type="text"
            required
            :disabled="!isConfigured || isCreating"
            :placeholder="
              t('MARINE_AI.PROVISIONING.FORM.DATABASE_NAME_PLACEHOLDER')
            "
            class="rounded-lg border border-n-weak bg-n-alpha-black1 px-3 py-2 text-n-slate-12"
          />
        </label>
        <label class="flex flex-col gap-1 text-sm">
          <span class="text-n-slate-11">
            {{ t('MARINE_AI.PROVISIONING.FORM.LOGIN_USERNAME_LABEL') }}
          </span>
          <input
            v-model="form.loginUsername"
            type="text"
            required
            :disabled="!isConfigured || isCreating"
            :placeholder="
              t('MARINE_AI.PROVISIONING.FORM.LOGIN_USERNAME_PLACEHOLDER')
            "
            class="rounded-lg border border-n-weak bg-n-alpha-black1 px-3 py-2 text-n-slate-12"
          />
        </label>
        <label class="flex flex-col gap-1 text-sm">
          <span class="text-n-slate-11">
            {{ t('MARINE_AI.PROVISIONING.FORM.LOGIN_PASSWORD_LABEL') }}
          </span>
          <input
            v-model="form.password"
            type="password"
            required
            autocomplete="new-password"
            :disabled="!isConfigured || isCreating"
            :placeholder="
              t('MARINE_AI.PROVISIONING.FORM.LOGIN_PASSWORD_PLACEHOLDER')
            "
            class="rounded-lg border border-n-weak bg-n-alpha-black1 px-3 py-2 text-n-slate-12"
          />
        </label>
        <span class="text-xs text-n-slate-10">
          {{ t('MARINE_AI.PROVISIONING.FORM.HELP') }}
        </span>
        <div>
          <Button
            type="submit"
            :label="
              isCreating
                ? t('MARINE_AI.PROVISIONING.FORM.CREATING')
                : t('MARINE_AI.PROVISIONING.FORM.CREATE_BUTTON')
            "
            :is-loading="isCreating"
            :disabled="!isConfigured || isCreating"
            class="!w-fit"
          />
        </div>
      </form>
    </div>

    <div v-if="isProvisioned" class="flex flex-col gap-4">
      <MarineSettingsHeader
        :heading="t('MARINE_AI.PROVISIONING.PRIVILEGES.TITLE')"
        :description="t('MARINE_AI.PROVISIONING.PRIVILEGES.DESCRIPTION')"
      />
      <div class="flex flex-wrap gap-3">
        <Button
          :label="t('MARINE_AI.PROVISIONING.PRIVILEGES.SHOW_BUTTON')"
          variant="outline"
          :disabled="isWorking"
          @click="handleShowPrivileges"
        />
        <Button
          :label="t('MARINE_AI.PROVISIONING.PRIVILEGES.DOWNGRADE_BUTTON')"
          variant="outline"
          :disabled="isWorking || !canDowngrade"
          @click="handleDowngrade"
        />
        <Button
          :label="t('MARINE_AI.PROVISIONING.PRIVILEGES.REVOKE_BUTTON')"
          color="ruby"
          :disabled="isWorking || !canRevoke"
          @click="handleRevoke"
        />
      </div>

      <dl v-if="privileges" class="grid gap-2 text-sm sm:grid-cols-2">
        <div
          v-for="row in privilegeRows"
          :key="row.label"
          class="flex items-center justify-between gap-3 rounded-lg border border-n-weak px-3 py-2"
        >
          <dt class="text-n-slate-11">{{ row.label }}</dt>
          <dd class="font-medium text-n-slate-12">{{ row.value }}</dd>
        </div>
      </dl>
    </div>

    <MarineProvisioningCredentialsDialog
      v-if="pendingCredentials"
      ref="credentialsDialog"
      :credentials="pendingCredentials"
      :password="pendingPassword"
      @acknowledge="handleAcknowledge"
    />

    <Dialog
      ref="confirmDialog"
      type="alert"
      :title="confirmConfig.title"
      :description="confirmConfig.body"
      :confirm-button-label="t('MARINE_AI.PROVISIONING.CONFIRM.CONFIRM')"
      :cancel-button-label="t('MARINE_AI.PROVISIONING.CONFIRM.CANCEL')"
      :is-loading="isWorking"
      @confirm="runConfirmed"
    />
  </div>
</template>
