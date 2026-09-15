import { mount, flushPromises } from '@vue/test-utils';
import ErpLeadPanel from '@wijaya/erp_lead_sidebar/frontend/ErpLeadPanel.vue';

// Zero-draft safety mirror on the client: while ERP is unconfigured the backend
// never persists a draft on open, so opening/editing the panel must issue no
// autosave (PATCH) and no sync (POST) until the server confirms configured:true.
// These specs drive the real component (no weakening) and assert the API surface.

const { showSpy, saveSpy, syncSpy, setOwnerSpy, resetOwnerSpy, retryOwnerSpy } =
  vi.hoisted(() => ({
    showSpy: vi.fn(),
    saveSpy: vi.fn(),
    syncSpy: vi.fn(),
    setOwnerSpy: vi.fn(),
    resetOwnerSpy: vi.fn(),
    retryOwnerSpy: vi.fn(),
  }));

vi.mock('@wijaya/erp_lead_sidebar/frontend/api/wijayaErpLeadDrafts', () => ({
  default: {
    show: showSpy,
    save: saveSpy,
    sync: syncSpy,
    setOwner: setOwnerSpy,
    resetOwner: resetOwnerSpy,
    retryOwner: retryOwnerSpy,
  },
}));

// The global NextButton stub renders only its default slot; the real Button
// renders :label instead. Mirror that here now the panel passes :label with no
// redundant slot, so text-based button lookups keep working.
const LabelledNextButton = {
  props: { label: { type: String, default: '' } },
  template: '<button><slot>{{ label }}</slot></button>',
};

