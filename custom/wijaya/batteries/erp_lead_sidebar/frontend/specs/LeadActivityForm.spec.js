import { mount, flushPromises } from '@vue/test-utils';
import LeadActivityForm from '@wijaya/erp_lead_sidebar/frontend/LeadActivityForm.vue';

// The manual Lead Activity form is fully isolated from the Lead Details flow. It
// fetches nothing from ERP on mount (only a lightweight, ERP-free default-date
// metadata call), and lazily loads the Activity Master and the Person In Charge
// directory independently — each only when its dropdown is first opened. These
// specs drive the real component and assert that contract at the API surface.

const { fetchMetaSpy, fetchActivitySpy, fetchPicSpy, createSpy } = vi.hoisted(
  () => ({
    fetchMetaSpy: vi.fn(),
    fetchActivitySpy: vi.fn(),
    fetchPicSpy: vi.fn(),
    createSpy: vi.fn(),
  })
);

vi.mock(
  '@wijaya/erp_lead_sidebar/frontend/api/wijayaErpLeadActivities',
  () => ({
    default: {
      fetchMeta: fetchMetaSpy,
      fetchActivityOptions: fetchActivitySpy,
      fetchPersonInChargeOptions: fetchPicSpy,
      create: createSpy,
    },
  })
);

// The global NextButton stub renders only its default slot; the real Button
// renders :label instead. Mirror that here (and pass :disabled through) so
// text-based button lookups and disabled assertions keep working.
const LabelledNextButton = {
  props: { label: { type: String, default: '' } },
  template: '<button><slot>{{ label }}</slot></button>',
};

// Minimal ComboBox stub: an open trigger that emits @open, and a clickable option
// list that emits @update:modelValue. It surfaces the empty-state text (never as a
// selectable option) so loading/error/empty copy can be asserted. The `class`
// passed in the template (erp-activity-type / erp-activity-followup-type /
// erp-activity-pic) falls through to the root so each field is addressable.
const ComboBoxStub = {
  name: 'ComboBox',
  props: {
    modelValue: { type: [String, Number], default: '' },
    options: { type: Array, default: () => [] },
    displayLabel: { type: String, default: '' },
    emptyState: { type: String, default: '' },
    disabled: { type: Boolean, default: false },
    hasError: { type: Boolean, default: false },
    placeholder: { type: String, default: '' },
  },
  emits: ['open', 'update:modelValue'],
  template: `
    <div class="combobox">
      <button
        class="combobox-open"
        :disabled="disabled"
        @click="$emit('open')"
      >{{ displayLabel || placeholder }}</button>
      <ul class="combobox-options">
        <li
          v-for="o in options"
          :key="o.value"
          class="combobox-option"
          :data-value="o.value"
          @click="$emit('update:modelValue', o.value)"
        >{{ o.label }}</li>
      </ul>
      <span v-if="!options.length" class="combobox-empty">{{ emptyState }}</span>
    </div>`,
};

const mountForm = (props = {}) =>
  mount(LeadActivityForm, {
    props: {
      conversationId: 42,
      currentChat: {},
      erpLeadId: 'LEAD-0001',
      configured: true,
      ...props,
    },
    global: {
      stubs: { NextButton: LabelledNextButton, ComboBox: ComboBoxStub },
    },
  });

const combo = (wrapper, cls) => wrapper.find(`.${cls}`);
const openCombo = (wrapper, cls) =>
  combo(wrapper, cls).find('.combobox-open').trigger('click');
const selectOption = (wrapper, cls, value) =>
  combo(wrapper, cls)
    .find(`.combobox-option[data-value="${value}"]`)
    .trigger('click');

const dateInput = wrapper => wrapper.find('#erp-activity-date');
const submitButton = wrapper =>
  wrapper.findAll('button').find(b => b.text().includes('Add Lead Activity'));
const findByText = (wrapper, selector, text) =>
  wrapper.findAll(selector).find(el => el.text().trim() === text);

