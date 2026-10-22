import { mount, flushPromises } from '@vue/test-utils';

const { replaceSpy, dispatchSpy, alertSpy } = vi.hoisted(() => ({
  replaceSpy: vi.fn(),
  dispatchSpy: vi.fn(),
  alertSpy: vi.fn(),
}));

vi.mock('dashboard/routes/index', () => ({
  default: { replace: replaceSpy },
}));

vi.mock('dashboard/composables', () => ({ useAlert: alertSpy }));

import CreateWecomInbox from '@wijaya/wecom_channel/frontend/CreateWecomInbox.vue';

const NextButtonStub = {
  props: {
    label: { type: String, default: '' },
    type: { type: String, default: 'button' },
    isLoading: Boolean,
  },
  template: '<button :type="type"><slot>{{ label }}</slot></button>',
};

const AES_KEY_43 = 'a'.repeat(43);

const mountForm = () =>
  mount(CreateWecomInbox, {
    global: {
      mocks: {
        $t: key => key,
        $store: {
          dispatch: dispatchSpy,
          getters: { 'inboxes/getUIFlags': { isCreating: false } },
        },
      },
      stubs: { PageHeader: true, NextButton: NextButtonStub },
    },
  });

const fillForm = async (wrapper, { aesKey = AES_KEY_43 } = {}) => {
  const inputs = wrapper.findAll('input[type="text"]');
  await inputs[0].setValue('WeChat Support');
  await inputs[1].setValue('ww-corp-123');
  await inputs[2].setValue('verify-token');
  await inputs[3].setValue(aesKey);
};

describe('CreateWecomInbox', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    dispatchSpy.mockResolvedValue({ id: 7 });
  });

  it('renders the inbox name, corp id, token and encoding AES key fields', () => {
    const wrapper = mountForm();
    expect(wrapper.findAll('input[type="text"]').length).toBe(4);
  });

  it('does not dispatch while any required field is empty', async () => {
    const wrapper = mountForm();
    await wrapper.find('form').trigger('submit.prevent');
    expect(dispatchSpy).not.toHaveBeenCalled();
  });

  it('rejects an EncodingAESKey that is not exactly 43 characters', async () => {
    const wrapper = mountForm();
    await fillForm(wrapper, { aesKey: 'a'.repeat(42) });
    await wrapper.find('form').trigger('submit.prevent');
    expect(dispatchSpy).not.toHaveBeenCalled();

    await wrapper.findAll('input[type="text"]')[3].setValue('a'.repeat(44));
    await wrapper.find('form').trigger('submit.prevent');
    expect(dispatchSpy).not.toHaveBeenCalled();
  });

  it('dispatches the native wecom create payload and redirects on a valid 43-char key', async () => {
    const wrapper = mountForm();
    await fillForm(wrapper);
    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();

    expect(dispatchSpy).toHaveBeenCalledWith('inboxes/createChannel', {
      name: 'WeChat Support',
      channel: {
        type: 'wecom',
        corp_id: 'ww-corp-123',
        token: 'verify-token',
        encoding_aes_key: AES_KEY_43,
      },
    });

    expect(replaceSpy).toHaveBeenCalledWith(
      expect.objectContaining({
        name: 'settings_inboxes_add_agents',
        params: { page: 'new', inbox_id: 7 },
      })
    );
  });
});
