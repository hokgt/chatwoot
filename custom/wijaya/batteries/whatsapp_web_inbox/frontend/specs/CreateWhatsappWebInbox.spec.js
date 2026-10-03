import { mount, flushPromises } from '@vue/test-utils';

const { createSpy, statusSpy, qrSpy, connectSpy, replaceSpy, pollRef } =
  vi.hoisted(() => ({
    createSpy: vi.fn(),
    statusSpy: vi.fn(),
    qrSpy: vi.fn(),
    connectSpy: vi.fn(),
    replaceSpy: vi.fn(),
    pollRef: { cb: null },
  }));

vi.mock('@wijaya/whatsapp_web_inbox/frontend/api/whatsappWeb', () => ({
  default: {
    create: createSpy,
    status: statusSpy,
    qr: qrSpy,
    connect: connectSpy,
  },
}));

// Make the poller deterministic: start() runs the poll callback once, and the callback
// is captured so a test can drive subsequent ticks by hand (real status progression).
vi.mock(
  '@wijaya/whatsapp_web_inbox/frontend/composables/useConnectorPolling',
  () => ({
    useConnectorPolling: cb => {
      pollRef.cb = cb;
      return { start: () => cb(), stop: vi.fn() };
    },
  })
);

vi.mock('widget/helpers/uuid', () => ({ default: () => 'stable-token' }));

vi.mock('vue-router', () => ({ useRouter: () => ({ replace: replaceSpy }) }));

import CreateWhatsappWebInbox from '@wijaya/whatsapp_web_inbox/frontend/CreateWhatsappWebInbox.vue';

const NextButtonStub = {
  props: {
    label: { type: String, default: '' },
    type: { type: String, default: 'button' },
    disabled: Boolean,
  },
  emits: ['click'],
  template:
    '<button :type="type" :disabled="disabled" @click="$emit(\'click\')"><slot>{{ label }}</slot></button>',
};

const mountWizard = () =>
  mount(CreateWhatsappWebInbox, {
    global: {
      stubs: { PageHeader: true, NextButton: NextButtonStub },
    },
  });

const fillForm = async wrapper => {
  await wrapper.find('input[type="text"]').setValue('Sales WA');
  await wrapper.find('input[type="checkbox"]').setValue(true);
};