const setFollowUpYes = async wrapper => {
  const select = wrapper.find('#erp-activity-followup');
  await select.setValue('Yes');
};

describe('LeadActivityForm — lazy dropdown loading', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    fetchMetaSpy.mockResolvedValue({ data: { default_date: '2026-08-10' } });
    fetchActivitySpy.mockResolvedValue({
      data: { options: ['Call', 'WhatsApp'] },
    });
    fetchPicSpy.mockResolvedValue({
      data: {
        options: [{ value: 'agent@erp.example', label: 'Agent Example' }],
      },
    });
    createSpy.mockResolvedValue({
      data: { status: 'success', message: 'Lead Activity added successfully.' },
    });
  });

  it('shows a link-first banner and performs no requests at all when no ERP Lead is linked', async () => {
    const wrapper = mountForm({ erpLeadId: '' });
    await flushPromises();

    expect(wrapper.text()).toContain('Create or link an ERP Lead first');
    expect(submitButton(wrapper)).toBeUndefined();
    expect(fetchMetaSpy).not.toHaveBeenCalled();
    expect(fetchActivitySpy).not.toHaveBeenCalled();
    expect(fetchPicSpy).not.toHaveBeenCalled();
  });

  it('on mount fetches only the ERP-free metadata and no ERP option data', async () => {
    const wrapper = mountForm();
    await flushPromises();

    expect(fetchMetaSpy).toHaveBeenCalledTimes(1);
    expect(fetchMetaSpy).toHaveBeenCalledWith(42);
    expect(fetchActivitySpy).not.toHaveBeenCalled();
    expect(fetchPicSpy).not.toHaveBeenCalled();
    // default_date is populated without any ERP lookup.
    expect(dateInput(wrapper).element.value).toBe('2026-08-10');
  });

  it('opening the Activity Type dropdown loads only the Activity Master', async () => {
    const wrapper = mountForm();
    await flushPromises();

    await openCombo(wrapper, 'erp-activity-type');
    await flushPromises();

    expect(fetchActivitySpy).toHaveBeenCalledTimes(1);
    expect(fetchActivitySpy).toHaveBeenCalledWith(42);
    expect(fetchPicSpy).not.toHaveBeenCalled();

    const labels = combo(wrapper, 'erp-activity-type')
      .findAll('.combobox-option')
      .map(o => o.text());
    expect(labels).toEqual(['Call', 'WhatsApp']);
  });

  it('Follow Up Activity shares the same Activity Master state (no second fetch)', async () => {
    const wrapper = mountForm();
    await flushPromises();

    await openCombo(wrapper, 'erp-activity-type');
    await flushPromises();
    expect(fetchActivitySpy).toHaveBeenCalledTimes(1);

    await setFollowUpYes(wrapper);
    await openCombo(wrapper, 'erp-activity-followup-type');
    await flushPromises();

    // Still one fetch: both dropdowns reuse the shared loaded cache.
    expect(fetchActivitySpy).toHaveBeenCalledTimes(1);
    const labels = combo(wrapper, 'erp-activity-followup-type')
      .findAll('.combobox-option')
      .map(o => o.text());
    expect(labels).toEqual(['Call', 'WhatsApp']);
  });

  it('opening the Person In Charge dropdown loads only the PIC directory', async () => {
    const wrapper = mountForm();
    await flushPromises();

    await openCombo(wrapper, 'erp-activity-pic');
    await flushPromises();

    expect(fetchPicSpy).toHaveBeenCalledTimes(1);
    expect(fetchActivitySpy).not.toHaveBeenCalled();
  });

  it('reopening an already-loaded dropdown reuses the cache and does not refetch', async () => {
    const wrapper = mountForm();
    await flushPromises();

    await openCombo(wrapper, 'erp-activity-type');
    await flushPromises();
    await openCombo(wrapper, 'erp-activity-type');
    await flushPromises();

    expect(fetchActivitySpy).toHaveBeenCalledTimes(1);
  });

  it('dedupes concurrent opens while a fetch is in flight', async () => {
    let resolveActivity;
    fetchActivitySpy.mockReturnValueOnce(
      new Promise(resolve => {
        resolveActivity = resolve;
      })
    );

    const wrapper = mountForm();
    await flushPromises();

    await openCombo(wrapper, 'erp-activity-type');
    await openCombo(wrapper, 'erp-activity-type');
    // Both opens happened before the first fetch resolved.
    expect(fetchActivitySpy).toHaveBeenCalledTimes(1);

    resolveActivity({ data: { options: ['Call'] } });
    await flushPromises();
    expect(fetchActivitySpy).toHaveBeenCalledTimes(1);
  });

  it('caches a valid empty response as loaded and does not refetch', async () => {
    fetchActivitySpy.mockResolvedValue({ data: { options: [] } });

    const wrapper = mountForm();
    await flushPromises();

    await openCombo(wrapper, 'erp-activity-type');
    await flushPromises();
    expect(fetchActivitySpy).toHaveBeenCalledTimes(1);
    expect(
      combo(wrapper, 'erp-activity-type').find('.combobox-empty').text()
    ).toContain('No Lead Activity options available.');

    // Reopening a valid-empty (loaded) resource must not refetch.
    await openCombo(wrapper, 'erp-activity-type');
    await flushPromises();
    expect(fetchActivitySpy).toHaveBeenCalledTimes(1);
  });

  it('surfaces an Activity Master error and retries it independently of PIC', async () => {
    fetchActivitySpy
      .mockRejectedValueOnce({
        response: {
          data: { error: 'Lead Activity options are currently unavailable.' },
        },
      })
      .mockResolvedValueOnce({ data: { options: ['Call'] } });

    const wrapper = mountForm();
    await flushPromises();

    await openCombo(wrapper, 'erp-activity-type');
    await flushPromises();

    // Error surfaced with a Retry affordance; PIC untouched.
    expect(wrapper.text()).toContain(
      'Lead Activity options are currently unavailable.'
    );
    expect(fetchPicSpy).not.toHaveBeenCalled();
    const retry = findByText(wrapper, 'button', 'Retry');
    expect(retry).toBeTruthy();

    await retry.trigger('click');
    await flushPromises();

    expect(fetchActivitySpy).toHaveBeenCalledTimes(2);
    const labels = combo(wrapper, 'erp-activity-type')
      .findAll('.combobox-option')
      .map(o => o.text());
    expect(labels).toEqual(['Call']);
  });

  it('offers an explicit Refresh that refetches a loaded resource and preserves the selection', async () => {
    fetchActivitySpy
      .mockResolvedValueOnce({ data: { options: ['Call', 'WhatsApp'] } })
      .mockResolvedValueOnce({
        data: { options: ['Call', 'WhatsApp', 'Email'] },
      });

    const wrapper = mountForm();
    await flushPromises();

    await openCombo(wrapper, 'erp-activity-type');
    await flushPromises();
    await selectOption(wrapper, 'erp-activity-type', 'Call');

    const refresh = findByText(wrapper, 'button', 'Refresh');
    expect(refresh).toBeTruthy();
    await refresh.trigger('click');
    await flushPromises();

    expect(fetchActivitySpy).toHaveBeenCalledTimes(2);
    // The selected value survives a refresh.
    expect(
      combo(wrapper, 'erp-activity-type').find('.combobox-open').text()
    ).toBe('Call');
  });

  it('ignores a stale Activity Master response after the conversation changes', async () => {
    let resolveOld;
    fetchActivitySpy.mockReturnValueOnce(
      new Promise(resolve => {
        resolveOld = resolve;
      })
    );

    const wrapper = mountForm();
    await flushPromises();

    await openCombo(wrapper, 'erp-activity-type');
    // Conversation switches before the in-flight fetch resolves.
    await wrapper.setProps({ conversationId: 99 });
    await flushPromises();

    // The stale response arrives late and must be ignored.
    resolveOld({ data: { options: ['StaleActivity'] } });
    await flushPromises();

    const labels = combo(wrapper, 'erp-activity-type')
      .findAll('.combobox-option')
      .map(o => o.text());
    expect(labels).not.toContain('StaleActivity');
  });

  it('resets the form and re-fetches the ERP-free metadata on a conversation change', async () => {
    const wrapper = mountForm();
    await flushPromises();

    await openCombo(wrapper, 'erp-activity-type');
    await flushPromises();
    await selectOption(wrapper, 'erp-activity-type', 'Call');
    expect(
      combo(wrapper, 'erp-activity-type').find('.combobox-open').text()
    ).toBe('Call');

    fetchMetaSpy.mockResolvedValueOnce({
      data: { default_date: '2026-09-01' },
    });
    await wrapper.setProps({ conversationId: 77 });
    await flushPromises();

    // Selection cleared, new default date fetched via the ERP-free metadata call.
    expect(
      combo(wrapper, 'erp-activity-type').find('.combobox-open').text()
    ).toBe('— Select —');
    expect(dateInput(wrapper).element.value).toBe('2026-09-01');
  });
});

