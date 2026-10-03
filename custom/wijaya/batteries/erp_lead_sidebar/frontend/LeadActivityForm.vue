<script setup>
// WIJAYA_CUSTOM_START erp_lead_sidebar
// Manual Lead Activity form, hosted inside the ERP Lead modal's "Lead Activity"
// tab. It is fully isolated from the Lead Details create/update/refresh/sync
// flow: it fetches its own runtime option lists and only ever inserts a Lead
// Activity child row on an explicit agent click.
//
// Latency shape: nothing ERP is fetched on mount. A lightweight metadata request
// (default date, no ERP round-trip) runs on mount; the Activity Master and the
// Person In Charge directory are each fetched lazily and independently, only when
// their dropdown is first opened. Activity Type and Follow Up Activity share one
// Activity Master resource; Person In Charge owns its own. Each dependency models
// idle/loading/loaded/error explicitly with independent Retry/Refresh.
import { computed, onMounted, reactive, ref, watch } from 'vue';
import ErpLeadActivitiesAPI from '@wijaya/erp_lead_sidebar/frontend/api/wijayaErpLeadActivities';
import NextButton from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import { useLazyErpResource } from './useLazyErpResource';
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

// Independent lazy ERP dependencies. Activity Type + Follow Up Activity share the
// single Activity Master resource (one fetch, one cache, one in-flight request);
// Person In Charge owns its own.
const activityResource = useLazyErpResource(() =>
  ErpLeadActivitiesAPI.fetchActivityOptions(props.conversationId).then(
    r => r.data.options
  )
);
const picResource = useLazyErpResource(() =>
  ErpLeadActivitiesAPI.fetchPersonInChargeOptions(props.conversationId).then(
    r => r.data.options
  )
);

// Activity Master names (strings) and their ComboBox {value,label} projection.
const activityNames = computed(() => activityResource.data.value);
const activityComboOptions = computed(() =>
  activityNames.value.map(name => ({ value: name, label: name }))
);
// Person In Charge options are already sanitized {value,label} objects server-side.
const picComboOptions = computed(() => picResource.data.value);

// A nonblank Person In Charge is only trustworthy while the directory is loaded and
// still contains it. Blank is always valid (the picker is optional). After a Refresh
// that dropped the value, or a directory failure, a nonblank selection can no longer
// be verified and must block submission until it is cleared or re-verified.
const picVerifiable = computed(() => {
  if (!form.person_in_charge) return true;
  return (
    picResource.isLoaded.value &&
    picComboOptions.value.some(o => o.value === form.person_in_charge)
  );
});

const clearPic = () => {
  form.person_in_charge = '';
};

const submissionId = ref(newSubmissionId());
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

// Default date only — issues NO ERP request, so opening the Activity tab performs
// zero ERP lookups. The date field stays editable.
//
// Monotonic token: a metadata response is only committed by the newest loadMeta
// call. If the conversation / link / config changed while a request was in flight
// (each triggers a fresh loadMeta), the older response is dropped so it can never
// populate the current form with another conversation's default date.
let metaSeq = 0;
const loadMeta = async () => {
  if (!props.configured || !linked.value) return;
  metaSeq += 1;
  const seq = metaSeq;
  const forConversation = props.conversationId;
  try {
    const { data } = await ErpLeadActivitiesAPI.fetchMeta(props.conversationId);
    if (
      seq !== metaSeq ||
      props.conversationId !== forConversation ||
      !props.configured ||
      !linked.value
    )
      return; // superseded / stale — ignore this late response
    defaultDate.value = data.default_date || '';
    if (!form.date) form.date = defaultDate.value;
  } catch {
    // The default date is a convenience; leave the field for manual entry.
  }
};

// Dropdown-level lazy triggers (ComboBox @open). Opening either activity dropdown
// loads the shared Activity Master once; opening the PIC dropdown loads the PIC
// directory once. A reopen after a successful load reuses the cache.
const onActivityOpen = () => activityResource.load();
const onPicOpen = () => picResource.load();

