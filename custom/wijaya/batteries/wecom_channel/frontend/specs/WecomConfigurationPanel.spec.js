import { mount, flushPromises } from '@vue/test-utils';

const { dispatchSpy, alertSpy } = vi.hoisted(() => ({
  dispatchSpy: vi.fn(),
  alertSpy: vi.fn(),
}));

vi.mock('dashboard/composables', () => ({ useAlert: alertSpy }));

import WecomConfigurationPanel from '@wijaya/wecom_channel/frontend/WecomConfigurationPanel.vue';

const NextButtonStub = {
  props: { label: { type: String, default: '' }, isLoading: Boolean },
  emits: ['click'],
  template: '<button @click="$emit(\'click\')">{{ label }}</button>',
};

const WootCodeStub = {
  props: { script: { type: String, default: '' } },
  template: '<code>{{ script }}</code>',
};

const WootInputStub = {
  props: {
    modelValue: { type: String, default: '' },
    type: { type: String, default: 'text' },
  },
  emits: ['update:modelValue'],
  template:
    '<input :type="type" :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
};

const mountPanel = (inbox = { id: 9, corp_id: 'ww-corp-xyz' }) =>
  mount(WecomConfigurationPanel, {
    props: { inbox },
    global: {
      mocks: { $t: key => key, $store: { dispatch: dispatchSpy } },
      stubs: {
        SettingsFieldSection: { template: '<div><slot /></div>' },
        NextButton: NextButtonStub,
        'woot-code': WootCodeStub,
        'woot-input': WootInputStub,
      },
    },
  });

describe('WecomConfigurationPanel', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    dispatchSpy.mockResolvedValue({});
  });

  it('renders the corp-scoped callback URL from window origin and corp id', () => {
    const wrapper = mountPanel();
    expect(wrapper.html()).toContain(
      `${window.location.origin}/webhooks/wecom/ww-corp-xyz`
    );
  });

  it('saves the secret and open_kfid via updateInbox', async () => {
    const wrapper = mountPanel();
    const inputs = wrapper.findAll('input');
    await inputs[0].setValue('the-secret');
    await inputs[1].setValue('wkFoo');

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(dispatchSpy).toHaveBeenCalledWith('inboxes/updateInbox', {
      id: 9,
      formData: false,
      channel: { secret: 'the-secret', open_kfid: 'wkFoo' },
    });
  });

  it('a secret-only save omits the blank open_kfid', async () => {
    const wrapper = mountPanel();
    const inputs = wrapper.findAll('input');
    await inputs[0].setValue('the-secret');

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(dispatchSpy).toHaveBeenCalledWith('inboxes/updateInbox', {
      id: 9,
      formData: false,
      channel: { secret: 'the-secret' },
    });
  });

  it('an open-kfid-only save omits the blank secret so it is never wiped', async () => {
    const wrapper = mountPanel();
    const inputs = wrapper.findAll('input');
    await inputs[1].setValue('wkFoo');

    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(dispatchSpy).toHaveBeenCalledWith('inboxes/updateInbox', {
      id: 9,
      formData: false,
      channel: { open_kfid: 'wkFoo' },
    });
  });

  it('preserves and displays an existing serialized open_kfid', () => {
    const wrapper = mountPanel({
      id: 9,
      corp_id: 'ww-corp-xyz',
      open_kfid: 'wkExisting',
    });
    const inputs = wrapper.findAll('input');
    expect(inputs[1].element.value).toBe('wkExisting');
  });

  it('renders the secret input as a password field without exposing a saved secret', () => {
    const wrapper = mountPanel({
      id: 9,
      corp_id: 'ww-corp-xyz',
      open_kfid: 'wkExisting',
    });
    const inputs = wrapper.findAll('input');
    expect(inputs[0].attributes('type')).toBe('password');
    expect(inputs[0].element.value).toBe('');
  });
});