describe('LeadActivityForm — submission behaviour', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    fetchMetaSpy.mockResolvedValue({ data: { default_date: '2026-08-10' } });
    fetchActivitySpy.mockResolvedValue({
      data: { options: ['Call', 'WhatsApp'] },
    });
    fetchPicSpy.mockResolvedValue({
      data: {
        options: [{ value: 'agent@erp.example', label: 'Agent Example' }],
      },
    });
    createSpy.mockResolvedValue({
      data: { status: 'success', message: 'Lead Activity added successfully.' },
    });
  });

  const selectActivity = async (wrapper, value = 'Call') => {
    await openCombo(wrapper, 'erp-activity-type');
    await flushPromises();
    await selectOption(wrapper, 'erp-activity-type', value);
  };

  it('keeps submit disabled until a valid activity is chosen', async () => {
    const wrapper = mountForm();
    await flushPromises();

    expect(submitButton(wrapper).attributes('disabled')).toBeDefined();
    await selectActivity(wrapper);
    expect(submitButton(wrapper).attributes('disabled')).toBeUndefined();
  });

  it('submits only on click and clears follow-up fields when follow_up is No', async () => {
    const wrapper = mountForm();
    await flushPromises();

    await selectActivity(wrapper);
    expect(createSpy).not.toHaveBeenCalled();

    await submitButton(wrapper).trigger('click');
    await flushPromises();

    expect(createSpy).toHaveBeenCalledTimes(1);
    const [conversationId, payload] = createSpy.mock.calls[0];
    expect(conversationId).toBe(42);
    expect(payload.lead_activity).toBe('Call');
    expect(payload.follow_up).toBe('No');
    expect(payload.follow_up_date).toBe('');
    expect(payload.follow_up_activity).toBe('');
    expect(typeof payload.submission_id).toBe('string');
  });

  it('resets the activity and starts a new submission id after success', async () => {
    const wrapper = mountForm();
    await flushPromises();

    await selectActivity(wrapper);
    await submitButton(wrapper).trigger('click');
    await flushPromises();

    const firstId = createSpy.mock.calls[0][1].submission_id;
    expect(wrapper.text()).toContain('Lead Activity added successfully.');
    // The activity selection is cleared, so submit is disabled again.
    expect(submitButton(wrapper).attributes('disabled')).toBeDefined();

    await selectActivity(wrapper, 'WhatsApp');
    await submitButton(wrapper).trigger('click');
    await flushPromises();

    const secondId = createSpy.mock.calls[1][1].submission_id;
    expect(secondId).not.toBe(firstId);
  });

  it('does not call create again after an outcome_unknown (same id stays blocked)', async () => {
    createSpy.mockRejectedValueOnce({
      response: {
        data: {
          status: 'outcome_unknown',
          warning: 'ERP may have accepted it.',
        },
      },
    });

    const wrapper = mountForm();
    await flushPromises();

    await selectActivity(wrapper);
    await submitButton(wrapper).trigger('click');
    await flushPromises();

    expect(createSpy).toHaveBeenCalledTimes(1);
    expect(wrapper.text()).toContain('ERP may have accepted it.');
    expect(submitButton(wrapper).attributes('disabled')).toBeDefined();

    await submitButton(wrapper).trigger('click');
    await flushPromises();
    expect(createSpy).toHaveBeenCalledTimes(1);
  });

  it('submits the manually selected Person In Charge value only on click', async () => {
    const wrapper = mountForm();
    await flushPromises();

    await selectActivity(wrapper);
    await openCombo(wrapper, 'erp-activity-pic');
    await flushPromises();
    await selectOption(wrapper, 'erp-activity-pic', 'agent@erp.example');

    expect(createSpy).not.toHaveBeenCalled();
    await submitButton(wrapper).trigger('click');
    await flushPromises();

    expect(createSpy.mock.calls[0][1].person_in_charge).toBe(
      'agent@erp.example'
    );
  });

  it('allows a blank Person In Charge submit when the PIC directory failed to load', async () => {
    fetchPicSpy.mockRejectedValue({
      response: {
        data: { error: 'The ERP user list is currently unavailable.' },
      },
    });

    const wrapper = mountForm();
    await flushPromises();

    await selectActivity(wrapper);
    await openCombo(wrapper, 'erp-activity-pic');
    await flushPromises();

    // A truthful warning is shown, but submission with a blank PIC still works.
    expect(wrapper.text()).toContain('ERP user list is unavailable');
    expect(submitButton(wrapper).attributes('disabled')).toBeUndefined();

    await submitButton(wrapper).trigger('click');
    await flushPromises();

    expect(createSpy).toHaveBeenCalledTimes(1);
    expect(createSpy.mock.calls[0][1].person_in_charge).toBe('');
  });

  it('blocks an invalid submit when the required Activity Master failed to load', async () => {
    fetchActivitySpy.mockRejectedValue({
      response: {
        data: { error: 'Lead Activity options are currently unavailable.' },
      },
    });

    const wrapper = mountForm();
    await flushPromises();

    await openCombo(wrapper, 'erp-activity-type');
    await flushPromises();

    // No selectable activity, so the required rule is unmet and submit is blocked.
    expect(submitButton(wrapper).attributes('disabled')).toBeDefined();
    await submitButton(wrapper).trigger('click');
    await flushPromises();
    expect(createSpy).not.toHaveBeenCalled();
  });

  it('shows a failure message and keeps values on a definite rejection', async () => {
    createSpy.mockRejectedValueOnce({
      response: {
        data: {
          status: 'rejected',
          error: 'ERPNext rejected the Lead Activity.',
        },
      },
    });

    const wrapper = mountForm();
    await flushPromises();

    await selectActivity(wrapper);
    await submitButton(wrapper).trigger('click');
    await flushPromises();

    expect(wrapper.text()).toContain('ERPNext rejected the Lead Activity.');
    expect(
      combo(wrapper, 'erp-activity-type').find('.combobox-open').text()
    ).toBe('Call');
  });

  it('explains the primary action and shows a plain-language disabled reason', async () => {
    const wrapper = mountForm();
    await flushPromises();

    expect(submitButton(wrapper).attributes('disabled')).toBeDefined();
    expect(wrapper.text()).toContain(
      'Adds a new activity to the linked ERP Lead in ERPNext.'
    );
    expect(wrapper.text()).toContain(
      'Complete the required fields marked * before adding the activity.'
    );
  });

  it('marks the required date field with an accessible required cue', async () => {
    const wrapper = mountForm();
    await flushPromises();

    expect(dateInput(wrapper).attributes('aria-required')).toBe('true');
  });
});