const onActivitySelect = value => {
  form.lead_activity = value || '';
};
const onFollowUpActivitySelect = value => {
  form.follow_up_activity = value || '';
};
const onPicSelect = value => {
  form.person_in_charge = value || '';
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
  else if (!activityNames.value.includes(form.lead_activity))
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
      !activityNames.value.includes(form.follow_up_activity)
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
    // A nonblank Person In Charge that cannot currently be verified against a
    // loaded directory blocks submission (blank stays submittable).
    picVerifiable.value &&
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

// One contextual feedback line for the submission outcome only. Per-dependency
// loading/error is surfaced inline at each dropdown, so it is intentionally not
// duplicated here.
const feedback = computed(() => {
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
  if (!activityNames.value.includes(form.lead_activity))
    return 'Lead Activity must be a known option.';
  return '';
});

// Inline empty-state copy for each ComboBox dropdown. Never a selectable option —
// ComboBox renders this as non-interactive empty text.
const activityEmptyState = computed(() => {
  if (activityResource.isLoading.value) return 'Loading Lead Activity options…';
  if (activityResource.isError.value)
    return activityResource.error.value || 'Options are unavailable.';
  return 'No Lead Activity options available.';
});
const picEmptyState = computed(() => {
  if (picResource.isLoading.value) return 'Loading users…';
  if (picResource.isError.value)
    return picResource.error.value || 'The user list is unavailable.';
  return 'No ERP users available.';
});

// Truthful guidance for a nonblank Person In Charge that cannot be verified: the
// directory failed to refresh, or a refresh no longer lists the selected user. In
// both cases the agent can clear it (blank submits) or retry/refresh to re-verify.
const picWarning = computed(() => {
  if (picVerifiable.value) return '';
  if (picResource.isError.value)
    return 'The ERP user list is unavailable, so the selected Person In Charge can’t be verified. Retry, or clear it to submit without one.';
  if (picResource.isLoaded.value)
    return 'The selected Person In Charge is no longer in the ERP user list. Pick another, clear it, or Refresh.';
  return 'Open the user list to verify the selected Person In Charge, or clear it.';
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
  if (!picVerifiable.value)
    return 'Verify the selected Person In Charge, clear it, or retry the user list before adding the activity.';
  return '';
});

onMounted(() => {
  form.date = '';
  form.person_in_charge = '';
  loadMeta();
});

// A conversation change resets every dependency's cache/state (so a stale
// response can never win) and clears the form, then reloads the ERP-free
// metadata. The parent also remounts the form on a conversation switch; this
// keeps the form correct even if it is kept mounted.
watch(
  () => props.conversationId,
  () => {
    activityResource.reset();
    picResource.reset();
    submissionId.value = newSubmissionId();
    state.value = 'idle';
    message.value = '';
    warning.value = '';
    defaultDate.value = '';
    form.date = '';
    resetActivityFields();
    loadMeta();
  }
);

// A draft can become linked/configured WITHOUT a conversation change while this
// form stays mounted (the parent keeps it mounted across tab switches). If it was
// mounted while unlinked or unconfigured, loadMeta returned early on mount, so the
// default date is still blank; fetch it once the draft is both linked and
// configured. loadMeta only fills a blank date, so this never erases entered values
// — unrelated prop churn leaves the form intact.
watch(
  () => [props.configured, linked.value],
  ([configuredNow, linkedNow], [configuredWas, linkedWas]) => {
    if (configuredNow && linkedNow && !(configuredWas && linkedWas)) loadMeta();
  }
);

// If the linked ERP Lead identity itself changes to a different Lead (a relink
// within the same conversation), the loaded option caches may no longer apply:
// invalidate them so the next dropdown open refetches. Only a nonblank -> different
// nonblank change qualifies; entered form values are left untouched.
watch(
  () => props.erpLeadId,
  (next, prev) => {
    if (next && prev && next !== prev) {
      activityResource.reset();
      picResource.reset();
    }
  }
);
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
      <!-- One contextual feedback line for the submission outcome. -->
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
              :aria-describedby="
                dateError ? 'erp-activity-date-help' : undefined
              "
            />
            <span
              v-if="dateError"
              id="erp-activity-date-help"
              class="text-xs text-n-ruby-10"
            >
              {{ dateError }}
            </span>
          </label>

          <label class="flex flex-col gap-1">
            <span>Lead Activity <span class="text-n-ruby-10">*</span></span>
            <ComboBox
              class="erp-activity-type"
              :model-value="form.lead_activity"
              :options="activityComboOptions"
              :display-label="form.lead_activity"
              :empty-state="activityEmptyState"
              :has-error="Boolean(activityError)"
              placeholder="— Select —"
              @open="onActivityOpen"
              @update:model-value="onActivitySelect"
            />
            <!-- Independent Activity Master status + Retry/Refresh, shared by both
                 activity dropdowns. Retry only appears after an error; Refresh only
                 after a successful load. Neither clears the selected value. -->
            <div class="flex items-center gap-2 text-xs">
              <button
                v-if="activityResource.isError.value"
                type="button"
                class="font-medium text-n-brand hover:underline"
                @click="activityResource.load()"
              >
                Retry
              </button>
              <button
                v-if="activityResource.isLoaded.value"
                type="button"
                class="font-medium text-n-slate-11 hover:underline"
                @click="activityResource.refresh()"
              >
                Refresh
              </button>
              <span
                v-if="activityResource.isError.value"
                class="text-n-ruby-10"
              >
                {{ activityResource.error.value }}
              </span>
            </div>
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

          <label class="flex flex-col gap-1">
            <span>Follow Up Activity</span>
            <ComboBox
              class="erp-activity-followup-type"
              :model-value="form.follow_up_activity"
              :options="activityComboOptions"
              :display-label="form.follow_up_activity"
              :empty-state="activityEmptyState"
              :disabled="form.follow_up !== 'Yes'"
              placeholder="— Select —"
              @open="onActivityOpen"
              @update:model-value="onFollowUpActivitySelect"
            />
          </label>

          <label class="flex flex-col gap-1">
            <span>Person In Charge</span>
            <ComboBox
              class="erp-activity-pic"
              :model-value="form.person_in_charge"
              :options="picComboOptions"
              :display-label="form.person_in_charge"
              :empty-state="picEmptyState"
              placeholder="— None —"
              @open="onPicOpen"
              @update:model-value="onPicSelect"
            />
            <!-- Independent Person In Charge status + Retry/Refresh/Clear. A blank
                 Person In Charge is always valid, so a directory outage never blocks
                 submission; but a nonblank selection that cannot be verified (failed
                 refresh, or dropped from a refreshed list) does, until it is cleared
                 or re-verified. -->
            <div class="flex items-center gap-2 text-xs">
              <button
                v-if="picResource.isError.value"
                type="button"
                class="font-medium text-n-brand hover:underline"
                @click="picResource.load()"
              >
                Retry
              </button>
              <button
                v-if="picResource.isLoaded.value"
                type="button"
                class="font-medium text-n-slate-11 hover:underline"
                @click="picResource.refresh()"
              >
                Refresh
              </button>
              <button
                v-if="form.person_in_charge && !picVerifiable"
                type="button"
                class="font-medium text-n-brand hover:underline"
                @click="clearPic"
              >
                Clear selection
              </button>
            </div>
            <span
              v-if="picWarning"
              id="erp-activity-pic-help"
              class="text-xs text-n-amber-11"
              role="alert"
            >
              {{ picWarning }}
            </span>
            <span
              v-else-if="picResource.isError.value"
              class="text-xs text-n-amber-11"
            >
              The ERP user list is unavailable right now; you can still submit
              without a Person In Charge, or Retry.
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
        />
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
