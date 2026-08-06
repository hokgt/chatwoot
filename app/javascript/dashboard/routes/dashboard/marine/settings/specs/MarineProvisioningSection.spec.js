import { mount, flushPromises } from '@vue/test-utils';
import { ref } from 'vue';
// The provisioning section component lives in the Wijaya marine_ai battery, but its
// consumer (marine settings Index.vue) lives here, so the regression test lives with
// the consumer where vitest's `app/**` include can discover it.
import MarineProvisioningSection from '../../../../../../../../custom/wijaya/batteries/marine_ai/frontend/MarineProvisioningSection.vue';

const { getStatus, create } = vi.hoisted(() => ({
  getStatus: vi.fn(),
  create: vi.fn(),
}));

vi.mock(
  '../../../../../../../../custom/wijaya/batteries/marine_ai/frontend/provisioning',
  () => ({
    default: {
      getStatus,
      create,
      downgrade: vi.fn(),
      revokeAll: vi.fn(),
      privileges: vi.fn(),
    },
  })
);

// Stub i18n so we do not need to install the vue-i18n plugin; keys pass through.
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const { alertSpy } = vi.hoisted(() => ({ alertSpy: vi.fn() }));
vi.mock('dashboard/composables', () => ({ useAlert: alertSpy }));

// Administrator so the section renders (gating is tested separately).
vi.mock('dashboard/composables/useAdmin', () => ({
  useAdmin: () => ({ isAdmin: ref(true) }),
}));

const { openSpy } = vi.hoisted(() => ({ openSpy: vi.fn() }));

// Stub the one-time credentials dialog. It exposes `open()` (asserted below) and
// re-emits acknowledge so we can exercise the password-clear path.
const CredentialsDialogStub = {
  name: 'MarineProvisioningCredentialsDialog',
  props: ['credentials', 'password'],
  emits: ['acknowledge'],
  methods: {
    open() {
      openSpy();
    },
  },
  template:
    '<div class="creds-dialog"><button class="ack" @click="$emit(\'acknowledge\')" /></div>',
};

const mountSection = () =>
  mount(MarineProvisioningSection, {
    global: {
      stubs: {
        Button: { props: ['label'], template: '<button>{{ label }}</button>' },
        Dialog: true,
        MarineSettingsHeader: true,
        MarineProvisioningCredentialsDialog: CredentialsDialogStub,
      },
    },
  });

const CREDENTIALS = {
  host: 'db',
  port: 5432,
  database_name: 'marine_erp',
  login_username: 'marine_app',
  ssl_mode: 'prefer',
};

describe('MarineProvisioningSection one-time credentials popup', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    getStatus.mockResolvedValue({
      data: { status: 'not_provisioned', provisioning_configured: true },
    });
    create.mockResolvedValue({
      data: {
        credentials: CREDENTIALS,
        status: { status: 'active', privilege_level: 'admin' },
      },
    });
  });

  const submitCreate = async wrapper => {
    wrapper.vm.form = {
      databaseName: 'marine_erp',
      loginUsername: 'marine_app',
      password: 'a-strong-password-123',
    };
    await wrapper.find('form').trigger('submit');
    await flushPromises();
  };

  it('opens the one-time dialog after a successful create (no mount race)', async () => {
    const wrapper = mountSection();
    await flushPromises();

    await submitCreate(wrapper);

    // The child dialog only mounts after pendingCredentials flips, so open() being
    // called proves the awaited nextTick let the ref resolve before we opened it.
    expect(openSpy).toHaveBeenCalledTimes(1);
    expect(wrapper.find('.creds-dialog').exists()).toBe(true);
  });

  it('clears the pending secret when the popup is acknowledged', async () => {
    const wrapper = mountSection();
    await flushPromises();
    await submitCreate(wrapper);

    await wrapper.find('.ack').trigger('click');
    await flushPromises();

    // Acknowledging drops pendingCredentials, so the dialog (and the password it
    // rendered) unmounts and is gone from the DOM.
    expect(wrapper.find('.creds-dialog').exists()).toBe(false);
    expect(alertSpy).toHaveBeenCalled();
  });
});

describe('MarineProvisioningSection status summary', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // A provisioned installation persists host/port in its status, so the summary
    // must surface them alongside the database name and login username.
    getStatus.mockResolvedValue({
      data: {
        status: 'active',
        provisioning_configured: true,
        database_name: 'marine_erp',
        login_username: 'marine_app',
        host: 'db.internal',
        port: 5432,
        privilege_level: 'admin',
      },
    });
  });

  it('renders the persisted host and port rows', async () => {
    const wrapper = mountSection();
    await flushPromises();

    const summary = wrapper.find('dl').text();
    expect(summary).toContain('MARINE_AI.PROVISIONING.STATUS.HOST');
    expect(summary).toContain('db.internal');
    expect(summary).toContain('MARINE_AI.PROVISIONING.STATUS.PORT');
    expect(summary).toContain('5432');
  });
});