// The parent keeps this form mounted across tab switches, so props.erpLeadId /
// props.configured can change WITHOUT a conversation change (the agent links the
// Lead or ERP becomes configured while the form is already mounted). The form must
// still pick up server metadata and invalidate stale caches without erasing state.
describe('LeadActivityForm — in-session link/config identity changes', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    fetchMetaSpy.mockResolvedValue({ data: { default_date: '2026-08-10' } });
    fetchActivitySpy.mockResolvedValue({
      data: { options: ['Call', 'WhatsApp'] },
    });
    fetchPicSpy.mockResolvedValue({
      data: {
        options: [{ value: 'agent@erp.example', label: 'Agent Example' }],
      },
    });
    createSpy.mockResolvedValue({
      data: { status: 'success', message: 'Lead Activity added successfully.' },
    });
  });

  it('fetches the ERP-free metadata once the draft becomes linked after mount', async () => {
    const wrapper = mountForm({ erpLeadId: '' });
    await flushPromises();
    // Unlinked on mount: loadMeta returned early, so no metadata request.
    expect(fetchMetaSpy).not.toHaveBeenCalled();

    await wrapper.setProps({ erpLeadId: 'LEAD-0001' });
    await flushPromises();

    expect(fetchMetaSpy).toHaveBeenCalledTimes(1);
    expect(fetchMetaSpy).toHaveBeenCalledWith(42);
    expect(dateInput(wrapper).element.value).toBe('2026-08-10');
  });

  it('fetches the ERP-free metadata once ERP becomes configured after mount', async () => {
    const wrapper = mountForm({ configured: false });
    await flushPromises();
    expect(fetchMetaSpy).not.toHaveBeenCalled();

    await wrapper.setProps({ configured: true });
    await flushPromises();

    expect(fetchMetaSpy).toHaveBeenCalledTimes(1);
    expect(dateInput(wrapper).element.value).toBe('2026-08-10');
  });

  it('invalidates the loaded option caches when the linked Lead identity changes', async () => {
    const wrapper = mountForm();
    await flushPromises();

    await openCombo(wrapper, 'erp-activity-type');
    await flushPromises();
    expect(fetchActivitySpy).toHaveBeenCalledTimes(1);

    // Relink to a different Lead within the same conversation.
    await wrapper.setProps({ erpLeadId: 'LEAD-0002' });
    await flushPromises();

    // The cache was invalidated, so reopening refetches.
    await openCombo(wrapper, 'erp-activity-type');
    await flushPromises();
    expect(fetchActivitySpy).toHaveBeenCalledTimes(2);
  });

  it('does not erase entered form state on an unrelated prop change', async () => {
    const wrapper = mountForm();
    await flushPromises();

    const remark = wrapper.find('#erp-activity-remark');
    await remark.setValue('Called the customer');

    await wrapper.setProps({ currentChat: { id: 7 } });
    await flushPromises();

    expect(wrapper.find('#erp-activity-remark').element.value).toBe(
      'Called the customer'
    );
  });

  it('ignores stale metadata that resolves after a conversation change', async () => {
    let resolveOld;
    fetchMetaSpy.mockReturnValueOnce(
      new Promise(resolve => {
        resolveOld = resolve;
      })
    );

    const wrapper = mountForm();
    await flushPromises();

    fetchMetaSpy.mockResolvedValueOnce({
      data: { default_date: '2026-09-09' },
    });
    await wrapper.setProps({ conversationId: 99 });
    await flushPromises();
    expect(dateInput(wrapper).element.value).toBe('2026-09-09');

    // The previous conversation's metadata resolves late and must be ignored.
    resolveOld({ data: { default_date: '2000-01-01' } });
    await flushPromises();
    expect(dateInput(wrapper).element.value).toBe('2026-09-09');
  });
});

