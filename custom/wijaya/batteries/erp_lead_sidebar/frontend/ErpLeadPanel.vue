<script setup>
/* eslint-disable no-use-before-define */
// WIJAYA_CUSTOM_START erp_lead_sidebar
import {
  computed,
  defineComponent,
  h,
  onBeforeUnmount,
  onMounted,
  reactive,
  ref,
  watch,
} from 'vue';
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

const applyOptions = options => {
  const opts = options || {};
  if (opts.utm_source?.length) sourceOptions.value = opts.utm_source;
  if (opts.utm_campaign?.length) campaignOptions.value = opts.utm_campaign;
  if (opts.industry?.length) industryOptions.value = opts.industry;
  if (opts.territory?.length) territoryOptions.value = opts.territory;
};

// The dropdowns are now real <select> controls, so a stored value that is not
// among the ERP options (e.g. the legacy "WhatsApp" autofill, or a value still
// loading behind the offline fallback) would otherwise vanish from the UI. We
// surface it as a temporary leading option instead of silently dropping or
// clearing it: the agent can see the current value and consciously pick a valid
// ERP option, and nothing invalid is persisted without being shown.
const withCurrent = (value, options) =>
  value && !options.includes(value) ? [value, ...options] : options;

// Local searchable dropdown so agents can type-to-filter long ERP option lists
// (Source/Campaign/Industry/Territory) instead of scrolling a native select.
// Kept inline as a render-function component to stay within this single-file
// customization: props/emits mirror a native select (v-model + change).
const SearchableSelect = defineComponent({
  name: 'SearchableSelect',
  props: {
    modelValue: { type: String, default: '' },
    options: { type: Array, default: () => [] },
    placeholder: { type: String, default: 'Search…' },
  },
  emits: ['update:modelValue', 'change'],
  setup(selectProps, { emit }) {
    const open = ref(false);
    const query = ref('');
    const highlight = ref(-1);
    const rootEl = ref(null);
    // Selecting an option commits on mousedown, which fires before the trailing
    // focus/click on the input. This guard swallows that immediate follow-up so
    // the menu does not close-then-reopen; it is released on the next tick.
    let suppressReopen = false;

    const displayOptions = computed(() => ['', ...selectProps.options]);

    const optionLabel = option =>
      option === '' ? '— Clear —' : String(option);

    const filtered = computed(() => {
      const q = query.value.trim().toLowerCase();
      if (!q) return displayOptions.value;
      return displayOptions.value.filter(option =>
        optionLabel(option).toLowerCase().includes(q)
      );
    });

    const close = () => {
      open.value = false;
      query.value = '';
      highlight.value = -1;
    };

    const openMenu = () => {
      if (suppressReopen) return;
      open.value = true;
      query.value = '';
      highlight.value = -1;
    };

    const select = option => {
      emit('update:modelValue', option);
      emit('change', option);
      close();
      // Block the focus/click that follows an option mousedown from reopening
      // the menu; release on the next tick so genuine reopens still work.
      suppressReopen = true;
      setTimeout(() => {
        suppressReopen = false;
      }, 0);
    };

    const onEnter = () => {
      const list = filtered.value;
      if (!list.length) return;
      if (highlight.value >= 0 && highlight.value < list.length) {
        select(list[highlight.value]);
        return;
      }
      const q = query.value.trim().toLowerCase();
      const exact = list.find(option => String(option).toLowerCase() === q);
      select(exact || list[0]);
    };

    const move = delta => {
      const len = filtered.value.length;
      if (!len) return;
      open.value = true;
      highlight.value = (highlight.value + delta + len) % len;
    };

    const onDocClick = event => {
      if (rootEl.value && !rootEl.value.contains(event.target)) close();
    };
    onMounted(() => document.addEventListener('click', onDocClick));
    onBeforeUnmount(() => document.removeEventListener('click', onDocClick));

    return () =>
      h('div', { ref: rootEl, class: 'relative' }, [
        h('input', {
          class: 'input',
          type: 'text',
          value: open.value ? query.value : selectProps.modelValue,
          placeholder: selectProps.modelValue || selectProps.placeholder,
          onFocus: openMenu,
          onClick: openMenu,
          onInput: event => {
            query.value = event.target.value;
            open.value = true;
            highlight.value = -1;
          },
          onKeydown: event => {
            if (event.key === 'Escape') {
              close();
            } else if (event.key === 'Enter') {
              event.preventDefault();
              onEnter();
            } else if (event.key === 'ArrowDown') {
              event.preventDefault();
              move(1);
            } else if (event.key === 'ArrowUp') {
              event.preventDefault();
              move(-1);
            }
          },
        }),
        open.value
          ? h(
              'ul',
              {
                class:
                  'absolute left-0 right-0 z-50 mt-1 max-h-48 overflow-y-auto rounded-md border border-n-weak bg-n-solid-1 py-1 shadow-lg',
              },
              filtered.value.length
                ? filtered.value.map((option, index) =>
                    h(
                      'li',
                      {
                        key: option || '__empty__',
                        class: [
                          'cursor-pointer px-2 py-1 text-n-slate-12',
                          index === highlight.value
                            ? 'bg-n-alpha-2'
                            : 'hover:bg-n-alpha-1',
                        ],
                        onMousedown: event => {
                          // Commit selection here (before blur/click) and keep
                          // input focus by preventing the default focus shift.
                          event.preventDefault();
                          select(option);
                        },
                        onMouseenter: () => {
                          highlight.value = index;
                        },
                      },
                      optionLabel(option)
                    )
                  )
                : [
                    h(
                      'li',
                      { class: 'px-2 py-1 text-n-slate-10' },
                      'No matches'
                    ),
                  ]
            )
          : null,
      ]);
  },
});

