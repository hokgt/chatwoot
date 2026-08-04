import { mount } from '@vue/test-utils';
import { ref } from 'vue';
import CopilotMenuBar from 'dashboard/components/widgets/WootWriter/CopilotMenuBar.vue';

// The reply editor mode getter is the only store dependency CopilotMenuBar
// reads. Fix it to REPLY so the general menu builds its full item list.
vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ref('REPLY'),
}));

// @vueuse/core size/window helpers only drive submenu positioning; stub them
// with static refs so jsdom layout measurement does not interfere.
vi.mock('@vueuse/core', () => ({
  useElementSize: () => ({ height: ref(0), width: ref(0) }),
  useWindowSize: () => ({ width: ref(1024), height: ref(768) }),
}));

const ButtonStub = {
  props: ['label'],
  template: '<button class="menu-item">{{ label }}</button>',
};

const mountMenuBar = props =>
  mount(CopilotMenuBar, {
    props: {
      conversationId: 123,
      hasContent: false,
      ...props,
    },
    global: {
      stubs: {
        Button: ButtonStub,
        DropdownBody: { template: '<div><slot /></div>' },
        Icon: true,
      },
    },
  });

describe('CopilotMenuBar', () => {
  // isMarineConversation is derived (in ReplyTopPanel via useCaptain) from the
  // current conversation inbox's marine_assistant_id. Marine-linked
  // conversations must hide the global "Ask Copilot" entry until the Marine NL
  // query UI ships, while non-Marine conversations keep native Captain behavior.
  it('hides "Ask Copilot" when the inbox is Marine-linked', () => {
    const wrapper = mountMenuBar({ isMarineConversation: true });

    expect(wrapper.text()).not.toContain('Ask Copilot');
  });

  it('shows "Ask Copilot" when the inbox is not Marine-linked', () => {
    const wrapper = mountMenuBar({ isMarineConversation: false });

    expect(wrapper.text()).toContain('Ask Copilot');
  });
});