const mountPanel = () =>
  mount(ErpLeadPanel, {
    props: { conversationId: 42 },
    global: { stubs: { NextButton: LabelledNextButton } },
  });

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
  });

  // The Lead Owner is a searchable combobox: it defaults to the assigned agent but the
  // agent can override it with a value chosen ONLY from the fetched ERP user list. The
  // browser never submits free text, and the owner is set through its own #owner endpoint
  // (setOwner), never the field autosave.
  it('defaults the owner to the assignee and sets a manual override from the ERP user list', async () => {
    showSpy.mockResolvedValue({
      data: {
        configured: true,
        fields: { first_name: 'Bob' },
        lead_owner: '',
        lead_owner_override: false,
        owner_options: [
          { value: 'agent@example.com', label: 'Agent One' },
          { value: 'boss@example.com', label: 'Boss Two' },
        ],
        owner_options_available: true,
      },
    });
    setOwnerSpy.mockResolvedValue({
      data: {
        lead_owner: 'boss@example.com',
        lead_owner_override: true,
        message: 'set',
      },
    });

    const wrapper = mount(ErpLeadPanel, {
      props: {
        conversationId: 42,
        currentChat: {
          meta: {
            assignee: {
              id: 7,
              name: 'Budi The Agent',
              email: 'agent@example.com',
            },
          },
        },
      },
      global: {
        stubs: { WootModal, WootModalHeader, NextButton, LeadActivityForm },
      },
    });
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    const owner = wrapper.find('#erp-lead-owner');
    // Editable combobox (not readonly) defaulting to the assignee, shown by its ERP label.
    expect(owner.attributes('readonly')).toBeUndefined();
    expect(owner.attributes('role')).toBe('combobox');
    expect(owner.element.value).toBe('Agent One');

    // Open the menu and pick the second ERP user; only the exact User.name is submitted.
    await owner.trigger('focus');
    const option = wrapper.findAll('li').find(li => li.text() === 'Boss Two');
    await option.trigger('mousedown');
    await flushPromises();

    expect(setOwnerSpy).toHaveBeenCalledWith(42, 'boss@example.com');
    // Owner autosave path is never used for the owner.
    expect(saveSpy).not.toHaveBeenCalled();
    // Now in manual override mode, showing the picked user.
    expect(wrapper.find('#erp-lead-owner').element.value).toBe('Boss Two');
  });

  it('offers a reset action while overridden and surfaces a sanitized rejection', async () => {
    showSpy.mockResolvedValue({
      data: {
        configured: true,
        fields: { first_name: 'Bob' },
        lead_owner: 'boss@example.com',
        lead_owner_override: true,
        owner_options: [{ value: 'boss@example.com', label: 'Boss Two' }],
        owner_options_available: true,
      },
    });
    resetOwnerSpy.mockResolvedValue({
      data: {
        lead_owner: '',
        lead_owner_override: false,
        message: 'follows agent',
      },
    });

    const wrapper = mount(ErpLeadPanel, {
      props: {
        conversationId: 42,
        currentChat: { meta: { assignee: { email: 'agent@example.com' } } },
      },
      global: {
        stubs: { WootModal, WootModalHeader, NextButton, LeadActivityForm },
      },
    });
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    // Reset offered only while a manual override is active.
    const reset = wrapper
      .findAll('button')
      .find(b => b.text() === 'Use assigned agent');
    expect(reset).toBeTruthy();
    await reset.trigger('click');
    await flushPromises();
    expect(resetOwnerSpy).toHaveBeenCalledWith(42);
    // Back to automatic: the reset action is no longer offered.
    expect(
      wrapper.findAll('button').find(b => b.text() === 'Use assigned agent')
    ).toBeFalsy();
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

  it('keeps the action area inside the modal in a non-scrolling footer below a single scroll body', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();

    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    const modal = wrapper.find('.woot-modal');
    const createButton = modal
      .findAll('button')
      .find(btn => btn.text().includes('Create Lead'));
    // The primary action lives inside the modal.
    expect(createButton).toBeTruthy();

    // Exactly one scrollable content region in the Lead Details panel.
    const scrollers = wrapper
      .findAll('div')
      .filter(d => d.classes().includes('overflow-y-auto'));
    expect(scrollers.length).toBe(1);

    // The footer is a stable, non-scrolling sibling below the scroll body: it is
    // not sticky and is not itself the scroller, so it cannot cover the fields.
    const footer = wrapper
      .findAll('div')
      .find(
        d =>
          d.classes().includes('shrink-0') &&
          d.classes().includes('border-t') &&
          d.find('button').exists()
      );
    expect(footer).toBeTruthy();
    expect(footer.classes()).not.toContain('sticky');
    expect(footer.classes()).not.toContain('overflow-y-auto');
    expect(footer.find('button').exists()).toBe(true);
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
      .find(l => l.attributes('for') === 'erp-status');
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

  it('shows plain-language guidance describing the modal purpose', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    expect(wrapper.find('.woot-modal').text()).toContain(
      'Manage the ERP Lead linked to this conversation'
    );
  });

  it('exposes accessible tab semantics with active state and exact helper text', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    const tablist = wrapper.find('[role="tablist"]');
    expect(tablist.exists()).toBe(true);

    const detailsTab = wrapper.find('#erp-tab-details');
    const activityTab = wrapper.find('#erp-tab-activity');
    expect(detailsTab.attributes('role')).toBe('tab');
    expect(activityTab.attributes('role')).toBe('tab');
    // Active tab is obvious to assistive tech and associated with its panel.
    expect(detailsTab.attributes('aria-selected')).toBe('true');
    expect(activityTab.attributes('aria-selected')).toBe('false');
    expect(detailsTab.attributes('aria-controls')).toBe('erp-tabpanel-details');
    expect(wrapper.find('#erp-tabpanel-details').attributes('role')).toBe(
      'tabpanel'
    );
    // Contextual helper for Lead Details.
    expect(wrapper.text()).toContain(
      'View and update the ERP Lead linked to this conversation.'
    );

    await activityTab.trigger('click');
    expect(activityTab.attributes('aria-selected')).toBe('true');
    expect(detailsTab.attributes('aria-selected')).toBe('false');
    // Contextual helper for Lead Activity.
    expect(wrapper.text()).toContain(
      'Manually record a new activity for the linked Lead.'
    );
  });

  it('keeps both tabs in the normal keyboard Tab order regardless of selection', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    const detailsTab = wrapper.find('#erp-tab-details');
    const activityTab = wrapper.find('#erp-tab-activity');

    // No roving tabindex: neither native <button> is removed from Tab order
    // (a tabindex of -1 on the inactive tab would make it unreachable).
    expect(detailsTab.attributes('tabindex')).toBeUndefined();
    expect(activityTab.attributes('tabindex')).toBeUndefined();
    // Selection/association semantics stay correct.
    expect(detailsTab.attributes('aria-selected')).toBe('true');
    expect(activityTab.attributes('aria-selected')).toBe('false');
    expect(detailsTab.attributes('aria-controls')).toBe('erp-tabpanel-details');
    expect(activityTab.attributes('aria-controls')).toBe(
      'erp-tabpanel-activity'
    );

    // Switching the active tab still leaves both reachable.
    await activityTab.trigger('click');
    expect(detailsTab.attributes('tabindex')).toBeUndefined();
    expect(activityTab.attributes('tabindex')).toBeUndefined();
    expect(activityTab.attributes('aria-selected')).toBe('true');
    expect(detailsTab.attributes('aria-selected')).toBe('false');
  });

  it('omits the Status/Industry aria-describedby when no error hint is rendered', async () => {
    // Default draft has a valid Status and Industry, so neither hint span is
    // present — the describedby reference must not dangle.
    const wrapper = mountModalPanel();
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    expect(wrapper.find('#erp-status-help').exists()).toBe(false);
    expect(wrapper.find('#erp-status').attributes('aria-describedby')).toBe(
      undefined
    );
    expect(wrapper.find('#erp-industry-help').exists()).toBe(false);
    expect(wrapper.find('#erp-industry').attributes('aria-describedby')).toBe(
      undefined
    );
  });

  it('binds the Status/Industry aria-describedby only when the error hint is shown', async () => {
    // Missing Status + Industry render both error hints, so the reference must
    // point at the now-present target.
    showSpy.mockResolvedValueOnce({
      data: {
        configured: true,
        fields: { first_name: 'Bob', status: '', industry: '' },
      },
    });
    const wrapper = mountModalPanel();
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    expect(wrapper.find('#erp-status-help').exists()).toBe(true);
    expect(wrapper.find('#erp-status').attributes('aria-describedby')).toBe(
      'erp-status-help'
    );
    expect(wrapper.find('#erp-industry-help').exists()).toBe(true);
    expect(wrapper.find('#erp-industry').attributes('aria-describedby')).toBe(
      'erp-industry-help'
    );
  });

  it('renders the footer action explanation and a plain-language disabled reason', async () => {
    // Missing Industry keeps the required rule unmet, so the primary action is
    // disabled and a plain-language reason is shown (guard logic unchanged).
    showSpy.mockResolvedValueOnce({
      data: {
        configured: true,
        fields: { first_name: 'Bob', status: 'Lead', industry: '' },
      },
    });
    const wrapper = mountModalPanel();
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    expect(wrapper.text()).toContain(
      'Creates a new Lead in ERPNext from these details.'
    );
    expect(wrapper.text()).toContain(
      'Complete the required fields marked * before continuing.'
    );
  });

  it('labels the primary action Update Lead / Retry Update Lead for a linked draft', async () => {
    showSpy.mockResolvedValueOnce({
      data: {
        configured: true,
        erp_lead_id: 'LEAD-9',
        sync_status: 'synced',
        fields: { first_name: 'Bob', status: 'Lead', industry: 'Retail' },
      },
    });
    const wrapper = mountModalPanel();
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    const primary = () =>
      wrapper
        .findAll('button')
        .find(
          b => b.text().includes('Update Lead') || b.text().includes('Retry')
        );
    // Linked + not failed -> Update Lead.
    expect(primary().text()).toContain('Update Lead');

    // The draft save keeps the linked id; the sync then fails.
    saveSpy.mockResolvedValue({
      data: { sync_status: 'draft', erp_lead_id: 'LEAD-9' },
    });
    syncSpy.mockRejectedValueOnce({ response: { data: {} } });
    await primary().trigger('click');
    await flushPromises();
    expect(primary().text()).toContain('Retry Update Lead');
  });

  it('shows a clear loading label while a create is in flight', async () => {
    let resolveSync;
    saveSpy.mockResolvedValue({ data: { sync_status: 'draft' } });
    syncSpy.mockReturnValueOnce(
      new Promise(resolve => {
        resolveSync = resolve;
      })
    );

    const wrapper = mountModalPanel();
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    const create = wrapper
      .findAll('button')
      .find(b => b.text().includes('Create Lead'));
    await create.trigger('click');
    await flushPromises();

    // While syncing, the label reflects the in-flight create.
    expect(
      wrapper.findAll('button').find(b => b.text().includes('Creating…'))
    ).toBeTruthy();

    resolveSync({ data: { sync_status: 'synced', erp_lead_id: 'LEAD-1' } });
    await flushPromises();
  });

  it('presents a single synchronization status without duplicate success banners', async () => {
    const wrapper = mountModalPanel();
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();

    const create = wrapper
      .findAll('button')
      .find(b => b.text().includes('Create Lead'));
    // Sync succeeds and returns an ERP Lead id (no server message).
    await create.trigger('click');
    await flushPromises();

    // Exactly one status region, and the id appears exactly once (no separate
    // "ERP Lead created" chip plus a duplicate success banner).
    const statuses = wrapper.findAll('[role="status"]');
    expect(statuses.length).toBe(1);
    const occurrences = (
      wrapper
        .find('.woot-modal')
        .text()
        .match(/LEAD-1/g) || []
    ).length;
    expect(occurrences).toBe(1);
    expect(wrapper.find('.woot-modal').text()).not.toContain(
      'ERP Lead created'
    );
  });
});