const loading = ref(false);
const saving = ref(false);
const syncing = ref(false);
const error = ref('');
const savedAt = ref(null);
const syncStatus = ref('draft');
const erpLeadId = ref('');
// ERP freshness reconciliation surfaced by the backend RefreshService on load:
// `refreshMessage` explains whether local fields were refreshed from ERP or kept,
// and `conflict` flags the "local unsynced draft vs newer ERP data" case so the
// banner renders as a warning the agent must resolve via Update Lead.
const refreshMessage = ref('');
const conflict = ref(false);
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
    applyOptions(data.options);
    const existingFields = data.fields || {};
    const hasExisting = Object.keys(existingFields).length > 0;
    // Stored/ERP-refreshed fields are applied as-is; only a first-time draft with
    // no stored fields falls back to client autofill.
    applyFields(hasExisting ? existingFields : buildAutofill());
    syncStatus.value = data.sync_status || 'draft';
    erpLeadId.value = data.erp_lead_id || '';
    refreshMessage.value = data.message || '';
    conflict.value = Boolean(data.conflict);
    if (data.last_error) error.value = data.last_error;
    // Only autosave the generated autofill for a brand-new draft. Opening an
    // existing (incl. ERP-refreshed) draft must NOT mark it dirty.
    if (!hasExisting) scheduleSave(0);
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
    // Sync succeeded: the local draft was pushed to ERP, so the stale
    // "local unsynced draft vs newer ERP data" conflict no longer applies.
    // Clear the warning banner and surface a success/info message instead.
    conflict.value = Boolean(data.conflict);
    refreshMessage.value =
      data.message ||
      (erpLeadId.value
        ? `ERP Lead ${erpLeadId.value} updated successfully.`
        : 'ERP Lead synced successfully.');
    error.value = data.last_error || '';
  } catch (e) {
    error.value =
      e?.response?.data?.error ||
      'ERPNext sync failed. Draft is kept for retry.';
    syncStatus.value = 'failed';
  } finally {
    syncing.value = false;
  }
};

watch(() => props.conversationId, loadDraft, { immediate: true });
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
      <div v-if="conflict" class="rounded-md bg-n-amber-3 text-n-amber-11 p-2">
        {{ refreshMessage }}
      </div>
      <div
        v-else-if="refreshMessage"
        class="rounded-md bg-n-teal-3 text-n-teal-11 p-2"
      >
        {{ refreshMessage }}
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
        <SearchableSelect
          v-model="fields.utm_source"
          :options="withCurrent(fields.utm_source, sourceOptions)"
          @change="scheduleSave(0)"
        />
      </label>

      <label class="flex flex-col gap-1">
        <span>Campaign</span>
        <SearchableSelect
          v-model="fields.utm_campaign"
          :options="withCurrent(fields.utm_campaign, campaignOptions)"
          @change="scheduleSave(0)"
        />
      </label>

      <label class="flex flex-col gap-1">
        <span>Industry <span class="text-n-ruby-10">*</span></span>
        <SearchableSelect
          v-model="fields.industry"
          :options="withCurrent(fields.industry, industryOptions)"
          @change="scheduleSave(0)"
        />
      </label>

      <label class="flex flex-col gap-1">
        <span>Territory</span>
        <SearchableSelect
          v-model="fields.territory"
          :options="withCurrent(fields.territory, territoryOptions)"
          @change="scheduleSave(0)"
        />
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
            ? erpLeadId
              ? 'Updating…'
              : 'Creating…'
            : syncStatus === 'failed'
              ? erpLeadId
                ? 'Retry Update Lead'
                : 'Retry Create Lead'
              : erpLeadId
                ? 'Update Lead'
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
