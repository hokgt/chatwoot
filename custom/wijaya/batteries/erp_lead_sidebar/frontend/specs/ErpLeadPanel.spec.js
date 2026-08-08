import { mount, flushPromises } from '@vue/test-utils';
import ErpLeadPanel from '@wijaya/erp_lead_sidebar/frontend/ErpLeadPanel.vue';

// Zero-draft safety mirror on the client: while ERP is unconfigured the backend
// never persists a draft on open, so opening/editing the panel must issue no
// autosave (PATCH) and no sync (POST) until the server confirms configured:true.
// These specs drive the real component (no weakening) and assert the API surface.

const { showSpy, saveSpy, syncSpy } = vi.hoisted(() => ({
  showSpy: vi.fn(),
  saveSpy: vi.fn(),
  syncSpy: vi.fn(),
}));

vi.mock('@wijaya/erp_lead_sidebar/frontend/api/wijayaErpLeadDrafts', () => ({
  default: { show: showSpy, save: saveSpy, sync: syncSpy },
}));

const mountPanel = () => mount(ErpLeadPanel, { props: { conversationId: 42 } });

describe('ErpLeadPanel unconfigured gating', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.runOnlyPendingTimers();
    vi.useRealTimers();
  });

  it('opens with configured=false and never autosaves before the server confirms', async () => {
    // Server reports the ERP connection is unconfigured; a brand-new draft
    // (no stored fields) would normally schedule an immediate autosave.
    showSpy.mockResolvedValue({ data: { configured: false, fields: {} } });

    mountPanel();
    await flushPromises();

    expect(showSpy).toHaveBeenCalledTimes(1);

    // Even after the autosave debounce window elapses, no PATCH is issued.
    vi.advanceTimersByTime(1000);
    await flushPromises();

    expect(saveSpy).not.toHaveBeenCalled();
  });

  it('disables Create Lead and issues no sync while unconfigured', async () => {
    showSpy.mockResolvedValue({ data: { configured: false, fields: {} } });

    const wrapper = mountPanel();
    await flushPromises();

    const createButton = wrapper
      .findAll('button')
      .find(btn => btn.text().includes('Create Lead'));
    expect(createButton.attributes('disabled')).toBeDefined();

    await createButton.trigger('click');
    await flushPromises();
    vi.advanceTimersByTime(1000);
    await flushPromises();

    expect(syncSpy).not.toHaveBeenCalled();
    expect(saveSpy).not.toHaveBeenCalled();
  });

  it('positive control: a configured server confirmation re-enables autosave', async () => {
    // Proves the gating is what suppresses autosave (not a broken test): once the
    // server confirms configured:true, the brand-new-draft autosave fires.
    showSpy.mockResolvedValue({ data: { configured: true, fields: {} } });
    saveSpy.mockResolvedValue({ data: { sync_status: 'draft' } });

    mountPanel();
    await flushPromises();

    vi.advanceTimersByTime(10);
    await flushPromises();

    expect(saveSpy).toHaveBeenCalledTimes(1);
  });
});

// Local stubs that honour the real component contracts (unlike the always-open
// global stubs): the modal renders its body only when `show` is true and can be
// closed via the v-model update event, and the header surfaces its title.
const WootModal = {
  props: { show: { type: Boolean, default: false } },
  emits: ['update:show'],
  template:
    '<div v-if="show" class="woot-modal">' +
    '<button class="modal-close" @click="$emit(\'update:show\', false)">x</button>' +
    '<slot /></div>',
};
const WootModalHeader = {
  props: { headerTitle: { type: String, default: '' } },
  template: '<div class="woot-modal-header"><h2>{{ headerTitle }}</h2></div>',
};
const NextButton = {
  props: { label: { type: String, default: '' } },
  emits: ['click'],
  template:
    '<button class="erp-trigger" @click="$emit(\'click\')">{{ label }}</button>',
};

const mountModalPanel = (conversationId = 42) =>
  mount(ErpLeadPanel, {
    props: { conversationId },
    global: { stubs: { WootModal, WootModalHeader, NextButton } },
  });

const triggerLabel = wrapper => wrapper.find('.erp-trigger').text();

describe('ErpLeadPanel modal presentation', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // Existing draft (non-empty fields) so opening does not schedule autosave.
    showSpy.mockResolvedValue({
      data: {
        configured: true,
        fields: {
          lead_owner: 'owner@example.com',
          first_name: 'Bob',
          industry: 'Retail',
          status: 'Lead',
        },
      },
    });
    saveSpy.mockResolvedValue({ data: { sync_status: 'draft' } });
    syncSpy.mockResolvedValue({
      data: { sync_status: 'synced', erp_lead_id: 'LEAD-1' },
    });
  });

  it('shows only a compact "ERP Lead" trigger button, no form, before click', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();

    expect(triggerLabel(wrapper)).toBe('ERP Lead');
    // Modal (and therefore the entire form) is absent until the button is clicked.
    expect(wrapper.find('.woot-modal').exists()).toBe(false);
    expect(wrapper.find('input').exists()).toBe(false);
  });

  it('opens a modal titled "ERP Lead" containing the form when clicked', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();

    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    expect(wrapper.find('.woot-modal').exists()).toBe(true);
    expect(wrapper.find('.woot-modal-header h2').text()).toBe('ERP Lead');
    // Form fields are now present inside the modal.
    expect(wrapper.find('input').exists()).toBe(true);
    const leadOwner = wrapper
      .findAll('input')
      .find(i => i.element.value === 'owner@example.com');
    expect(leadOwner).toBeTruthy();
  });

  it('preserves an edited field across close/reopen in the same conversation', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();

    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    const firstName = wrapper
      .findAll('input')
      .find(i => i.element.value === 'Bob');
    await firstName.setValue('Bob Edited');

    // Close via the modal's own close event, then reopen from the trigger.
    await wrapper.find('.modal-close').trigger('click');
    expect(wrapper.find('.woot-modal').exists()).toBe(false);

    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    // Reopening must not reload the draft (no extra show call) or reset state.
    expect(showSpy).toHaveBeenCalledTimes(1);
    const reopened = wrapper
      .findAll('input')
      .find(i => i.element.value === 'Bob Edited');
    expect(reopened).toBeTruthy();
  });

  it('loads the new conversation exactly once when conversationId changes', async () => {
    const wrapper = mountModalPanel(42);
    await flushPromises();
    expect(showSpy).toHaveBeenCalledTimes(1);
    expect(showSpy).toHaveBeenLastCalledWith(42);

    await wrapper.setProps({ conversationId: 99 });
    await flushPromises();

    expect(showSpy).toHaveBeenCalledTimes(2);
    expect(showSpy).toHaveBeenLastCalledWith(99);
  });

  it('closes the modal when the conversation changes', async () => {
    const wrapper = mountModalPanel(42);
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();
    expect(wrapper.find('.woot-modal').exists()).toBe(true);

    await wrapper.setProps({ conversationId: 99 });
    await flushPromises();

    expect(wrapper.find('.woot-modal').exists()).toBe(false);
  });

  it('keeps the Create/Update Lead action wired inside the modal', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();

    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    const createButton = wrapper
      .findAll('button')
      .find(btn => btn.text().includes('Create Lead'));
    expect(createButton).toBeTruthy();

    await createButton.trigger('click');
    await flushPromises();

    // The existing draft-then-sync pipeline still fires against the same APIs.
    expect(saveSpy).toHaveBeenCalled();
    expect(syncSpy).toHaveBeenCalledWith(42, expect.any(Object));
  });
});