// The assigned agent is the automatic Lead Owner default ONLY when it resolves to a
// selectable ERP User. An arbitrary/unresolved assignee email — or any email while the
// directory is unavailable — must never be shown as a valid selected owner; a confirmed
// stored owner is still shown even if it is not in the current options list.
describe('ErpLeadPanel Lead Owner default resolution', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  const mountWithAssignee = (assigneeEmail, showData) => {
    showSpy.mockResolvedValue({ data: showData });
    return mount(ErpLeadPanel, {
      props: {
        conversationId: 42,
        currentChat: { meta: { assignee: { email: assigneeEmail } } },
      },
      global: {
        stubs: { WootModal, WootModalHeader, NextButton, LeadActivityForm },
      },
    });
  };

  const openOwner = async wrapper => {
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();
    return wrapper.find('#erp-lead-owner');
  };

  it('shows the assigned agent as the owner default when it is a selectable ERP user', async () => {
    const wrapper = mountWithAssignee('agent@example.com', {
      configured: true,
      fields: { first_name: 'Bob' },
      lead_owner: '',
      lead_owner_override: false,
      owner_options: [{ value: 'agent@example.com', label: 'Agent One' }],
      owner_options_available: true,
    });

    const owner = await openOwner(wrapper);
    expect(owner.element.value).toBe('Agent One');
  });

  it('leaves the owner blank and warns when the assigned agent is not a selectable ERP user', async () => {
    const wrapper = mountWithAssignee('ghost@example.com', {
      configured: true,
      fields: { first_name: 'Bob' },
      lead_owner: '',
      lead_owner_override: false,
      owner_options: [{ value: 'agent@example.com', label: 'Agent One' }],
      owner_options_available: true,
    });

    const owner = await openOwner(wrapper);
    expect(owner.element.value).toBe('');
    expect(wrapper.text()).toContain('not a selectable ERP user');
  });

  it('does not show the assigned agent as a valid default when the directory is unavailable', async () => {
    const wrapper = mountWithAssignee('agent@example.com', {
      configured: true,
      fields: { first_name: 'Bob' },
      lead_owner: '',
      lead_owner_override: false,
      owner_options: [],
      owner_options_available: false,
    });

    const owner = await openOwner(wrapper);
    expect(owner.element.value).toBe('');
    expect(wrapper.text()).toContain('ERP user list is unavailable');
  });

  it('still shows a confirmed stored owner even when it is not in the current options list', async () => {
    const wrapper = mountWithAssignee('agent@example.com', {
      configured: true,
      fields: { first_name: 'Bob' },
      lead_owner: 'legacy-owner@example.com',
      lead_owner_override: false,
      owner_options: [{ value: 'agent@example.com', label: 'Agent One' }],
      owner_options_available: true,
    });

    const owner = await openOwner(wrapper);
    expect(owner.element.value).toBe('legacy-owner@example.com');
  });
});

