<script setup>
// WIJAYA_CUSTOM_START erp_lead_sidebar
// Manual Lead Activity form, hosted inside the ERP Lead modal's "Lead Activity"
// tab. It is fully isolated from the Lead Details create/update/refresh/sync
// flow: it fetches its own runtime option list, builds its own submission, and
// only ever inserts a Lead Activity child row on an explicit agent click.
import { computed, onMounted, reactive, ref } from 'vue';
import ErpLeadActivitiesAPI from '@wijaya/erp_lead_sidebar/frontend/api/wijayaErpLeadActivities';
import NextButton from 'dashboard/components-next/button/Button.vue';
import { isRealISODate } from './dateValidation';

const props = defineProps({
  conversationId: { type: [Number, String], required: true },
  // Accepted from ErpLeadPanel for interface parity; the manual Person In Charge
  // picker no longer derives anything from the conversation assignee.
  // eslint-disable-next-line vue/no-unused-properties
  currentChat: { type: Object, default: () => ({}) },
  // The server-derived linked ERP Lead id. Submit stays disabled until a Lead
  // exists; options are only fetched for a linked, configured draft.
  erpLeadId: { type: String, default: '' },
  configured: { type: Boolean, default: false },
});

const FOLLOW_UP_VALUES = ['No', 'Yes'];

// One UUID per logical submission; retained across retries of the same form and
// regenerated only after a confirmed success.
const newSubmissionId = () => crypto.randomUUID();

const linked = computed(() => Boolean(props.erpLeadId));

const form = reactive({
  date: '',
  lead_activity: '',
  follow_up: 'No',
  follow_up_date: '',
  follow_up_activity: '',
  person_in_charge: '',
  remark: '',
});

const activityOptions = ref([]);
// Selectable ERP Users [{ value, label }] for the manual Person In Charge
// picker, plus whether the directory was reachable. When unavailable the picker
// is disabled but a blank Person In Charge may still be submitted.
const personInChargeOptions = ref([]);
const personInChargeAvailable = ref(true);
const submissionId = ref(newSubmissionId());
const loadingOptions = ref(false);
const optionsError = ref('');
// state: 'idle' | 'submitting' | 'success' | 'failure' | 'unknown'
const state = ref('idle');
const message = ref('');
const warning = ref('');
const defaultDate = ref('');

const resetActivityFields = () => {
  form.date = defaultDate.value;
  form.lead_activity = '';
  form.follow_up = 'No';
  form.follow_up_date = '';
  form.follow_up_activity = '';
  form.remark = '';
  // Person In Charge is a manual choice: reset to blank only after a success.
  form.person_in_charge = '';
};

const loadOptions = async () => {
  if (!props.configured || !linked.value) return;
  loadingOptions.value = true;
  optionsError.value = '';
  try {
    const { data } = await ErpLeadActivitiesAPI.fetchOptions(
      props.conversationId
    );
    activityOptions.value = Array.isArray(data.options) ? data.options : [];
    personInChargeOptions.value = Array.isArray(data.person_in_charge_options)
      ? data.person_in_charge_options
      : [];
    personInChargeAvailable.value = data.person_in_charge_available !== false;
    defaultDate.value = data.default_date || '';
    if (!form.date) form.date = defaultDate.value;
  } catch (e) {
    optionsError.value =
      e?.response?.data?.error ||
      'Lead Activity options are currently unavailable.';
  } finally {
    loadingOptions.value = false;
  }
};

// follow_up "No" clears + disables the follow-up fields (mirrors the backend).
const onFollowUpChange = () => {
  if (form.follow_up === 'No') {
    form.follow_up_date = '';
    form.follow_up_activity = '';
  }
};

const validationErrors = computed(() => {
  const problems = [];
  if (!form.date) problems.push('Date is required.');
  else if (!isRealISODate(form.date))
    problems.push('Date must be a valid calendar date (YYYY-MM-DD).');
  if (!form.lead_activity) problems.push('Lead Activity is required.');
  else if (!activityOptions.value.includes(form.lead_activity))
    problems.push('Lead Activity must be a known option.');
  if (!FOLLOW_UP_VALUES.includes(form.follow_up))
    problems.push('Follow Up must be No or Yes.');
  if (form.follow_up === 'Yes') {
    if (form.follow_up_date && !isRealISODate(form.follow_up_date))
      problems.push(
        'Follow Up Date must be a valid calendar date (YYYY-MM-DD).'
      );
    if (
      form.follow_up_activity &&
      !activityOptions.value.includes(form.follow_up_activity)
    )
      problems.push('Follow Up Activity must be a known option.');
  }
  return problems;
});

