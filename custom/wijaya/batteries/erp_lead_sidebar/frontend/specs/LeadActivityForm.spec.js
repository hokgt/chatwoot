import { mount, flushPromises } from '@vue/test-utils';
import LeadActivityForm from '@wijaya/erp_lead_sidebar/frontend/LeadActivityForm.vue';

// The manual Lead Activity form is fully isolated from the Lead Details flow: it
// fetches its own runtime options, only submits on an explicit click, and only
// when the server-derived erp_lead_id is present. These specs drive the real
// component and assert that contract at the API surface.

const { fetchOptionsSpy, createSpy } = vi.hoisted(() => ({
  fetchOptionsSpy: vi.fn(),
  createSpy: vi.fn(),
}));

vi.mock(
  '@wijaya/erp_lead_sidebar/frontend/api/wijayaErpLeadActivities',
  () => ({
    default: { fetchOptions: fetchOptionsSpy, create: createSpy },
  })
);

// The global NextButton stub renders only its default slot; the real Button
// renders :label instead. Mirror that here now the form passes :label with no
// redundant slot, so text-based button lookups keep working.
const LabelledNextButton = {
  props: { label: { type: String, default: '' } },
  template: '<button><slot>{{ label }}</slot></button>',
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
    global: { stubs: { NextButton: LabelledNextButton } },
  });

const findByLabel = (wrapper, labelText) =>
  wrapper.findAll('label').find(l => l.text().includes(labelText));

const submitButton = wrapper =>
  wrapper.findAll('button').find(b => b.text().includes('Add Lead Activity'));

