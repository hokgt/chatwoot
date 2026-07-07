<script setup>
/* eslint-disable no-use-before-define */
// WIJAYA_CUSTOM_START erp_lead_sidebar
import { computed, reactive, ref, watch } from 'vue';
import ErpLeadDraftsAPI from 'dashboard/api/wijayaErpLeadDrafts';
import {
  STATUS_OPTIONS,
  MARKET_CUSTOMER_OPTIONS,
  JENIS_PAKAIAN_OPTIONS,
} from './fieldConfig';
import {
  AGENT_TO_ERP_USER,
  SOURCE_MAPPING,
  CAMPAIGN_MAPPING,
  INDUSTRY_OPTIONS,
  TERRITORY_OPTIONS,
  UTM_SOURCE_OPTIONS,
  UTM_CAMPAIGN_OPTIONS,
} from './mappings';

const props = defineProps({
  conversationId: { type: [Number, String], required: true },
  currentChat: { type: Object, default: () => ({}) },
  contact: { type: Object, default: () => ({}) },
});

const fields = reactive({
  lead_owner: '',
  first_name: '',
  company_name: '',
  whatsapp_no: '',
  mobile_no: '',
  status: 'Lead',
  utm_source: '',
  industry: '',
  territory: '',
  utm_campaign: '',
});

[...MARKET_CUSTOMER_OPTIONS, ...JENIS_PAKAIAN_OPTIONS].forEach(([, key]) => {
  fields[key] = false;
});

// Dropdown options are fetched live from their ERPNext source DocTypes (see
// backend OptionsService). The static arrays from mappings.js are only an
// offline fallback until the ERP fetch resolves.
const sourceOptions = ref([...UTM_SOURCE_OPTIONS]);
const campaignOptions = ref([...UTM_CAMPAIGN_OPTIONS]);
const industryOptions = ref([...INDUSTRY_OPTIONS]);
const territoryOptions = ref([...TERRITORY_OPTIONS]);

// One-shot guard so options are fetched a single time per panel and never on
// every autosave. Reset on failure so a later conversation switch can retry.
let optionsLoaded = false;

const loadOptions = async () => {
  if (optionsLoaded) return;
  optionsLoaded = true;
  try {
    const { data } = await ErpLeadDraftsAPI.options();
    const opts = data.options || {};
    if (opts.utm_source?.length) sourceOptions.value = opts.utm_source;
    if (opts.utm_campaign?.length) campaignOptions.value = opts.utm_campaign;
    if (opts.industry?.length) industryOptions.value = opts.industry;
    if (opts.territory?.length) territoryOptions.value = opts.territory;
  } catch {
    // Best-effort: keep the static fallback options if ERP is unreachable.
    optionsLoaded = false;
  }
};

const loading = ref(false);
const saving = ref(false);
const syncing = ref(false);
const error = ref('');
const savedAt = ref(null);
const syncStatus = ref('draft');
const erpLeadId = ref('');
let saveTimer = null;

const messages = computed(
  () => props.currentChat?.messages || props.currentChat?.payload || []
);

const adsReferral = computed(() => {
  const hit = messages.value.find(
    message => message?.content_attributes?.ads_referral
  );
  return hit?.content_attributes?.ads_referral || {};
});

const assignee = computed(() => props.currentChat?.meta?.assignee || {});
const contactName = computed(
  () => props.contact?.name || props.currentChat?.meta?.sender?.name || ''
);
const contactPhone = computed(
  () =>
    props.contact?.phone_number ||
    props.currentChat?.meta?.sender?.phone_number ||
    ''
);

const campaignFromMapping = () => {
  const referral = adsReferral.value;
  const candidates = [
    referral.source_id ? `source_id:${referral.source_id}` : null,
    referral.ctwa_clid ? `ctwa_clid:${referral.ctwa_clid}` : null,
    referral.headline ? `headline:${referral.headline}` : null,
  ].filter(Boolean);
  return candidates.map(key => CAMPAIGN_MAPPING[key]).find(Boolean) || '';
};

const sourceFromMapping = () => {
  const channel = adsReferral.value.channel;
  return channel ? SOURCE_MAPPING[channel] || '' : '';
};

const leadOwnerFromMapping = () => {
  const id = assignee.value.id;
  const name = assignee.value.name;
  return (
    AGENT_TO_ERP_USER[id] ||
    AGENT_TO_ERP_USER[name] ||
    assignee.value.email ||
    ''
  );
};

