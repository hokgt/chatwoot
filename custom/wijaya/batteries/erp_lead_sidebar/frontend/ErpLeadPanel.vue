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
import ErpLeadDraftsAPI from '@wijaya/erp_lead_sidebar/frontend/api/wijayaErpLeadDrafts';
import LeadActivityForm from './LeadActivityForm.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
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

// The ContactPanel only mounts <ErpLeadPanel/>; the battery renders a compact
// trigger button and hosts the full form inside a standard modal. Modal
// visibility is the ONLY thing toggled here — all form state lives in this
// setup scope (see `fields`/refs below), so closing/reopening never resets it.
const panelTitle = 'ERP Lead';
const isModalOpen = ref(false);
const openModal = () => {
  isModalOpen.value = true;
};

// Two isolated views inside the same modal. 'details' is the default and hosts
// the unchanged Lead Details create/update flow; 'activity' mounts the fully
// separate LeadActivityForm (v-if, so its runtime options only fetch when the
// tab is opened). Reset to 'details' on conversation switch.
const activeTab = ref('details');

// When ERP is unconfigured the backend never persists a draft on open; mirror
// that on the client by disabling all autosave so opening the panel creates zero
// draft rows. Fail closed: stays false until the server confirms configuration.
const configured = ref(false);

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
// customization: props/emits mirror a native select (v-model + change). The
// id/describedby/invalid props are display-only association hooks so the field
// label, helper text and error can be wired to the input for assistive tech;
// they never affect selection behaviour.
const SearchableSelect = defineComponent({
  name: 'SearchableSelect',
  props: {
    modelValue: { type: String, default: '' },
    options: { type: Array, default: () => [] },
    placeholder: { type: String, default: 'Search…' },
    id: { type: String, default: '' },
    describedby: { type: String, default: '' },
    invalid: { type: Boolean, default: false },
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
          id: selectProps.id || undefined,
          role: 'combobox',
          'aria-expanded': open.value ? 'true' : 'false',
          'aria-describedby': selectProps.describedby || undefined,
          'aria-invalid': selectProps.invalid ? 'true' : undefined,
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
    configured.value = data.configured !== false;
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
  // Never autosave while ERP is unconfigured: this keeps opening/editing the
  // panel from creating draft rows until the ERP connection is set up.
  if (!configured.value) return;
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
  () =>
    configured.value && validationErrors.value.length === 0 && !syncing.value
);

const createLead = async () => {
  // Never sync while ERP is unconfigured: guard before saveDraft so no draft
  // row is persisted and no ERP request is issued from an unconfigured install.
  if (!configured.value) return;
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

// ---------------------------------------------------------------------------
// Display-only presentation derived from the existing state refs. None of the
// computeds below mutate state, change validation logic, or reprioritise the
// underlying refs — they only decide how the current state is rendered.
// ---------------------------------------------------------------------------

const STATUS_TONES = {
  info: 'bg-n-slate-3 text-n-slate-12',
  success: 'bg-n-teal-3 text-n-teal-11',
  warning: 'bg-n-amber-3 text-n-amber-11',
  danger: 'bg-n-ruby-3 text-n-ruby-11',
};

// One compact synchronization-status line. Priority is a rendering choice only:
// a single contextual message replaces the previously stacked banners, and the
// success case shows the ERP Lead id exactly once (never a "created" chip plus a
// duplicate success banner).
const leadStatus = computed(() => {
  if (loading.value)
    return {
      tone: 'info',
      text: 'Loading the ERP Lead linked to this conversation…',
    };
  if (syncing.value)
    return {
      tone: 'info',
      text: erpLeadId.value
        ? 'Updating the Lead in ERP…'
        : 'Creating the Lead in ERP…',
    };
  if (error.value) return { tone: 'danger', text: error.value };
  if (conflict.value) return { tone: 'warning', text: refreshMessage.value };
  if (syncStatus.value === 'synced' && erpLeadId.value)
    return {
      tone: 'success',
      text: refreshMessage.value || `Synced with ERP Lead ${erpLeadId.value}.`,
    };
  if (refreshMessage.value) return { tone: 'info', text: refreshMessage.value };
  if (erpLeadId.value)
    return { tone: 'info', text: `Linked to ERP Lead ${erpLeadId.value}.` };
  return { tone: 'info', text: '' };
});

const tabHelper = computed(() =>
  activeTab.value === 'activity'
    ? 'Manually record a new activity for the linked Lead.'
    : 'View and update the ERP Lead linked to this conversation.'
);

// Field-level validation copy reuses the exact same conditions/messages as
// `validationErrors`, so it can render next to the affected field without
// changing what makes the form valid.
const statusError = computed(() => {
  if (!fields.status) return 'Status is required.';
  if (!STATUS_OPTIONS.includes(fields.status))
    return 'Status value is not allowed.';
  return '';
});
const industryError = computed(() =>
  !fields.industry ? 'Industry is required before Create Lead.' : ''
);
const nameError = computed(() =>
  !fields.first_name && !fields.company_name
    ? 'First Name or Organization Name is required.'
    : ''
);

const primaryLabel = computed(() => {
  if (syncing.value) return erpLeadId.value ? 'Updating…' : 'Creating…';
  if (syncStatus.value === 'failed')
    return erpLeadId.value ? 'Retry Update Lead' : 'Retry Create Lead in ERP';
  return erpLeadId.value ? 'Update Lead' : 'Create Lead in ERP';
});

const footerActionHint = computed(() =>
  erpLeadId.value
    ? 'Pushes your changes to the linked ERP Lead in ERPNext.'
    : 'Creates a new Lead in ERPNext from these details.'
);

const disabledReason = computed(() => {
  if (syncing.value) return '';
  if (!configured.value)
    return 'Connect ERP in settings to enable creating or updating leads.';
  if (validationErrors.value.length)
    return 'Complete the required fields marked * before continuing.';
  return '';
});

const draftStatusText = computed(() => {
  if (!configured.value)
    return 'ERP is not configured, so changes are not saved yet.';
  if (saving.value) return 'Saving draft…';
  if (savedAt.value) return `Draft saved ${savedAt.value}`;
  return 'Draft is saved locally before sync.';
});

// On conversation switch, close/reset the modal and load the new conversation
// exactly once. Toggling the modal alone never re-runs this, so in-conversation
// close/reopen preserves the in-memory form state.
watch(
  () => props.conversationId,
  () => {
    isModalOpen.value = false;
    activeTab.value = 'details';
    loadDraft();
  },
  { immediate: true }
);
// WIJAYA_CUSTOM_END erp_lead_sidebar
</script>

<template>
  <!-- eslint-disable vue/no-bare-strings-in-template, @intlify/vue-i18n/no-raw-text -->
  <!-- WIJAYA_CUSTOM_START erp_lead_sidebar -->
  <div class="px-2 pb-3">
    <NextButton
      :label="panelTitle"
      icon="i-lucide-building-2"
      faded
      slate
      sm
      class="w-full"
      @click="openModal"
    />
    <woot-modal v-model:show="isModalOpen" size="medium" :on-close="() => {}">
      <woot-modal-header :header-title="panelTitle" />
      <div class="flex max-h-[80vh] flex-col text-sm">
        <!-- Guidance: what this modal is for. -->
        <p class="shrink-0 px-6 pt-3 text-xs text-n-slate-11">
          Manage the ERP Lead linked to this conversation — review its details,
          keep it in sync with ERPNext, and log activities against it.
        </p>

        <!-- Accessible tablist for the two isolated views. -->
        <div
          role="tablist"
          aria-label="ERP Lead sections"
          class="flex shrink-0 gap-1 border-b border-n-weak px-6 pt-2"
        >
          <button
            id="erp-tab-details"
            type="button"
            role="tab"
            :aria-selected="activeTab === 'details' ? 'true' : 'false'"
            aria-controls="erp-tabpanel-details"
            class="rounded-t border-b-2 px-3 py-2 font-medium outline-none focus-visible:ring-2 focus-visible:ring-n-brand"
            :class="
              activeTab === 'details'
                ? 'border-n-brand text-n-slate-12'
                : 'border-transparent text-n-slate-10 hover:text-n-slate-11'
            "
            @click="activeTab = 'details'"
          >
            Lead Details
          </button>
          <button
            id="erp-tab-activity"
            type="button"
            role="tab"
            :aria-selected="activeTab === 'activity' ? 'true' : 'false'"
            aria-controls="erp-tabpanel-activity"
            class="rounded-t border-b-2 px-3 py-2 font-medium outline-none focus-visible:ring-2 focus-visible:ring-n-brand"
            :class="
              activeTab === 'activity'
                ? 'border-n-brand text-n-slate-12'
                : 'border-transparent text-n-slate-10 hover:text-n-slate-11'
            "
            @click="activeTab = 'activity'"
          >
            Lead Activity
          </button>
        </div>

        <!-- Contextual helper for the active tab. -->
        <p class="shrink-0 px-6 pt-2 text-xs text-n-slate-11">
          {{ tabHelper }}
        </p>

        <!-- Activity tab: the form owns its own scroll body + footer, so it must
             not be wrapped in another overflow scroller here. -->
        <div
          v-if="activeTab === 'activity'"
          id="erp-tabpanel-activity"
          role="tabpanel"
          aria-labelledby="erp-tab-activity"
          class="flex min-h-0 flex-1 flex-col pt-2"
        >
          <LeadActivityForm
            :conversation-id="conversationId"
            :current-chat="currentChat"
            :erp-lead-id="erpLeadId"
            :configured="configured"
          />
        </div>

        <!-- Details tab: compact status region, a single scroll body, and a
             stable non-scrolling footer sibling below it. -->
        <div
          v-else
          id="erp-tabpanel-details"
          role="tabpanel"
          aria-labelledby="erp-tab-details"
          class="flex min-h-0 flex-1 flex-col"
        >
          <div
            v-if="leadStatus.text"
            class="mx-6 mt-3 shrink-0 rounded-md p-2 text-xs"
            :class="STATUS_TONES[leadStatus.tone]"
            role="status"
            aria-live="polite"
          >
            {{ leadStatus.text }}
          </div>

          <div
            class="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-6 pt-3 pb-6"
          >
            <p class="text-xs text-n-slate-10">
              Fields marked <span class="text-n-ruby-10">*</span> are required;
              all others are optional.
            </p>

            <section
              class="flex flex-col gap-3 rounded-lg border border-n-weak bg-n-solid-1 p-4"
            >
              <h3
                class="border-b border-n-weak pb-1 font-semibold text-n-slate-12"
              >
                Informasi Lead
              </h3>
              <div class="grid grid-cols-1 gap-x-4 gap-y-3 sm:grid-cols-2">
                <label class="flex flex-col gap-1" for="erp-lead-owner">
                  <span>Lead Owner</span>
                  <input
                    id="erp-lead-owner"
                    v-model="fields.lead_owner"
                    class="input"
                    type="text"
                    @input="scheduleSave()"
                  />
                </label>

                <label class="flex flex-col gap-1" for="erp-first-name">
                  <span>First Name</span>
                  <input
                    id="erp-first-name"
                    v-model="fields.first_name"
                    class="input"
                    type="text"
                    :aria-invalid="nameError ? 'true' : undefined"
                    aria-describedby="erp-name-help"
                    @input="scheduleSave()"
                  />
                </label>

                <label
                  class="flex flex-col gap-1 sm:col-span-2"
                  for="erp-company-name"
                >
                  <span>Organization Name</span>
                  <input
                    id="erp-company-name"
                    v-model="fields.company_name"
                    class="input"
                    type="text"
                    :aria-invalid="nameError ? 'true' : undefined"
                    aria-describedby="erp-name-help"
                    @input="scheduleSave()"
                  />
                  <span
                    id="erp-name-help"
                    class="text-xs"
                    :class="nameError ? 'text-n-ruby-10' : 'text-n-slate-10'"
                  >
                    {{
                      nameError ||
                      'Provide at least a First Name or an Organization Name.'
                    }}
                  </span>
                </label>
              </div>
            </section>

            <section
              class="flex flex-col gap-3 rounded-lg border border-n-weak bg-n-solid-1 p-4"
            >
              <h3
                class="border-b border-n-weak pb-1 font-semibold text-n-slate-12"
              >
                Kontak
              </h3>
              <div class="grid grid-cols-1 gap-x-4 gap-y-3 sm:grid-cols-2">
                <label class="flex flex-col gap-1" for="erp-whatsapp">
                  <span>WhatsApp</span>
                  <input
                    id="erp-whatsapp"
                    v-model="fields.whatsapp_no"
                    class="input"
                    type="text"
                    @input="
                      fields.mobile_no = fields.whatsapp_no;
                      scheduleSave();
                    "
                  />
                </label>

                <label class="flex flex-col gap-1" for="erp-mobile">
                  <span>Mobile No</span>
                  <input
                    id="erp-mobile"
                    :value="fields.whatsapp_no"
                    class="input"
                    type="text"
                    readonly
                    aria-describedby="erp-mobile-help"
                  />
                  <span id="erp-mobile-help" class="text-xs text-n-slate-10">
                    Read-only — mirrors WhatsApp automatically and is always
                    sent with the same value.
                  </span>
                </label>
              </div>
            </section>

            <section
              class="flex flex-col gap-3 rounded-lg border border-n-weak bg-n-solid-1 p-4"
            >
              <h3
                class="border-b border-n-weak pb-1 font-semibold text-n-slate-12"
              >
                Sumber dan Klasifikasi
              </h3>
              <div class="grid grid-cols-1 gap-x-4 gap-y-3 sm:grid-cols-2">
                <label class="flex flex-col gap-1" for="erp-status">
                  <span>Status <span class="text-n-ruby-10">*</span></span>
                  <select
                    id="erp-status"
                    v-model="fields.status"
                    class="input"
                    aria-required="true"
                    :aria-invalid="statusError ? 'true' : undefined"
                    :aria-describedby="
                      statusError ? 'erp-status-help' : undefined
                    "
                    @change="scheduleSave(0)"
                  >
                    <option
                      v-for="option in STATUS_OPTIONS"
                      :key="option"
                      :value="option"
                    >
                      {{ option }}
                    </option>
                  </select>
                  <span
                    v-if="statusError"
                    id="erp-status-help"
                    class="text-xs text-n-ruby-10"
                  >
                    {{ statusError }}
                  </span>
                </label>

                <label class="flex flex-col gap-1" for="erp-source">
                  <span>Source</span>
                  <SearchableSelect
                    id="erp-source"
                    v-model="fields.utm_source"
                    :options="withCurrent(fields.utm_source, sourceOptions)"
                    @change="scheduleSave(0)"
                  />
                </label>

                <label class="flex flex-col gap-1" for="erp-campaign">
                  <span>Campaign</span>
                  <SearchableSelect
                    id="erp-campaign"
                    v-model="fields.utm_campaign"
                    :options="withCurrent(fields.utm_campaign, campaignOptions)"
                    @change="scheduleSave(0)"
                  />
                </label>

                <label class="flex flex-col gap-1" for="erp-industry">
                  <span>Industry <span class="text-n-ruby-10">*</span></span>
                  <SearchableSelect
                    id="erp-industry"
                    v-model="fields.industry"
                    :options="withCurrent(fields.industry, industryOptions)"
                    :invalid="Boolean(industryError)"
                    :describedby="industryError ? 'erp-industry-help' : ''"
                    @change="scheduleSave(0)"
                  />
                  <span
                    v-if="industryError"
                    id="erp-industry-help"
                    class="text-xs text-n-ruby-10"
                  >
                    {{ industryError }}
                  </span>
                </label>

                <label class="flex flex-col gap-1" for="erp-territory">
                  <span>Territory</span>
                  <SearchableSelect
                    id="erp-territory"
                    v-model="fields.territory"
                    :options="withCurrent(fields.territory, territoryOptions)"
                    @change="scheduleSave(0)"
                  />
                </label>
              </div>
            </section>

            <section
              class="flex flex-col gap-3 rounded-lg border border-n-weak bg-n-solid-1 p-4"
            >
              <h3
                class="border-b border-n-weak pb-1 font-semibold text-n-slate-12"
              >
                Market Customer
              </h3>
              <div class="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3">
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
            </section>

            <section
              class="flex flex-col gap-3 rounded-lg border border-n-weak bg-n-solid-1 p-4"
            >
              <h3
                class="border-b border-n-weak pb-1 font-semibold text-n-slate-12"
              >
                Jenis Pakaian
              </h3>
              <div class="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-3">
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
            </section>
          </div>

          <!-- Non-scrolling footer: a sibling below the scroll body, not sticky
               inside it, so it can never cover the fields. -->
          <div
            class="flex shrink-0 flex-col gap-2 border-t border-n-weak bg-n-alpha-2 px-6 py-3"
          >
            <ul
              v-if="validationErrors.length"
              class="list-disc pl-4 text-xs text-n-ruby-10"
              role="alert"
            >
              <li v-for="item in validationErrors" :key="item">{{ item }}</li>
            </ul>

            <NextButton
              :label="primaryLabel"
              :is-loading="syncing"
              :disabled="!canSync"
              color="blue"
              class="w-full"
              @click="createLead"
            />

            <p class="text-xs text-n-slate-11">{{ footerActionHint }}</p>
            <p v-if="disabledReason" class="text-xs text-n-amber-11">
              {{ disabledReason }}
            </p>
            <p class="text-xs text-n-slate-10">{{ draftStatusText }}</p>
          </div>
        </div>
      </div>
    </woot-modal>
  </div>
  <!-- WIJAYA_CUSTOM_END erp_lead_sidebar -->
</template>
