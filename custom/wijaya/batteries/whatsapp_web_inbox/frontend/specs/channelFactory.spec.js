import { shallowMount, mount } from '@vue/test-utils';
import ChannelFactory from 'dashboard/routes/dashboard/settings/inbox/ChannelFactory.vue';
import { WHATSAPP_WEB_CHANNEL_KEY } from '@wijaya/whatsapp_web_inbox/frontend/channel/whatsappWebChannel';

// Keep the wizard light so the factory mapping can be asserted without loading the
// wizard's own dependencies.
vi.mock(
  '@wijaya/whatsapp_web_inbox/frontend/CreateWhatsappWebInbox.vue',
  () => ({
    default: {
      name: 'WhatsappWebWizardStub',
      template: '<div data-testid="wa-wizard" />',
    },
  })
);

const factory = channelName =>
  shallowMount(ChannelFactory, { props: { channelName } });

describe('ChannelFactory whatsapp_web mapping', () => {
  it('maps the whatsapp_web_unofficial key to the battery wizard', () => {
    // Full mount so the (lightweight, mocked) wizard's template renders. The factory
    // only instantiates the matched component, so no heavy native channel loads here.
    const wrapper = mount(ChannelFactory, {
      props: { channelName: WHATSAPP_WEB_CHANNEL_KEY },
    });
    expect(wrapper.find('[data-testid="wa-wizard"]').exists()).toBe(true);
  });

  it('keeps the existing native channel mappings intact (regression)', () => {
    expect(factory('api').html()).not.toBe('');
    expect(factory('website').html()).not.toBe('');
    // Native keys must not resolve to our wizard.
    expect(factory('api').find('[data-testid="wa-wizard"]').exists()).toBe(
      false
    );
  });

  it('renders nothing for an unknown key', () => {
    expect(factory('does_not_exist').html()).toBe('');
  });
});