describe('CreateWhatsappWebInbox', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    createSpy.mockResolvedValue({
      data: {
        inbox_id: 7,
        status: 'pending',
        provisioning_state: 'pending',
        connector_available: true,
      },
    });
    statusSpy.mockResolvedValue({
      data: { status: 'waiting_for_qr', connector_available: true },
    });
    qrSpy.mockResolvedValue({
      data: { available: true, data_url: 'data:image/png;base64,QQ==' },
    });
  });

  it('does not submit until the name and the risk acknowledgement are provided', async () => {
    const wrapper = mountWizard();
    await wrapper.find('form').trigger('submit.prevent');
    expect(createSpy).not.toHaveBeenCalled();

    // Name alone must NOT be enough — the risk acknowledgement specifically gates submit.
    await wrapper.find('input[type="text"]').setValue('Sales WA');
    await wrapper.find('form').trigger('submit.prevent');
    expect(createSpy).not.toHaveBeenCalled();

    await wrapper.find('input[type="checkbox"]').setValue(true);
    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();
    expect(createSpy).toHaveBeenCalledWith({
      name: 'Sales WA',
      request_token: 'stable-token',
      acknowledged: true,
    });
  });

  it('reuses the same request token across retries', async () => {
    const wrapper = mountWizard();
    await fillForm(wrapper);

    createSpy.mockRejectedValueOnce({ response: { status: 500 } });
    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();

    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();

    expect(createSpy).toHaveBeenCalledTimes(2);
    expect(createSpy.mock.calls[0][0].request_token).toBe('stable-token');
    expect(createSpy.mock.calls[1][0].request_token).toBe('stable-token');
  });

  it('renders the QR image from the data URL and never a raw QR string', async () => {
    // Even if a raw qr string ever leaked into the API payload, it must never reach the
    // DOM — only the data URL is ever bound to the <img>.
    qrSpy.mockResolvedValue({
      data: {
        available: true,
        data_url: 'data:image/png;base64,QQ==',
        qr: 'RAW-QR-LEAK-2@wa.link',
        raw_qr: 'RAW-QR-LEAK-2@wa.link',
      },
    });
    const wrapper = mountWizard();
    await fillForm(wrapper);
    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();

    const img = wrapper.find('[data-testid="qr-image"]');
    expect(img.exists()).toBe(true);
    expect(img.attributes('src')).toBe('data:image/png;base64,QQ==');
    expect(img.attributes('alt')).toBeTruthy();
    expect(wrapper.html()).not.toContain('RAW-QR-LEAK-2');
  });

  it('shows success and navigates to add agents when connected', async () => {
    statusSpy.mockResolvedValue({
      data: { status: 'connected', connector_available: true },
    });
    const wrapper = mountWizard();
    await fillForm(wrapper);
    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();

    expect(wrapper.text()).toContain('WhatsApp connected');
    await wrapper.findAll('button').at(-1).trigger('click');
    expect(replaceSpy).toHaveBeenCalledWith(
      expect.objectContaining({
        name: 'settings_inboxes_add_agents',
        params: { page: 'new', inbox_id: 7 },
      })
    );
  });

  it('drives real pairing from a disconnected session: connects exactly once, then connecting -> waiting_for_qr -> connected', async () => {
    // The FIRST server state is the real post-provision connector state: 'disconnected'
    // with no QR — NOT a fabricated 'waiting_for_qr'. Pairing must not progress until the
    // wizard explicitly calls connect in response to that disconnected state.
    statusSpy.mockReset();
    statusSpy.mockResolvedValueOnce({
      data: {
        status: 'disconnected',
        provisioning_state: 'provisioned',
        connector_available: true,
      },
    });
    connectSpy.mockResolvedValue({
      data: {
        status: 'connecting',
        provisioning_state: 'provisioned',
        connector_available: true,
      },
    });

    const wrapper = mountWizard();
    await fillForm(wrapper);
    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises(); // create + first tick (disconnected) -> connect called

    // connect was driven by the disconnected state, not a pre-supplied waiting_for_qr.
    expect(connectSpy).toHaveBeenCalledTimes(1);
    expect(connectSpy).toHaveBeenCalledWith(7);
    // The first status the wizard ever saw was 'disconnected'.
    await expect(statusSpy.mock.results[0].value).resolves.toMatchObject({
      data: { status: 'disconnected' },
    });

    // Tick 2: connector now reports waiting_for_qr -> the QR image appears.
    statusSpy.mockResolvedValueOnce({
      data: {
        status: 'waiting_for_qr',
        provisioning_state: 'provisioned',
        connector_available: true,
      },
    });
    await pollRef.cb();
    await flushPromises();
    expect(wrapper.find('[data-testid="qr-image"]').exists()).toBe(true);

    // Tick 3: connected -> success panel, and connect is never called again.
    statusSpy.mockResolvedValueOnce({
      data: {
        status: 'connected',
        provisioning_state: 'provisioned',
        connector_available: true,
      },
    });
    await pollRef.cb();
    await flushPromises();
    expect(wrapper.text()).toContain('WhatsApp connected');
    expect(connectSpy).toHaveBeenCalledTimes(1);
  });

  it('does not call connect while the mapping is still provisioning (pending)', async () => {
    // A provisioned+disconnected state is the ONLY trigger. A pending mapping, even if the
    // connector momentarily reports disconnected, must not start pairing.
    statusSpy.mockReset();
    statusSpy.mockResolvedValue({
      data: {
        status: 'disconnected',
        provisioning_state: 'pending',
        connector_available: true,
      },
    });
    const wrapper = mountWizard();
    await fillForm(wrapper);
    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();
    expect(connectSpy).not.toHaveBeenCalled();
  });

  it('surfaces an actionable error and allows an intentional retry when connect fails', async () => {
    statusSpy.mockReset();
    statusSpy.mockResolvedValue({
      data: {
        status: 'disconnected',
        provisioning_state: 'provisioned',
        connector_available: true,
      },
    });
    connectSpy.mockRejectedValueOnce({ response: { status: 500 } });

    const wrapper = mountWizard();
    await fillForm(wrapper);
    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();

    expect(connectSpy).toHaveBeenCalledTimes(1);
    const retry = wrapper.find('[data-testid="retry-connect"]');
    expect(retry.exists()).toBe(true);

    // A further poll tick must NOT auto-retry connect (no spin/flood).
    await pollRef.cb();
    await flushPromises();
    expect(connectSpy).toHaveBeenCalledTimes(1);

    // Intentional retry re-arms and calls connect again.
    connectSpy.mockResolvedValueOnce({
      data: {
        status: 'connecting',
        provisioning_state: 'provisioned',
        connector_available: true,
      },
    });
    await retry.trigger('click');
    await flushPromises();
    expect(connectSpy).toHaveBeenCalledTimes(2);
  });

  it('surfaces a connector-unavailable error on a 503 create', async () => {
    createSpy.mockRejectedValueOnce({ response: { status: 503 } });
    const wrapper = mountWizard();
    await fillForm(wrapper);
    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();

    expect(wrapper.text()).toContain('connector is not available');
  });
});