// A selected Person In Charge is optional but, once picked, must remain verifiable
// against a loaded directory. A refresh that drops it, or a directory failure,
// leaves the display value in place but blocks submission until it is cleared or
// re-verified — a blank Person In Charge always stays submittable.
describe('LeadActivityForm — Person In Charge verification', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    fetchMetaSpy.mockResolvedValue({ data: { default_date: '2026-08-10' } });
    fetchActivitySpy.mockResolvedValue({
      data: { options: ['Call', 'WhatsApp'] },
    });
    createSpy.mockResolvedValue({
      data: { status: 'success', message: 'Lead Activity added successfully.' },
    });
  });

  const picLabel = wrapper =>
    wrapper.findAll('label').find(l => l.find('.erp-activity-pic').exists());
  const picButton = (wrapper, text) =>
    picLabel(wrapper)
      .findAll('button')
      .find(b => b.text() === text);
  const selectActivity = async (wrapper, value = 'Call') => {
    await openCombo(wrapper, 'erp-activity-type');
    await flushPromises();
    await selectOption(wrapper, 'erp-activity-type', value);
  };

  it('blocks submit and offers Clear when a refresh drops the selected Person In Charge', async () => {
    fetchPicSpy
      .mockResolvedValueOnce({
        data: {
          options: [{ value: 'agent@erp.example', label: 'Agent Example' }],
        },
      })
      .mockResolvedValueOnce({
        data: { options: [{ value: 'other@erp.example', label: 'Other' }] },
      });

    const wrapper = mountForm();
    await flushPromises();
    await selectActivity(wrapper);

    await openCombo(wrapper, 'erp-activity-pic');
    await flushPromises();
    await selectOption(wrapper, 'erp-activity-pic', 'agent@erp.example');
    // Verified against the loaded directory -> submittable.
    expect(submitButton(wrapper).attributes('disabled')).toBeUndefined();

    await picButton(wrapper, 'Refresh').trigger('click');
    await flushPromises();

    // The selection is gone from the refreshed list: submission is blocked, but the
    // display value is preserved and a Clear affordance is offered.
    expect(submitButton(wrapper).attributes('disabled')).toBeDefined();
    expect(wrapper.text()).toContain('no longer in the ERP user list');
    expect(
      combo(wrapper, 'erp-activity-pic').find('.combobox-open').text()
    ).toBe('agent@erp.example');

    await picButton(wrapper, 'Clear selection').trigger('click');
    await flushPromises();

    // Blank Person In Charge is valid again.
    expect(submitButton(wrapper).attributes('disabled')).toBeUndefined();
  });

  it('blocks submit and offers Retry/Clear when a directory refresh fails with a selection', async () => {
    fetchPicSpy
      .mockResolvedValueOnce({
        data: {
          options: [{ value: 'agent@erp.example', label: 'Agent Example' }],
        },
      })
      .mockRejectedValueOnce({
        response: {
          data: { error: 'The ERP user list is currently unavailable.' },
        },
      });

    const wrapper = mountForm();
    await flushPromises();
    await selectActivity(wrapper);

    await openCombo(wrapper, 'erp-activity-pic');
    await flushPromises();
    await selectOption(wrapper, 'erp-activity-pic', 'agent@erp.example');
    expect(submitButton(wrapper).attributes('disabled')).toBeUndefined();

    await picButton(wrapper, 'Refresh').trigger('click');
    await flushPromises();

    // The selection can no longer be verified: submission is blocked, the value is
    // preserved, and both Retry and Clear are offered.
    expect(submitButton(wrapper).attributes('disabled')).toBeDefined();
    expect(wrapper.text()).toContain(
      'Retry, or clear it to submit without one'
    );
    expect(
      combo(wrapper, 'erp-activity-pic').find('.combobox-open').text()
    ).toBe('agent@erp.example');
    expect(picButton(wrapper, 'Retry')).toBeTruthy();

    await picButton(wrapper, 'Clear selection').trigger('click');
    await flushPromises();
    expect(submitButton(wrapper).attributes('disabled')).toBeUndefined();
  });
});
