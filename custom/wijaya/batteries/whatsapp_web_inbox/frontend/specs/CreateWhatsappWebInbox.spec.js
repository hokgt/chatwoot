import { mount, flushPromises } from '@vue/test-utils';

const { createSpy, statusSpy, qrSpy, replaceSpy } = vi.hoisted(() => ({
  createSpy: vi.fn(),
  statusSpy: vi.fn(),
  qrSpy: vi.fn(),
  replaceSpy: vi.fn(),
}));

vi.mock('@wijaya/whatsapp_web_inbox/frontend/api/whatsappWeb', () => ({
  default: { create: createSpy, status: statusSpy, qr: qrSpy },
}));

// Make the poller deterministic: start() runs the poll callback exactly once.
vi.mock(
  '@wijaya/whatsapp_web_inbox/frontend/composables/useConnectorPolling',
  () => ({
    useConnectorPolling: cb => ({ start: () => cb(), stop: vi.fn() }),
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

  it('surfaces a connector-unavailable error on a 503 create', async () => {
    createSpy.mockRejectedValueOnce({ response: { status: 503 } });
    const wrapper = mountWizard();
    await fillForm(wrapper);
    await wrapper.find('form').trigger('submit.prevent');
    await flushPromises();

    expect(wrapper.text()).toContain('connector is not available');
  });
});