const canSubmit = computed(
  () =>
    props.configured &&
    linked.value &&
    validationErrors.value.length === 0 &&
    state.value !== 'submitting' &&
    // After an outcome_unknown the same submission id is retained but ERP may
    // already hold it: block further clicks so we never re-hit the API with the
    // same id. The agent must verify/reopen in ERP deliberately (no easy bypass).
    state.value !== 'unknown'
);

const submit = async () => {
  // Explicit-click only; guard against repeat clicks in flight.
  if (!canSubmit.value) return;
  state.value = 'submitting';
  message.value = '';
  warning.value = '';
  const payload = {
    submission_id: submissionId.value,
    date: form.date,
    lead_activity: form.lead_activity,
    follow_up: form.follow_up,
    follow_up_date: form.follow_up === 'Yes' ? form.follow_up_date : '',
    follow_up_activity: form.follow_up === 'Yes' ? form.follow_up_activity : '',
    person_in_charge: form.person_in_charge,
    remark: form.remark,
  };
  try {
    const { data } = await ErpLeadActivitiesAPI.create(
      props.conversationId,
      payload
    );
    state.value = 'success';
    message.value = data.message || 'Lead Activity added successfully.';
    // Success resets activity-only fields and starts a new logical submission.
    submissionId.value = newSubmissionId();
    resetActivityFields();
  } catch (e) {
    const data = e?.response?.data || {};
    if (data.status === 'outcome_unknown') {
      state.value = 'unknown';
      warning.value =
        data.warning ||
        'ERP may have accepted it; please verify before retrying.';
    } else {
      state.value = 'failure';
      message.value =
        data.error || 'Could not add the Lead Activity. Please retry.';
    }
    // Failure/unknown retain the entered values (same submission id) for retry.
  }
};

// ---------------------------------------------------------------------------
// Display-only presentation derived from the existing refs — no state, payload,
// validation, or reset/retry semantics change here.
// ---------------------------------------------------------------------------

const FEEDBACK_TONES = {
  info: 'bg-n-slate-3 text-n-slate-12',
  success: 'bg-n-teal-3 text-n-teal-11',
  warning: 'bg-n-amber-3 text-n-amber-11',
  danger: 'bg-n-ruby-3 text-n-ruby-11',
};

// One contextual feedback line consolidating the loading/options-error and the
// success/unknown/failure outcomes. Messages are surfaced exactly as produced by
// the existing state; this only chooses which single line to render.
const feedback = computed(() => {
  if (loadingOptions.value)
    return { tone: 'info', text: 'Loading Lead Activity options…' };
  if (optionsError.value) return { tone: 'danger', text: optionsError.value };
  if (state.value === 'success')
    return { tone: 'success', text: message.value };
  if (state.value === 'unknown')
    return { tone: 'warning', text: warning.value };
  if (state.value === 'failure') return { tone: 'danger', text: message.value };
  return { tone: 'info', text: '' };
});

// Field-level copy reuses the exact same conditions/messages as
// `validationErrors`, rendered next to the affected required field.
const dateError = computed(() => {
  if (!form.date) return 'Date is required.';
  if (!isRealISODate(form.date))
    return 'Date must be a valid calendar date (YYYY-MM-DD).';
  return '';
});
const activityError = computed(() => {
  if (!form.lead_activity) return 'Lead Activity is required.';
  if (!activityOptions.value.includes(form.lead_activity))
    return 'Lead Activity must be a known option.';
  return '';
});

const submitLabel = computed(() =>
  state.value === 'submitting' ? 'Adding…' : 'Add Lead Activity'
);

const disabledReason = computed(() => {
  if (state.value === 'submitting') return '';
  if (state.value === 'unknown')
    return 'Verify in ERP whether the previous activity was saved before adding another.';
  if (!linked.value) return '';
  if (validationErrors.value.length)
    return 'Complete the required fields marked * before adding the activity.';
  return '';
});

onMounted(() => {
  form.date = '';
  form.person_in_charge = '';
  loadOptions();
});
// WIJAYA_CUSTOM_END erp_lead_sidebar
</script>

