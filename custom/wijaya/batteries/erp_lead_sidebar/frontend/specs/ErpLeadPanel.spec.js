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

// The Lead Activity tab hosts a fully separate component with its own API. Stub
// it so the Lead Details specs never reach that network surface, and so switching
// tabs can be asserted without mounting the real form.
const LeadActivityForm = {
  name: 'LeadActivityForm',
  props: ['conversationId', 'currentChat', 'erpLeadId', 'configured'],
  template: '<div class="lead-activity-form-stub" />',
};

const mountModalPanel = (conversationId = 42) =>
  mount(ErpLeadPanel, {
    props: { conversationId },
    global: {
      stubs: { WootModal, WootModalHeader, NextButton, LeadActivityForm },
    },
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

  it('requests the wider supported WootModal size', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();

    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    // `size="medium"` maps to Modal.vue's `.medium` class (max-w-[80%]
    // w-[56.25rem] ≈ 900px), the supported step up from the 600px default.
    expect(wrapper.find('.woot-modal').attributes('size')).toBe('medium');
  });

  it('renders all five grouped section headings after opening', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();

    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    const headings = wrapper.findAll('h3').map(h => h.text());
    expect(headings).toEqual([
      'Informasi Lead',
      'Kontak',
      'Sumber dan Klasifikasi',
      'Market Customer',
      'Jenis Pakaian',
    ]);
  });

  it('uses a responsive one/two-column field layout', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();

    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    // Field grids collapse to a single column on small screens and expand to
    // two columns from the `sm` breakpoint up.
    const fieldGrid = wrapper
      .findAll('div')
      .find(
        d =>
          d.classes().includes('grid-cols-1') &&
          d.classes().includes('sm:grid-cols-2')
      );
    expect(fieldGrid).toBeTruthy();
  });

  it('lays out checkbox groups in a multi-column grid', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();

    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    // Market Customer + Jenis Pakaian render as multi-column grids rather than
    // one checkbox per row on desktop while remaining single-column on mobile.
    const checkboxGrids = wrapper
      .findAll('div')
      .filter(
        d =>
          d.classes().includes('grid-cols-1') &&
          d.classes().includes('sm:grid-cols-2') &&
          d.classes().includes('lg:grid-cols-3')
      );
    expect(checkboxGrids.length).toBe(2);
    // Both groups keep every checkbox: 10 Market Customer + 24 Jenis Pakaian.
    const checkboxes = wrapper.findAll('input[type="checkbox"]');
    expect(checkboxes.length).toBe(34);
  });

  it('keeps the action area with Create/Update wiring inside the modal', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();

    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    const modal = wrapper.find('.woot-modal');
    const createButton = modal
      .findAll('button')
      .find(btn => btn.text().includes('Create Lead'));
    // The primary action lives inside the modal, in a sticky bottom action bar.
    expect(createButton).toBeTruthy();
    const actionBar = wrapper
      .findAll('div')
      .find(
        d => d.classes().includes('sticky') && d.classes().includes('bottom-0')
      );
    expect(actionBar).toBeTruthy();
    expect(actionBar.find('button').exists()).toBe(true);
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

  it('defaults to the Lead Details tab and does not mount the Activity form', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();

    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    // Both tab buttons are present; details content (headings) is shown.
    const tabLabels = wrapper
      .findAll('button')
      .map(b => b.text())
      .filter(t => t === 'Lead Details' || t === 'Lead Activity');
    expect(tabLabels).toEqual(['Lead Details', 'Lead Activity']);
    expect(wrapper.findAll('h3').length).toBe(5);
    expect(wrapper.find('.lead-activity-form-stub').exists()).toBe(false);
  });

  it('mounts the Activity form and hides Lead Details when the Activity tab is opened', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();

    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    const activityTab = wrapper
      .findAll('button')
      .find(b => b.text() === 'Lead Activity');
    await activityTab.trigger('click');

    expect(wrapper.find('.lead-activity-form-stub').exists()).toBe(true);
    // Lead Details sections are no longer rendered while on the Activity tab.
    expect(wrapper.findAll('h3').length).toBe(0);
  });

  it('resets to the Lead Details tab when the conversation changes', async () => {
    const wrapper = mountModalPanel(42);
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    const activityTab = wrapper
      .findAll('button')
      .find(b => b.text() === 'Lead Activity');
    await activityTab.trigger('click');
    expect(wrapper.find('.lead-activity-form-stub').exists()).toBe(true);

    await wrapper.setProps({ conversationId: 99 });
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    // Back on details after the conversation switch.
    expect(wrapper.find('.lead-activity-form-stub').exists()).toBe(false);
    expect(wrapper.findAll('h3').length).toBe(5);
  });

  it('renders the exact ordered Status options', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();

    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    const statusLabel = wrapper
      .findAll('label')
      .find(l => l.find('span').exists() && l.find('span').text() === 'Status');
    const options = statusLabel.findAll('option').map(o => o.element.value);
    expect(options).toEqual([
      'Lead',
      'Qualified',
      'Catalogue Request',
      'Sample Request',
      'Converted',
      'Regular Customer',
      'Lost Quotation',
    ]);
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
