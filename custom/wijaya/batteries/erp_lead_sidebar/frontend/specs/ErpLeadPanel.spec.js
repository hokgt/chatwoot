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

vi.mock('dashboard/composables/useUISettings', () => ({
  useUISettings: () => ({
    isContactSidebarItemOpen: () => true,
    toggleSidebarUIState: vi.fn(),
  }),
}));

// The accordion chrome is native chatwoot UI; render its slot so the panel body
// (inputs + Create Lead button) is present without pulling the real component.
vi.mock('dashboard/components/Accordion/AccordionItem.vue', () => ({
  default: { name: 'AccordionItem', template: '<div><slot /></div>' },
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