const buildAutofill = () => {
  const phone = contactPhone.value || '';
  return {
    lead_owner: leadOwnerFromMapping(),
    first_name: contactName.value || '',
    company_name: '',
    whatsapp_no: phone,
    mobile_no: phone,
    status: 'Lead',
    utm_source: sourceFromMapping(),
    industry: '',
    territory: '',
    utm_campaign: campaignFromMapping(),
  };
};

const applyFields = values => {
  Object.keys(fields).forEach(key => {
    if (Object.prototype.hasOwnProperty.call(values, key)) {
      fields[key] = values[key];
    }
  });
};

const loadDraft = async () => {
  if (!props.conversationId) return;
  loading.value = true;
  error.value = '';
  try {
    const { data } = await ErpLeadDraftsAPI.show(props.conversationId);
    const existingFields = data.fields || {};
    applyFields(
      Object.keys(existingFields).length ? existingFields : buildAutofill()
    );
    syncStatus.value = data.sync_status || 'draft';
    erpLeadId.value = data.erp_lead_id || '';
    if (data.last_error) error.value = data.last_error;
    scheduleSave(0);
  } catch (e) {
    applyFields(buildAutofill());
    error.value = e?.response?.data?.error || 'Unable to load ERP Lead draft';
  } finally {
    loading.value = false;
  }
};

const draftPayload = () => ({ ...fields, mobile_no: fields.whatsapp_no });

const saveDraft = async () => {
  if (!props.conversationId) return;
  saving.value = true;
  try {
    const { data } = await ErpLeadDraftsAPI.save(
      props.conversationId,
      draftPayload()
    );
    savedAt.value = data.updated_at;
    syncStatus.value = data.sync_status || 'draft';
    erpLeadId.value = data.erp_lead_id || '';
    if (!data.last_error) error.value = '';
  } catch (e) {
    error.value = e?.response?.data?.error || 'Unable to save ERP Lead draft';
  } finally {
    saving.value = false;
  }
};

const scheduleSave = (delay = 500) => {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveDraft, delay);
};

const validationErrors = computed(() => {
  const problems = [];
  if (!fields.status) problems.push('Status is required.');
  if (!STATUS_OPTIONS.includes(fields.status))
    problems.push('Status value is not allowed.');
  if (!fields.industry)
    problems.push('Industry is required before Create Lead.');
  if (!fields.first_name && !fields.company_name) {
    problems.push('First Name or Organization Name is required.');
  }
  return problems;
});

const canSync = computed(
  () => validationErrors.value.length === 0 && !syncing.value
);

const createLead = async () => {
  await saveDraft();
  if (!canSync.value) return;
  syncing.value = true;
  error.value = '';
  try {
    const { data } = await ErpLeadDraftsAPI.sync(
      props.conversationId,
      draftPayload()
    );
    syncStatus.value = data.sync_status || 'synced';
    erpLeadId.value = data.erp_lead_id || '';
  } catch (e) {
    error.value =
      e?.response?.data?.error ||
      'ERPNext sync failed. Draft is kept for retry.';
    syncStatus.value = 'failed';
  } finally {
    syncing.value = false;
  }
};

watch(
  () => props.conversationId,
  () => {
    loadOptions();
    loadDraft();
  },
  { immediate: true }
);
// WIJAYA_CUSTOM_END erp_lead_sidebar
</script>

