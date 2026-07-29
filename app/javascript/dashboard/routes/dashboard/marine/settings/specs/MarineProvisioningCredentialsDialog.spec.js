import { mount } from '@vue/test-utils';
// The one-time credentials dialog lives in the Wijaya marine_ai battery, but its
// spec lives here so vitest's `app/**` include can discover it (mirroring the
// section spec alongside it).
import MarineProvisioningCredentialsDialog from '../../../../../../../../custom/wijaya/batteries/marine_ai/frontend/MarineProvisioningCredentialsDialog.vue';

// Stub i18n so we do not need to install the vue-i18n plugin; keys pass through.
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const CREDENTIALS = {
  host: 'db.internal',
  port: 5432,
  database_name: 'marine_erp',
  login_username: 'marine_app',
  ssl_mode: 'prefer',
};

const mountDialog = () =>
  mount(MarineProvisioningCredentialsDialog, {
    props: { credentials: CREDENTIALS, password: 'a-strong-password-123' },
    global: {
      stubs: {
        Button: { props: ['label'], template: '<button>{{ label }}</button>' },
      },
    },
  });

describe('MarineProvisioningCredentialsDialog', () => {
  it('renders the host and port rows once opened', async () => {
    const wrapper = mountDialog();
    // The dialog stays hidden until open() is invoked by the parent.
    wrapper.vm.open();
    await wrapper.vm.$nextTick();

    const body = wrapper.find('[role="dialog"]').text();
    expect(body).toContain('MARINE_AI.PROVISIONING.CREDENTIALS_DIALOG.HOST');
    expect(body).toContain('db.internal');
    expect(body).toContain('MARINE_AI.PROVISIONING.CREDENTIALS_DIALOG.PORT');
    expect(body).toContain('5432');
  });
});
