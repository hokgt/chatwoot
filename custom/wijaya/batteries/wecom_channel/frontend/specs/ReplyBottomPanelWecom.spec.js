import { shallowMount } from '@vue/test-utils';

// ReplyBottomPanel pulls in composables, activestorage and vuex getters; mock the
// side-effecting ones so the capability computeds can be exercised in isolation.
vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    setSignatureFlagForInbox: vi.fn(),
    fetchSignatureFlagFromUISettings: vi.fn(() => false),
  }),
}));

vi.mock('dashboard/composables/useKeyboardEvents', () => ({
  useKeyboardEvents: vi.fn(),
}));

vi.mock('activestorage', () => ({ start: vi.fn() }));

import ReplyBottomPanel from 'dashboard/components/widgets/WootWriter/ReplyBottomPanel.vue';
import FileUpload from 'vue-upload-component';

const mountPanel = ({ channelType, voiceEnabled = true, props = {} } = {}) =>
  shallowMount(ReplyBottomPanel, {
    props: {
      conversationId: 1,
      portalSlug: '',
      inbox: { channel_type: channelType },
      showFileUpload: true,
      showAudioRecorder: true,
      ...props,
    },
    global: {
      mocks: {
        $t: key => key,
        $store: {
          getters: {
            getCurrentAccountId: 1,
            'accounts/isFeatureEnabledonAccount': () => voiceEnabled,
            'integrations/getUIFlags': { isFetching: false },
          },
        },
      },
      directives: { tooltip: {} },
      stubs: { 'fluent-icon': true },
    },
  });

describe('ReplyBottomPanel WeCom composer capabilities', () => {
  it('shows the attachment button for a WeCom inbox', () => {
    const wrapper = mountPanel({ channelType: 'Channel::Wecom' });
    expect(wrapper.vm.showAttachButton).toBe(true);
    expect(wrapper.findComponent(FileUpload).exists()).toBe(true);
  });

  it('permits only image/video/file types (no audio) for WeCom', () => {
    const wrapper = mountPanel({ channelType: 'Channel::Wecom' });
    const accept = wrapper.vm.allowedFileTypes;
    expect(accept).toContain('image/*');
    expect(accept).toContain('video/*');
    expect(accept).toContain('application/pdf');
    expect(accept).not.toContain('audio/');
  });

  it('hides the audio recorder button for WeCom even with the voice flag + recorder enabled', () => {
    const wrapper = mountPanel({
      channelType: 'Channel::Wecom',
      voiceEnabled: true,
    });
    expect(wrapper.vm.showAudioRecorderButton).toBe(false);
  });

  it('leaves a non-WeCom channel unchanged (audio recorder + audio types still available)', () => {
    const wrapper = mountPanel({
      channelType: 'Channel::Api',
      voiceEnabled: true,
    });
    expect(wrapper.vm.showAudioRecorderButton).toBe(true);
    expect(wrapper.vm.allowedFileTypes).toContain('audio/');
  });
});
