import { ref, nextTick } from 'vue';
import { mount } from '@vue/test-utils';
import ChannelItem from 'dashboard/components/widgets/ChannelItem.vue';

// Shared holders (prefixed so vitest allows them inside the hoisted mock factories).
// Each is reassigned to a fresh Vue ref per test so reactivity/hydration is exercised.
const mockRefs = vi.hoisted(() => ({
  account: null,
  globalConfig: null,
  accountId: null,
}));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    accountId: mockRefs.accountId,
    currentAccount: mockRefs.account,
  }),
}));
vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => mockRefs.globalConfig,
}));
vi.mock('vue-router', () => ({ useRouter: () => ({ push: vi.fn() }) }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

import ChannelList from 'dashboard/routes/dashboard/settings/inbox/ChannelList.vue';

const mountList = () =>
  mount(ChannelList, {
    global: { stubs: { ChannelSelector: true } },
  });

const channelItems = wrapper => wrapper.findAllComponents(ChannelItem);

describe('wecom_channel ChannelList direct-load hydration', () => {
  beforeEach(() => {
    mockRefs.account = ref(undefined);
    mockRefs.globalConfig = ref(undefined);
    mockRefs.accountId = ref(3);
  });

  it('renders without throwing when globalConfig and account are undefined', () => {
    const wrapper = mountList();
    expect(wrapper.exists()).toBe(true);
    // Loading-gated: no channel cards until globalConfig hydrates.
    expect(channelItems(wrapper)).toHaveLength(0);
  });

  it('does not crash when the account has no features yet', () => {
    mockRefs.globalConfig.value = { apiChannelName: 'API' };
    mockRefs.account.value = { id: 1 }; // features undefined — the reported crash input

    const wrapper = mountList();

    // Cards render; each ChannelItem receives a safe {} instead of undefined, so
    // Object.keys(...) and enabledFeatures.channel_voice never throw.
    expect(channelItems(wrapper).length).toBeGreaterThan(0);
    expect(channelItems(wrapper)[0].props('enabledFeatures')).toEqual({});
  });

  it('populates channels and features after the store hydrates', async () => {
    const wrapper = mountList();
    expect(channelItems(wrapper)).toHaveLength(0);

    const features = { channel_website: true, channel_voice: true };
    mockRefs.globalConfig.value = { apiChannelName: 'API' };
    mockRefs.account.value = { id: 1, features };
    await nextTick();

    const items = channelItems(wrapper);
    expect(items.length).toBeGreaterThan(0);
    expect(items[0].props('enabledFeatures')).toEqual(features);
  });
});
