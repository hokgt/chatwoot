import { mount, flushPromises } from '@vue/test-utils';
import Index from '../Index.vue';

// The dual-model AI Provider page renders two fully independent provider cards
// (Decision Maker + Response Generator), runs a per-card Test, and saves both
// configs atomically. These specs stub the leaf card so we can assert the exact
// API payloads the page builds without exercising the shared form inputs.
const { get, update, test } = vi.hoisted(() => ({
  get: vi.fn(),
  update: vi.fn(),
  test: vi.fn(),
}));

vi.mock('@wijaya/marine_ai/frontend/api/llmSettings', () => ({
  default: { get, update, test },
}));

vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const { alertSpy } = vi.hoisted(() => ({ alertSpy: vi.fn() }));
vi.mock('dashboard/composables', () => ({ useAlert: alertSpy }));
vi.mock('dashboard/store/utils/api', () => ({
  parseAPIErrorResponse: () => 'error',
}));

const CardStub = {
  name: 'LlmProviderCard',
  props: {
    title: {},
    subtitle: {},
    config: {},
    providers: {},
    apiKeyMasked: {},
    apiKeyPresent: {},
    modelPlaceholder: {},
    // Boolean-typed so a valueless `show-api-mode` shorthand coerces to true,
    // matching the real component's prop declaration.
    showApiMode: { type: Boolean, default: false },
    isTesting: {},
    isBusy: {},
    testResult: {},
  },
  emits: [
    'update:provider',
    'update:model',
    'update:endpoint',
    'update:apiKey',
    'update:apiMode',
    'test',
  ],
  template:
    '<div class="card"><span class="title">{{ title }}</span>' +
    '<button class="test" @click="$emit(\'test\')" /></div>',
};

const RESPONSE = {
  available_providers: [
    {
      value: 'gemini',
      label: 'Google Gemini',
      default_model: 'gemini-2.0-flash',
      default_endpoint: 'https://gg',
    },
    {
      value: 'openrouter',
      label: 'OpenRouter',
      default_model: 'nemo',
      default_endpoint: 'https://openrouter.ai/api',
    },
  ],
  decision_maker_config: {
    provider: 'gemini',
    model: 'gemini-2.5-flash',
    api_endpoint: 'https://gg',
    api_mode: 'chat_completions',
    api_key_masked: 'AIza...abcd',
    api_key_present: true,
  },
  response_generator_config: {
    provider: 'openrouter',
    model: 'nemotron',
    api_endpoint: 'https://openrouter.ai/api',
    api_key_masked: 'sk-or...wxyz',
    api_key_present: true,
  },
};

const mountPage = () =>
  mount(Index, {
    global: {
      stubs: {
        MarinePageShell: { template: '<div><slot /></div>' },
        LlmProviderCard: CardStub,
        Button: {
          props: ['label'],
          template: '<button class="save">{{ label }}</button>',
        },
      },
    },
  });

describe('Marine AI dual-model provider page', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    get.mockResolvedValue({ data: RESPONSE });
    update.mockResolvedValue({ data: RESPONSE });
    test.mockResolvedValue({ data: { ok: true } });
  });

  const cards = wrapper => wrapper.findAllComponents(CardStub);

  it('renders two independent cards seeded from the backend', async () => {
    const wrapper = mountPage();
    await flushPromises();

    const [decision, response] = cards(wrapper);
    expect(decision.props('title')).toBe(
      'MARINE_AI.LLM_SETTINGS.DECISION_MAKER.TITLE'
    );
    expect(decision.props('apiKeyMasked')).toBe('AIza...abcd');
    expect(decision.props('config').provider).toBe('gemini');

    expect(response.props('title')).toBe(
      'MARINE_AI.LLM_SETTINGS.RESPONSE_GENERATOR.TITLE'
    );
    expect(response.props('apiKeyMasked')).toBe('sk-or...wxyz');
    expect(response.props('config').provider).toBe('openrouter');
  });

  it('saves both nested configs atomically, mapping endpoint and omitting blank keys', async () => {
    const wrapper = mountPage();
    await flushPromises();

    await wrapper.find('button.save').trigger('click');
    await flushPromises();

    expect(update).toHaveBeenCalledTimes(1);
    expect(update).toHaveBeenCalledWith({
      decision_maker_config: {
        provider: 'gemini',
        model: 'gemini-2.5-flash',
        api_endpoint: 'https://gg',
        api_mode: 'chat_completions',
      },
      response_generator_config: {
        provider: 'openrouter',
        model: 'nemotron',
        api_endpoint: 'https://openrouter.ai/api',
      },
    });
  });

  it('shows the API Mode selector only on the decision card', async () => {
    const wrapper = mountPage();
    await flushPromises();

    const [decision, response] = cards(wrapper);
    expect(decision.props('showApiMode')).toBe(true);
    expect(response.props('showApiMode')).toBeFalsy();
  });

  it('runs the Test for each card against its own target', async () => {
    const wrapper = mountPage();
    await flushPromises();

    const [decision, response] = cards(wrapper);

    await decision.find('button.test').trigger('click');
    await flushPromises();
    expect(test).toHaveBeenLastCalledWith({
      target: 'decision_maker',
      config: {
        provider: 'gemini',
        model: 'gemini-2.5-flash',
        api_endpoint: 'https://gg',
        api_mode: 'chat_completions',
      },
    });

    await response.find('button.test').trigger('click');
    await flushPromises();
    expect(test).toHaveBeenLastCalledWith({
      target: 'response_generator',
      config: {
        provider: 'openrouter',
        model: 'nemotron',
        api_endpoint: 'https://openrouter.ai/api',
      },
    });
    // The response generator test never carries an api_mode.
    expect(test.mock.calls.at(-1)[0].config.api_mode).toBeUndefined();
  });

  it('reflects edits to one card in its save payload without affecting the other', async () => {
    const wrapper = mountPage();
    await flushPromises();

    const [decision] = cards(wrapper);
    decision.vm.$emit('update:provider', 'openrouter');
    decision.vm.$emit('update:apiKey', 'new-decision-key');
    await flushPromises();

    await wrapper.find('button.save').trigger('click');
    await flushPromises();

    const payload = update.mock.calls[0][0];
    expect(payload.decision_maker_config).toEqual({
      provider: 'openrouter',
      model: 'gemini-2.5-flash',
      api_endpoint: 'https://gg',
      api_mode: 'chat_completions',
      api_key: 'new-decision-key',
    });
    // The response generator card is untouched and carries no api_key.
    expect(payload.response_generator_config.api_key).toBeUndefined();
    expect(payload.response_generator_config.provider).toBe('openrouter');
  });
});
