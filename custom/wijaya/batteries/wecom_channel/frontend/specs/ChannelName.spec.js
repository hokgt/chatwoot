import { mount } from '@vue/test-utils';
import wecomInbox from '@wijaya/wecom_channel/frontend/i18n/wecomInbox.json';
import {
  isWecomChannelType,
  wecomReadableChannelName,
} from '@wijaya/wecom_channel/frontend/helpers/wecomInbox';

// Resolve a dotted i18n key against a messages tree (only the battery WeCom keys are
// needed here; native INBOX_MGMT keys fall through to the key itself).
const resolve = (obj, key) =>
  key
    .split('.')
    .reduce((acc, part) => (acc == null ? undefined : acc[part]), obj);

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => resolve(wecomInbox, key) ?? key }),
}));

vi.mock('dashboard/composables/store', () => ({
  useStoreGetters: () => ({ 'globalConfig/get': { value: {} } }),
}));

import ChannelName from 'dashboard/routes/dashboard/settings/inbox/components/ChannelName.vue';

const render = channelType => mount(ChannelName, { props: { channelType } });

describe('wecom_channel ChannelName', () => {
  describe('helper', () => {
    it('matches only the Channel::Wecom type', () => {
      expect(isWecomChannelType('Channel::Wecom')).toBe(true);
      expect(isWecomChannelType('Channel::Api')).toBe(false);
    });

    it('returns the battery i18n title for WeCom, undefined otherwise', () => {
      const t = key => resolve(wecomInbox, key) ?? key;
      expect(
        wecomReadableChannelName({ t, channelType: 'Channel::Wecom' })
      ).toBe('WeCom (微信客服)');
      expect(
        wecomReadableChannelName({ t, channelType: 'Channel::Telegram' })
      ).toBeUndefined();
    });
  });

  it('renders the WeCom label for a Channel::Wecom row', () => {
    const wrapper = render('Channel::Wecom');
    expect(wrapper.text()).toBe('WeCom (微信客服)');
  });

  it('never renders the broken INBOX_MGMT.CHANNELS.undefined label', () => {
    const wrapper = render('Channel::Wecom');
    expect(wrapper.text()).not.toContain('undefined');
  });

  it('leaves other channel labels untouched', () => {
    const wrapper = render('Channel::Telegram');
    expect(wrapper.text()).toBe('INBOX_MGMT.CHANNELS.TELEGRAM');
  });
});
