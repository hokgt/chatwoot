import { mount, RouterLinkStub } from '@vue/test-utils';

const { getInboxSpy } = vi.hoisted(() => ({ getInboxSpy: vi.fn() }));

vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ({ value: getInboxSpy }),
}));

vi.mock('dashboard/components-next/message/provider.js', () => ({
  useMessageContext: () => ({ inboxId: { value: 7 } }),
}));

import WhatsappWebFailedMessageNotice from '@wijaya/whatsapp_web_inbox/frontend/WhatsappWebFailedMessageNotice.vue';

const WA_INBOX = {
  channel_type: 'Channel::Api',
  additional_attributes: { wijaya_provider: 'whatsapp_web' },
};

const mountNotice = error =>
  mount(WhatsappWebFailedMessageNotice, {
    props: { error },
    global: { stubs: { 'router-link': RouterLinkStub } },
  });

const notice = wrapper =>
  wrapper.find('[data-testid="whatsapp-web-disconnect-notice"]');

describe('WhatsappWebFailedMessageNotice', () => {
  beforeEach(() => vi.clearAllMocks());

  it('shows a friendly message + a QR shortcut to the exact inbox panel on a 503', () => {
    getInboxSpy.mockReturnValue(WA_INBOX);

    const wrapper = mountNotice('503 Service Unavailable');

    expect(notice(wrapper).exists()).toBe(true);
    expect(wrapper.text()).toContain('WhatsApp disconnected');
    const link = wrapper.findComponent(RouterLinkStub);
    expect(link.props('to')).toEqual({
      name: 'settings_inbox_show',
      params: { inboxId: 7, tab: 'whatsapp-web' },
    });
  });

  it('renders nothing for a whatsapp_web inbox with an unrelated error', () => {
    getInboxSpy.mockReturnValue(WA_INBOX);

    const wrapper = mountNotice('connector rejected request (422)');

    expect(notice(wrapper).exists()).toBe(false);
  });

  it('renders nothing for a non-whatsapp_web inbox even on a 503', () => {
    getInboxSpy.mockReturnValue({
      channel_type: 'Channel::Api',
      additional_attributes: {},
    });

    const wrapper = mountNotice('503 Service Unavailable');

    expect(notice(wrapper).exists()).toBe(false);
  });
});
