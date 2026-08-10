import { mount, flushPromises } from '@vue/test-utils';
import LeadActivityForm from '@wijaya/erp_lead_sidebar/frontend/LeadActivityForm.vue';

// The manual Lead Activity form is fully isolated from the Lead Details flow: it
// fetches its own runtime options, only submits on an explicit click, and only
// when the server-derived erp_lead_id is present. These specs drive the real
// component and assert that contract at the API surface.

const { optionsSpy, createSpy } = vi.hoisted(() => ({
  optionsSpy: vi.fn(),
  createSpy: vi.fn(),
}));

vi.mock(
  '@wijaya/erp_lead_sidebar/frontend/api/wijayaErpLeadActivities',
  () => ({
    default: { options: optionsSpy, create: createSpy },
  })
);

const mountForm = (props = {}) =>
  mount(LeadActivityForm, {
    props: {
      conversationId: 42,
      currentChat: {},
      erpLeadId: 'LEAD-0001',
      configured: true,
      ...props,
    },
  });

const findByLabel = (wrapper, labelText) =>
  wrapper.findAll('label').find(l => l.text().includes(labelText));

const submitButton = wrapper =>
  wrapper.findAll('button').find(b => b.text().includes('Add Lead Activity'));

describe('LeadActivityForm', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    optionsSpy.mockResolvedValue({
      data: { options: ['Call', 'WhatsApp'], default_date: '2026-08-10' },
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
    expect(optionsSpy).not.toHaveBeenCalled();
  });

  it('fetches runtime options on mount for a linked, configured draft', async () => {
    mountForm();
    await flushPromises();

    expect(optionsSpy).toHaveBeenCalledTimes(1);
    expect(optionsSpy).toHaveBeenCalledWith(42);
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
});