describe('LeadActivityForm', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    fetchOptionsSpy.mockResolvedValue({
      data: {
        options: ['Call', 'WhatsApp'],
        default_date: '2026-08-10',
        person_in_charge_options: [
          { value: 'agent@erp.example', label: 'Agent Example' },
        ],
        person_in_charge_available: true,
      },
    });
    createSpy.mockResolvedValue({
      data: { status: 'success', message: 'Lead Activity added successfully.' },
    });
  });

  it('shows a link-first banner and no submit when no ERP Lead is linked', async () => {
    const wrapper = mountForm({ erpLeadId: '' });
    await flushPromises();

    expect(wrapper.text()).toContain('Create or link an ERP Lead first');
    expect(submitButton(wrapper)).toBeUndefined();
    expect(fetchOptionsSpy).not.toHaveBeenCalled();
  });

  it('fetches runtime options on mount for a linked, configured draft', async () => {
    mountForm();
    await flushPromises();

    expect(fetchOptionsSpy).toHaveBeenCalledTimes(1);
    expect(fetchOptionsSpy).toHaveBeenCalledWith(42);
  });

  // Regression: ApiClient assigns `this.options` in its constructor, which
  // shadowed a prototype method named `options`. The renamed `fetchOptions`
  // must resolve and its options/default_date must populate the form.
  it('populates activity options and the default date from the response', async () => {
    const wrapper = mountForm();
    await flushPromises();

    expect(fetchOptionsSpy).toHaveBeenCalledWith(42);
    const activitySelect = findByLabel(wrapper, 'Lead Activity').find('select');
    expect(activitySelect.findAll('option').map(o => o.text())).toEqual([
      '— Select —',
      'Call',
      'WhatsApp',
    ]);
    expect(findByLabel(wrapper, 'Date').find('input').element.value).toBe(
      '2026-08-10'
    );
  });

  it('keeps submit disabled until required fields are valid', async () => {
    const wrapper = mountForm();
    await flushPromises();

    // No lead_activity selected yet -> disabled.
    expect(submitButton(wrapper).attributes('disabled')).toBeDefined();

    const select = findByLabel(wrapper, 'Lead Activity').find('select');
    await select.setValue('Call');

    expect(submitButton(wrapper).attributes('disabled')).toBeUndefined();
  });

  it('submits only on click and clears follow-up fields when follow_up is No', async () => {
    const wrapper = mountForm();
    await flushPromises();

    await findByLabel(wrapper, 'Lead Activity').find('select').setValue('Call');
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

  it('resets activity fields and starts a new submission id after success', async () => {
    const wrapper = mountForm();
    await flushPromises();

    await findByLabel(wrapper, 'Lead Activity').find('select').setValue('Call');
    await submitButton(wrapper).trigger('click');
    await flushPromises();

    const firstId = createSpy.mock.calls[0][1].submission_id;
    expect(wrapper.text()).toContain('Lead Activity added successfully.');

    // The lead_activity select is reset, so submit is disabled again.
    expect(submitButton(wrapper).attributes('disabled')).toBeDefined();

    // A fresh submission uses a new id.
    await findByLabel(wrapper, 'Lead Activity')
      .find('select')
      .setValue('WhatsApp');
    await submitButton(wrapper).trigger('click');
    await flushPromises();

    const secondId = createSpy.mock.calls[1][1].submission_id;
    expect(secondId).not.toBe(firstId);
  });

  it('does not call create a second time after an outcome_unknown (same id stays blocked)', async () => {
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

    await findByLabel(wrapper, 'Lead Activity').find('select').setValue('Call');
    await submitButton(wrapper).trigger('click');
    await flushPromises();

    expect(createSpy).toHaveBeenCalledTimes(1);
    expect(wrapper.text()).toContain('ERP may have accepted it.');
    // Submit is now disabled; a repeated click must not fire a second create.
    expect(submitButton(wrapper).attributes('disabled')).toBeDefined();

    await submitButton(wrapper).trigger('click');
    await flushPromises();

    expect(createSpy).toHaveBeenCalledTimes(1);
  });

  it('surfaces an outcome-unknown warning without discarding the entered values', async () => {
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

    await findByLabel(wrapper, 'Lead Activity').find('select').setValue('Call');
    await submitButton(wrapper).trigger('click');
    await flushPromises();

    expect(wrapper.text()).toContain('ERP may have accepted it.');
    // Value retained for a manual verify/retry.
    expect(
      findByLabel(wrapper, 'Lead Activity').find('select').element.value
    ).toBe('Call');
  });

  it('renders the Person In Charge options with a blank default and no assignee prefill', async () => {
    // Even with an assigned agent, nothing is derived from the assignee: the
    // agent must pick manually, so the picker defaults to blank.
    const wrapper = mountForm({
      currentChat: { meta: { assignee: { id: 55, name: 'Agent Smith' } } },
    });
    await flushPromises();

    const picSelect = findByLabel(wrapper, 'Person In Charge').find('select');
    expect(picSelect.findAll('option').map(o => o.text())).toEqual([
      '— None —',
      'Agent Example',
    ]);
    expect(picSelect.element.value).toBe('');
  });

  it('submits the manually selected Person In Charge value only on click', async () => {
    const wrapper = mountForm();
    await flushPromises();

    await findByLabel(wrapper, 'Lead Activity').find('select').setValue('Call');
    await findByLabel(wrapper, 'Person In Charge')
      .find('select')
      .setValue('agent@erp.example');

    // Nothing submitted until the explicit click.
    expect(createSpy).not.toHaveBeenCalled();

    await submitButton(wrapper).trigger('click');
    await flushPromises();

    expect(createSpy.mock.calls[0][1].person_in_charge).toBe(
      'agent@erp.example'
    );
  });

  it('retains the selected Person In Charge on failure and resets it to blank on success', async () => {
    createSpy.mockRejectedValueOnce({
      response: { data: { status: 'invalid', error: 'PIC invalid.' } },
    });

    const wrapper = mountForm();
    await flushPromises();

    const pic = () => findByLabel(wrapper, 'Person In Charge').find('select');
    await findByLabel(wrapper, 'Lead Activity').find('select').setValue('Call');
    await pic().setValue('agent@erp.example');

    // Failure keeps the entered value for a corrected retry.
    await submitButton(wrapper).trigger('click');
    await flushPromises();
    expect(pic().element.value).toBe('agent@erp.example');

    // A subsequent success resets the picker back to blank.
    await findByLabel(wrapper, 'Lead Activity').find('select').setValue('Call');
    await submitButton(wrapper).trigger('click');
    await flushPromises();
    expect(pic().element.value).toBe('');
  });

  it('disables the Person In Charge picker and warns when the directory is unavailable, still allowing blank submit', async () => {
    fetchOptionsSpy.mockResolvedValue({
      data: {
        options: ['Call'],
        default_date: '2026-08-10',
        person_in_charge_options: [],
        person_in_charge_available: false,
      },
    });

    const wrapper = mountForm();
    await flushPromises();

    const picSelect = findByLabel(wrapper, 'Person In Charge').find('select');
    expect(picSelect.attributes('disabled')).toBeDefined();
    expect(wrapper.text()).toContain('ERP user list is unavailable');
    // The warning hint is present, so its association is wired (not dangling).
    expect(picSelect.attributes('aria-describedby')).toBe(
      'erp-activity-pic-help'
    );

    // A blank Person In Charge can still be submitted.
    await findByLabel(wrapper, 'Lead Activity').find('select').setValue('Call');
    await submitButton(wrapper).trigger('click');
    await flushPromises();

    expect(createSpy).toHaveBeenCalledTimes(1);
    expect(createSpy.mock.calls[0][1].person_in_charge).toBe('');
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

    await findByLabel(wrapper, 'Lead Activity').find('select').setValue('Call');
    await submitButton(wrapper).trigger('click');
    await flushPromises();

    expect(wrapper.text()).toContain('ERPNext rejected the Lead Activity.');
    expect(
      findByLabel(wrapper, 'Lead Activity').find('select').element.value
    ).toBe('Call');
  });

  it('lays out a single scrollable body with a stable non-scrolling footer action', async () => {
    const wrapper = mountForm();
    await flushPromises();

    // Exactly one scrollable content region.
    const scrollers = wrapper
      .findAll('div')
      .filter(d => d.classes().includes('overflow-y-auto'));
    expect(scrollers.length).toBe(1);

    // The primary action sits in a non-scrolling footer sibling (shrink-0),
    // which is not the scroller, so it cannot cover the fields.
    const footer = wrapper
      .findAll('div')
      .find(
        d =>
          d.classes().includes('shrink-0') &&
          d.classes().includes('border-t') &&
          d.find('button').exists()
      );
    expect(footer).toBeTruthy();
    expect(footer.classes()).not.toContain('overflow-y-auto');
    expect(footer.classes()).not.toContain('sticky');
    expect(submitButton(wrapper)).toBeTruthy();
  });

  it('explains the primary action and shows a plain-language disabled reason', async () => {
    const wrapper = mountForm();
    await flushPromises();

    // No Lead Activity selected yet -> disabled with a clear reason.
    expect(submitButton(wrapper).attributes('disabled')).toBeDefined();
    expect(wrapper.text()).toContain(
      'Adds a new activity to the linked ERP Lead in ERPNext.'
    );
    expect(wrapper.text()).toContain(
      'Complete the required fields marked * before adding the activity.'
    );
  });

  it('marks the required fields with an accessible required cue', async () => {
    const wrapper = mountForm();
    await flushPromises();

    expect(
      findByLabel(wrapper, 'Date').find('input').attributes('aria-required')
    ).toBe('true');
    expect(
      findByLabel(wrapper, 'Lead Activity')
        .find('select')
        .attributes('aria-required')
    ).toBe('true');
  });

  it('binds field aria-describedby only when the conditional hint is rendered', async () => {
    const wrapper = mountForm();
    await flushPromises();

    // Date is valid (default date applied), so no hint span and no reference.
    const dateInput = findByLabel(wrapper, 'Date').find('input');
    expect(wrapper.find('#erp-activity-date-help').exists()).toBe(false);
    expect(dateInput.attributes('aria-describedby')).toBe(undefined);

    // Lead Activity is required and unselected, so its hint is shown and wired.
    const activitySelect = findByLabel(wrapper, 'Lead Activity').find('select');
    expect(wrapper.find('#erp-activity-type-help').exists()).toBe(true);
    expect(activitySelect.attributes('aria-describedby')).toBe(
      'erp-activity-type-help'
    );

    // Person In Charge directory is available, so no warning and no reference.
    const picSelect = findByLabel(wrapper, 'Person In Charge').find('select');
    expect(wrapper.find('#erp-activity-pic-help').exists()).toBe(false);
    expect(picSelect.attributes('aria-describedby')).toBe(undefined);
  });
});