<template>
  <!-- eslint-disable vue/no-bare-strings-in-template, @intlify/vue-i18n/no-raw-text -->
  <!-- WIJAYA_CUSTOM_START erp_lead_sidebar -->
  <div class="flex h-full min-h-0 flex-1 flex-col">
    <div v-if="!linked" class="px-6 pt-3 pb-4">
      <div class="rounded-md bg-n-amber-3 text-n-amber-11 p-2">
        Create or link an ERP Lead first, then add activities here.
      </div>
    </div>

    <template v-else>
      <!-- One contextual feedback line for options/success/unknown/failure. -->
      <div
        v-if="feedback.text"
        class="mx-6 mt-3 shrink-0 rounded-md p-2 text-xs"
        :class="FEEDBACK_TONES[feedback.tone]"
        role="status"
        aria-live="polite"
      >
        {{ feedback.text }}
      </div>

      <!-- Single scrollable body. -->
      <div
        class="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-6 pt-3 pb-6"
      >
        <p class="text-xs text-n-slate-10">
          Fields marked <span class="text-n-ruby-10">*</span> are required; all
          others are optional.
        </p>

        <div class="grid grid-cols-1 gap-x-4 gap-y-3 sm:grid-cols-2">
          <label class="flex flex-col gap-1" for="erp-activity-date">
            <span>Date <span class="text-n-ruby-10">*</span></span>
            <input
              id="erp-activity-date"
              v-model="form.date"
              class="input"
              type="date"
              aria-required="true"
              :aria-invalid="dateError ? 'true' : undefined"
              aria-describedby="erp-activity-date-help"
            />
            <span
              v-if="dateError"
              id="erp-activity-date-help"
              class="text-xs text-n-ruby-10"
            >
              {{ dateError }}
            </span>
          </label>

          <label class="flex flex-col gap-1" for="erp-activity-type">
            <span>Lead Activity <span class="text-n-ruby-10">*</span></span>
            <select
              id="erp-activity-type"
              v-model="form.lead_activity"
              class="input"
              aria-required="true"
              :aria-invalid="activityError ? 'true' : undefined"
              aria-describedby="erp-activity-type-help"
            >
              <option value="">— Select —</option>
              <option
                v-for="option in activityOptions"
                :key="option"
                :value="option"
              >
                {{ option }}
              </option>
            </select>
            <span
              v-if="activityError"
              id="erp-activity-type-help"
              class="text-xs text-n-ruby-10"
            >
              {{ activityError }}
            </span>
          </label>

          <label class="flex flex-col gap-1" for="erp-activity-followup">
            <span>Follow Up</span>
            <select
              id="erp-activity-followup"
              v-model="form.follow_up"
              class="input"
              @change="onFollowUpChange"
            >
              <option
                v-for="option in FOLLOW_UP_VALUES"
                :key="option"
                :value="option"
              >
                {{ option }}
              </option>
            </select>
          </label>

          <label class="flex flex-col gap-1" for="erp-activity-followup-date">
            <span>Follow Up Date</span>
            <input
              id="erp-activity-followup-date"
              v-model="form.follow_up_date"
              class="input"
              type="date"
              :disabled="form.follow_up !== 'Yes'"
            />
          </label>

          <label class="flex flex-col gap-1" for="erp-activity-followup-type">
            <span>Follow Up Activity</span>
            <select
              id="erp-activity-followup-type"
              v-model="form.follow_up_activity"
              class="input"
              :disabled="form.follow_up !== 'Yes'"
            >
              <option value="">— Select —</option>
              <option
                v-for="option in activityOptions"
                :key="option"
                :value="option"
              >
                {{ option }}
              </option>
            </select>
          </label>

          <label class="flex flex-col gap-1" for="erp-activity-pic">
            <span>Person In Charge</span>
            <select
              id="erp-activity-pic"
              v-model="form.person_in_charge"
              class="input"
              :disabled="!personInChargeAvailable"
              aria-describedby="erp-activity-pic-help"
            >
              <option value="">— None —</option>
              <option
                v-for="option in personInChargeOptions"
                :key="option.value"
                :value="option.value"
              >
                {{ option.label }}
              </option>
            </select>
            <span
              v-if="!personInChargeAvailable"
              id="erp-activity-pic-help"
              class="text-xs text-n-amber-11"
            >
              The ERP user list is unavailable right now; you can still submit
              without a Person In Charge.
            </span>
          </label>

          <label
            class="flex flex-col gap-1 sm:col-span-2"
            for="erp-activity-remark"
          >
            <span>Remark</span>
            <textarea
              id="erp-activity-remark"
              v-model="form.remark"
              class="input"
              rows="3"
            />
          </label>
        </div>

        <ul
          v-if="validationErrors.length"
          class="list-disc pl-4 text-xs text-n-ruby-10"
          role="alert"
        >
          <li v-for="item in validationErrors" :key="item">{{ item }}</li>
        </ul>
      </div>

      <!-- Stable non-scrolling action footer. -->
      <div
        class="flex shrink-0 flex-col gap-2 border-t border-n-weak bg-n-alpha-2 px-6 py-3"
      >
        <NextButton
          :label="submitLabel"
          :is-loading="state === 'submitting'"
          :disabled="!canSubmit"
          color="blue"
          class="w-full"
          @click="submit"
        >
          {{ submitLabel }}
        </NextButton>
        <p class="text-xs text-n-slate-11">
          Adds a new activity to the linked ERP Lead in ERPNext.
        </p>
        <p v-if="disabledReason" class="text-xs text-n-amber-11">
          {{ disabledReason }}
        </p>
      </div>
    </template>
  </div>
  <!-- WIJAYA_CUSTOM_END erp_lead_sidebar -->
</template>
