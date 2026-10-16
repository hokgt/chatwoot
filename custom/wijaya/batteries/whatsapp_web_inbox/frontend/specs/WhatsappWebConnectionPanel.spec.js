import { mount, flushPromises } from '@vue/test-utils';

const { statusSpy, qrSpy, reconnectSpy, logoutSpy, retrySpy } = vi.hoisted(
  () => ({
    statusSpy: vi.fn(),
    qrSpy: vi.fn(),
    reconnectSpy: vi.fn(),
    logoutSpy: vi.fn(),
    retrySpy: vi.fn(),
  })
);

vi.mock('@wijaya/whatsapp_web_inbox/frontend/api/whatsappWeb', () => ({
  default: {
    status: statusSpy,
    qr: qrSpy,
    reconnect: reconnectSpy,
    logout: logoutSpy,
    retry: retrySpy,
  },
}));

vi.mock(
  '@wijaya/whatsapp_web_inbox/frontend/composables/useConnectorPolling',
  () => ({
    useConnectorPolling: cb => ({ start: () => cb(), stop: vi.fn() }),
  })
);

import WhatsappWebConnectionPanel from '@wijaya/whatsapp_web_inbox/frontend/WhatsappWebConnectionPanel.vue';

const NextButtonStub = {
  props: { label: { type: String, default: '' }, disabled: Boolean },
  emits: ['click'],
  template:
    '<button :disabled="disabled" @click="$emit(\'click\')">{{ label }}</button>',
};

const mountPanel = async () => {
  const wrapper = mount(WhatsappWebConnectionPanel, {
    props: { inbox: { id: 7 } },
    global: { stubs: { NextButton: NextButtonStub } },
  });
  await flushPromises();
  return wrapper;
};

const buttonByText = (wrapper, text) =>
  wrapper.findAll('button').find(b => b.text().includes(text));

describe('WhatsappWebConnectionPanel', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    qrSpy.mockResolvedValue({ data: { available: false, data_url: null } });
  });

  it('renders status and masked linked number for a provisioned inbox', async () => {
    statusSpy.mockResolvedValue({
      data: {
        status: 'connected',
        provisioning_state: 'provisioned',
        connector_available: true,
        wa_jid_masked: '••••7890',
      },
    });
    const wrapper = await mountPanel();

    expect(wrapper.find('[data-testid="whatsapp-web-panel"]').exists()).toBe(
      true
    );
    expect(wrapper.find('[data-testid="connection-status"]').text()).toContain(
      'Connected'
    );
    expect(wrapper.find('[data-testid="linked-number"]').text()).toContain(
      '••••7890'
    );
  });

  it('requires confirmation before logging out', async () => {
    statusSpy.mockResolvedValue({
      data: {
        status: 'connected',
        provisioning_state: 'provisioned',
        connector_available: true,
      },
    });
    logoutSpy.mockResolvedValue({
      data: {
        status: 'logged_out',
        provisioning_state: 'provisioned',
        connector_available: true,
      },
    });
    const wrapper = await mountPanel();

    await buttonByText(wrapper, 'Log out & pair again').trigger('click');
    expect(wrapper.find('[data-testid="logout-confirm"]').exists()).toBe(true);
    expect(logoutSpy).not.toHaveBeenCalled();

    // The first button inside the confirm block is the destructive confirm.
    await wrapper
      .find('[data-testid="logout-confirm"] button')
      .trigger('click');
    await flushPromises();
    expect(logoutSpy).toHaveBeenCalledWith(7);
  });

  it('shows the retry control only when provisioning is not complete', async () => {
    statusSpy.mockResolvedValue({
      data: {
        status: 'error',
        provisioning_state: 'error',
        connector_available: true,
      },
    });
    const wrapper = await mountPanel();

    const retryBtn = buttonByText(wrapper, 'Retry');
    expect(retryBtn).toBeTruthy();
    await retryBtn.trigger('click');
    await flushPromises();
    expect(retrySpy).toHaveBeenCalledWith(7);
  });

  it('hides the retry control once provisioning is complete', async () => {
    statusSpy.mockResolvedValue({
      data: {
        status: 'connected',
        provisioning_state: 'provisioned',
        connector_available: true,
      },
    });
    const wrapper = await mountPanel();

    expect(buttonByText(wrapper, 'Retry')).toBeFalsy();
  });

  it('shows a connector-unavailable notice instead of crashing', async () => {
    statusSpy.mockResolvedValue({ data: { connector_available: false } });
    const wrapper = await mountPanel();

    expect(wrapper.find('[data-testid="connector-unavailable"]').exists()).toBe(
      true
    );
  });

  it('surfaces a sanitized error when a control action fails', async () => {
    statusSpy.mockResolvedValue({
      data: {
        status: 'disconnected',
        provisioning_state: 'provisioned',
        connector_available: true,
      },
    });
    reconnectSpy.mockRejectedValue({ response: { status: 500 } });
    const wrapper = await mountPanel();

    await buttonByText(wrapper, 'Reconnect').trigger('click');
    await flushPromises();
    expect(wrapper.text()).toContain('could not be completed');
  });
});
