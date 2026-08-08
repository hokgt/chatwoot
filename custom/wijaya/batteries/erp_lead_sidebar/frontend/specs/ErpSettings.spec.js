import { mount, flushPromises } from '@vue/test-utils';
import ErpSettings from '@wijaya/erp_lead_sidebar/frontend/routes/ErpSettings.vue';

// The ERPNext Settings page never receives the raw key/secret back — only
// presence/source metadata. These specs assert the credential-preserving
// contract: blank password inputs are omitted from the payload so the server
// keeps the stored value, and an edited value is sent through.

const { getSpy, updateSpy, testSpy } = vi.hoisted(() => ({
  getSpy: vi.fn(),
  updateSpy: vi.fn(),
  testSpy: vi.fn(),
}));

vi.mock('@wijaya/erp_lead_sidebar/frontend/api/wijayaErpSettings', () => ({
  default: { get: getSpy, update: updateSpy, test: testSpy },
}));

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, args) => (args ? `${key}:${JSON.stringify(args)}` : key),
  }),
}));

const { alertSpy } = vi.hoisted(() => ({ alertSpy: vi.fn() }));
vi.mock('dashboard/composables', () => ({ useAlert: alertSpy }));
vi.mock('dashboard/store/utils/api', () => ({
  parseAPIErrorResponse: err => err?.message || 'error',
}));

const InputStub = {
  name: 'Input',
  props: [
    'modelValue',
    'label',
    'placeholder',
    'type',
    'message',
    'messageType',
  ],
  emits: ['update:modelValue'],
  template:
    '<input :data-placeholder="placeholder" :value="modelValue" @input="$emit(\'update:modelValue\', $event.target.value)" />',
};

const ButtonStub = {
  name: 'Button',
  props: ['label'],
  emits: ['click'],
  template:
    '<button :data-label="label" @click="$emit(\'click\')">{{ label }}</button>',
};

const SettingsLayoutStub = {
  name: 'SettingsLayout',
  template: '<div><slot name="header" /><slot name="body" /></div>',
};

const mountPage = () =>
  mount(ErpSettings, {
    global: {
      mocks: {
        // The template renders labels/placeholders via the global `$t`; mirror the
        // useI18n mock so stubbed data-label/data-placeholder carry the i18n keys.
        $t: (key, args) => (args ? `${key}:${JSON.stringify(args)}` : key),
      },
      stubs: {
        SettingsLayout: SettingsLayoutStub,
        BaseSettingsHeader: true,
        Input: InputStub,
        Button: ButtonStub,
      },
    },
  });

const savedResponse = {
  host: 'https://erp.example.com',
  host_source: 'account',
  api_key_present: true,
  api_key_source: 'account',
  api_secret_present: true,
  api_secret_source: 'account',
  configured: true,
};

const clickButton = (wrapper, label) =>
  wrapper.find(`[data-label="${label}"]`).trigger('click');

describe('ErpSettings page', () => {
  beforeEach(() => vi.clearAllMocks());

  it('fetches settings on mount and hides the password inputs when a credential is present', async () => {
    getSpy.mockResolvedValue({ data: savedResponse });

    const wrapper = mountPage();
    await flushPromises();

    expect(getSpy).toHaveBeenCalledTimes(1);
    // Present credentials render a "Change" affordance, not a password input.
    expect(
      wrapper.find('[data-label="WIJAYA_ERP_SETTINGS.API_KEY.CHANGE"]').exists()
    ).toBe(true);
    expect(
      wrapper
        .find('[data-placeholder="WIJAYA_ERP_SETTINGS.API_KEY.PLACEHOLDER"]')
        .exists()
    ).toBe(false);
  });

  it('omits blank credential fields on save so the server preserves the stored values', async () => {
    getSpy.mockResolvedValue({ data: savedResponse });
    updateSpy.mockResolvedValue({ data: savedResponse });

    const wrapper = mountPage();
    await flushPromises();

    await clickButton(wrapper, 'WIJAYA_ERP_SETTINGS.SAVE.BUTTON');
    await flushPromises();

    expect(updateSpy).toHaveBeenCalledWith({
      erp_setting: { host: 'https://erp.example.com' },
    });
    expect(alertSpy).toHaveBeenCalled();
  });

  it('sends an edited key/secret through the payload', async () => {
    getSpy.mockResolvedValue({
      data: {
        ...savedResponse,
        api_key_present: false,
        api_secret_present: false,
      },
    });
    updateSpy.mockResolvedValue({ data: savedResponse });

    const wrapper = mountPage();
    await flushPromises();

    const keyInput = wrapper.find(
      '[data-placeholder="WIJAYA_ERP_SETTINGS.API_KEY.PLACEHOLDER"]'
    );
    const secretInput = wrapper.find(
      '[data-placeholder="WIJAYA_ERP_SETTINGS.API_SECRET.PLACEHOLDER"]'
    );
    await keyInput.setValue('new-key');
    await secretInput.setValue('new-secret');

    await clickButton(wrapper, 'WIJAYA_ERP_SETTINGS.SAVE.BUTTON');
    await flushPromises();

    expect(updateSpy).toHaveBeenCalledWith({
      erp_setting: {
        host: 'https://erp.example.com',
        api_key: 'new-key',
        api_secret: 'new-secret',
      },
    });
  });

  it('runs a connection test and surfaces the sanitized result', async () => {
    getSpy.mockResolvedValue({ data: savedResponse });
    testSpy.mockResolvedValue({
      data: { ok: true, message: null, error: null },
    });

    const wrapper = mountPage();
    await flushPromises();

    await clickButton(wrapper, 'WIJAYA_ERP_SETTINGS.TEST.BUTTON');
    await flushPromises();

    expect(testSpy).toHaveBeenCalledWith({
      erp_setting: { host: 'https://erp.example.com' },
    });
    expect(wrapper.text()).toContain('WIJAYA_ERP_SETTINGS.TEST.SUCCESS');
  });
});