<template>
  <!-- eslint-disable vue/no-bare-strings-in-template, @intlify/vue-i18n/no-raw-text -->
  <!-- WIJAYA_CUSTOM_START erp_lead_sidebar -->
  <div class="flex flex-col gap-3 p-3 text-sm">
    <div v-if="loading" class="text-n-slate-11">Loading ERP Lead draft…</div>

    <template v-else>
      <div v-if="erpLeadId" class="rounded-md bg-n-teal-3 text-n-teal-11 p-2">
        ERP Lead created: <strong>{{ erpLeadId }}</strong>
      </div>
      <div v-if="error" class="rounded-md bg-n-ruby-3 text-n-ruby-11 p-2">
        {{ error }}
      </div>

      <label class="flex flex-col gap-1">
        <span>Lead Owner</span>
        <input
          v-model="fields.lead_owner"
          class="input"
          type="text"
          @input="scheduleSave()"
        />
      </label>

      <label class="flex flex-col gap-1">
        <span>First Name</span>
        <input
          v-model="fields.first_name"
          class="input"
          type="text"
          @input="scheduleSave()"
        />
      </label>

      <label class="flex flex-col gap-1">
        <span>Organization Name</span>
        <input
          v-model="fields.company_name"
          class="input"
          type="text"
          @input="scheduleSave()"
        />
      </label>

      <label class="flex flex-col gap-1">
        <span>WhatsApp</span>
        <input
          v-model="fields.whatsapp_no"
          class="input"
          type="text"
          @input="
            fields.mobile_no = fields.whatsapp_no;
            scheduleSave();
          "
        />
      </label>

      <label class="flex flex-col gap-1">
        <span>Mobile No</span>
        <input :value="fields.whatsapp_no" class="input" type="text" readonly />
        <span class="text-xs text-n-slate-10">
          Always sent with the same value as WhatsApp.
        </span>
      </label>

      <label class="flex flex-col gap-1">
        <span>Status</span>
        <select v-model="fields.status" class="input" @change="scheduleSave(0)">
          <option
            v-for="option in STATUS_OPTIONS"
            :key="option"
            :value="option"
          >
            {{ option }}
          </option>
        </select>
      </label>

      <label class="flex flex-col gap-1">
        <span>Source</span>
        <input
          v-model="fields.utm_source"
          class="input"
          list="wijaya-erp-sources"
          @input="scheduleSave()"
        />
        <datalist id="wijaya-erp-sources">
          <option
            v-for="option in sourceOptions"
            :key="option"
            :value="option"
          />
        </datalist>
      </label>

      <label class="flex flex-col gap-1">
        <span>Campaign</span>
        <input
          v-model="fields.utm_campaign"
          class="input"
          list="wijaya-erp-campaigns"
          @input="scheduleSave()"
        />
        <datalist id="wijaya-erp-campaigns">
          <option
            v-for="option in campaignOptions"
            :key="option"
            :value="option"
          />
        </datalist>
      </label>

      <label class="flex flex-col gap-1">
        <span>Industry <span class="text-n-ruby-10">*</span></span>
        <input
          v-model="fields.industry"
          class="input"
          list="wijaya-erp-industries"
          @input="scheduleSave()"
        />
        <datalist id="wijaya-erp-industries">
          <option
            v-for="option in industryOptions"
            :key="option"
            :value="option"
          />
        </datalist>
      </label>

      <label class="flex flex-col gap-1">
        <span>Territory</span>
        <input
          v-model="fields.territory"
          class="input"
          list="wijaya-erp-territories"
          @input="scheduleSave()"
        />
        <datalist id="wijaya-erp-territories">
          <option
            v-for="option in territoryOptions"
            :key="option"
            :value="option"
          />
        </datalist>
      </label>

      <div class="flex flex-col gap-2">
        <strong>Market Customer</strong>
        <label
          v-for="[label, key] in MARKET_CUSTOMER_OPTIONS"
          :key="key"
          class="flex items-center gap-2"
        >
          <input
            v-model="fields[key]"
            type="checkbox"
            @change="scheduleSave(0)"
          />
          <span>{{ label }}</span>
        </label>
      </div>

      <div class="flex flex-col gap-2">
        <strong>Jenis Pakaian</strong>
        <label
          v-for="[label, key] in JENIS_PAKAIAN_OPTIONS"
          :key="key"
          class="flex items-center gap-2"
        >
          <input
            v-model="fields[key]"
            type="checkbox"
            @change="scheduleSave(0)"
          />
          <span>{{ label }}</span>
        </label>
      </div>

      <ul v-if="validationErrors.length" class="list-disc pl-4 text-n-ruby-10">
        <li v-for="item in validationErrors" :key="item">{{ item }}</li>
      </ul>

      <button
        class="button button-primary"
        :disabled="!canSync"
        @click="createLead"
      >
        {{
          syncing
            ? 'Creating…'
            : syncStatus === 'failed'
              ? 'Retry Create Lead'
              : 'Create Lead'
        }}
      </button>
      <div class="text-xs text-n-slate-10">
        {{
          saving
            ? 'Saving draft…'
            : savedAt
              ? `Draft saved ${savedAt}`
              : 'Draft is saved locally before sync.'
        }}
      </div>
    </template>
  </div>
  <!-- WIJAYA_CUSTOM_END erp_lead_sidebar -->
</template>
