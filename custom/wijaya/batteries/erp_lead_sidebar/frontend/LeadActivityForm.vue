<script setup>
// WIJAYA_CUSTOM_START erp_lead_sidebar
// Manual Lead Activity form, hosted inside the ERP Lead modal's "Lead Activity"
// tab. It is fully isolated from the Lead Details create/update/refresh/sync
// flow: it fetches its own runtime option list, builds its own submission, and
// only ever inserts a Lead Activity child row on an explicit agent click.
import { computed, onMounted, reactive, ref } from 'vue';
import ErpLeadActivitiesAPI from '@wijaya/erp_lead_sidebar/frontend/api/wijayaErpLeadActivities';
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
  <div class="flex flex-col gap-4">
    <div v-if="!linked" class="rounded-md bg-n-amber-3 text-n-amber-11 p-2">
      Create or link an ERP Lead first, then add activities here.
    </div>

    <template v-else>
      <div v-if="loadingOptions" class="text-n-slate-11">
        Loading Lead Activity options…
      </div>
      <div
        v-if="optionsError"
        class="rounded-md bg-n-ruby-3 text-n-ruby-11 p-2"
      >
        {{ optionsError }}
      </div>
      <div
        v-if="state === 'success'"
        class="rounded-md bg-n-teal-3 text-n-teal-11 p-2"
      >
        {{ message }}
      </div>
      <div
        v-if="state === 'unknown'"
        class="rounded-md bg-n-amber-3 text-n-amber-11 p-2"
      >
        {{ warning }}
      </div>
      <div
        v-if="state === 'failure'"
        class="rounded-md bg-n-ruby-3 text-n-ruby-11 p-2"
      >
        {{ message }}
      </div>

      <div class="grid grid-cols-1 gap-x-4 gap-y-3 sm:grid-cols-2">
        <label class="flex flex-col gap-1">
          <span>Date <span class="text-n-ruby-10">*</span></span>
          <input v-model="form.date" class="input" type="date" />
        </label>

        <label class="flex flex-col gap-1">
          <span>Lead Activity <span class="text-n-ruby-10">*</span></span>
          <select v-model="form.lead_activity" class="input">
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

        <label class="flex flex-col gap-1">
          <span>Follow Up</span>
          <select
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

        <label class="flex flex-col gap-1">
          <span>Follow Up Date</span>
          <input
            v-model="form.follow_up_date"
            class="input"
            type="date"
            :disabled="form.follow_up !== 'Yes'"
          />
        </label>

        <label class="flex flex-col gap-1">
          <span>Follow Up Activity</span>
          <select
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

        <label class="flex flex-col gap-1">
          <span>Person In Charge</span>
          <select
            v-model="form.person_in_charge"
            class="input"
            :disabled="!personInChargeAvailable"
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
          <span v-if="!personInChargeAvailable" class="text-xs text-n-amber-11">
            The ERP user list is unavailable right now; you can still submit
            without a Person In Charge.
          </span>
        </label>

        <label class="flex flex-col gap-1 sm:col-span-2">
          <span>Remark</span>
          <textarea v-model="form.remark" class="input" rows="3" />
        </label>
      </div>

      <ul v-if="validationErrors.length" class="list-disc pl-4 text-n-ruby-10">
        <li v-for="item in validationErrors" :key="item">{{ item }}</li>
      </ul>

      <button
        class="button button-primary"
        :disabled="!canSubmit"
        @click="submit"
      >
        {{ state === 'submitting' ? 'Adding…' : 'Add Lead Activity' }}
      </button>
    </template>
  </div>
  <!-- WIJAYA_CUSTOM_END erp_lead_sidebar -->
</template>