// A confirmed owner that has not reached ERP (lead_owner_sync_pending) must be visible and,
// on a LINKED Lead, retryable without re-picking it. On an UNLINKED Lead there is nothing to
// retry yet, so it only explains the owner will sync after the Lead is created.
describe('ErpLeadPanel Lead Owner pending/retry', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  const mountWith = showData => {
    showSpy.mockResolvedValue({ data: showData });
    return mount(ErpLeadPanel, {
      props: { conversationId: 42 },
      global: {
        stubs: { WootModal, WootModalHeader, NextButton, LeadActivityForm },
      },
    });
  };

  const open = async wrapper => {
    await flushPromises();
    await wrapper.find('.erp-trigger').trigger('click');
    await flushPromises();
  };

  it('shows a Retry Lead Owner sync action for a pending owner on a linked Lead', async () => {
    const wrapper = mountWith({
      configured: true,
      erp_lead_id: 'LEAD-1',
      sync_status: 'failed',
      fields: { first_name: 'Bob', industry: 'Retail', status: 'Lead' },
      lead_owner: 'boss@example.com',
      lead_owner_override: true,
      lead_owner_sync_pending: true,
    });
    retryOwnerSpy.mockResolvedValue({
      data: {
        lead_owner: 'boss@example.com',
        lead_owner_override: true,
        lead_owner_sync_pending: true,
        message: 'Retrying the Lead Owner sync to ERP.',
      },
    });
    await open(wrapper);

    const retry = wrapper
      .findAll('button')
      .find(b => b.text() === 'Retry Lead Owner sync');
    expect(retry).toBeTruthy();

    await retry.trigger('click');
    await flushPromises();
    expect(retryOwnerSpy).toHaveBeenCalledWith(42);
  });

  it('explains a pending owner will sync after creation on an unlinked Lead (no retry button)', async () => {
    const wrapper = mountWith({
      configured: true,
      erp_lead_id: '',
      sync_status: 'draft',
      fields: { first_name: 'Bob', industry: 'Retail', status: 'Lead' },
      lead_owner: 'boss@example.com',
      lead_owner_override: true,
      lead_owner_sync_pending: true,
    });
    await open(wrapper);

    expect(
      wrapper.findAll('button').find(b => b.text() === 'Retry Lead Owner sync')
    ).toBeFalsy();
    expect(wrapper.text()).toContain('will sync to ERP after the Lead is');
  });

  it('shows no pending owner indicator once the owner is confirmed in ERP', async () => {
    const wrapper = mountWith({
      configured: true,
      erp_lead_id: 'LEAD-1',
      sync_status: 'synced',
      fields: { first_name: 'Bob', industry: 'Retail', status: 'Lead' },
      lead_owner: 'boss@example.com',
      lead_owner_override: true,
      lead_owner_sync_pending: false,
    });
    await open(wrapper);

    expect(
      wrapper.findAll('button').find(b => b.text() === 'Retry Lead Owner sync')
    ).toBeFalsy();
    expect(wrapper.text()).not.toContain('not yet confirmed in ERP');
  });
});
