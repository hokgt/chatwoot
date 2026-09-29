import { mount } from '@vue/test-utils';
import LlmProviderCard from '../LlmProviderCard.vue';

// One reusable provider card: masked-key change/cancel, provider-default autofill,
// and the Test emit. These are the interactions each of the two AI Provider cards
// relies on, exercised here in isolation from the page.
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const InputStub = {
  props: ['modelValue', 'label', 'placeholder', 'type'],
  emits: ['update:modelValue'],
  template:
    '<input :type="type" :data-label="label" :placeholder="placeholder" :value="modelValue" ' +
    '@input="$emit(\'update:modelValue\', $event.target.value)" />',
};

const ButtonStub = {
  props: ['label'],
  emits: ['click'],
  template: '<button @click="$emit(\'click\')">{{ label }}</button>',
};

const ComboBoxStub = {
  props: ['modelValue', 'options', 'placeholder'],
  emits: ['update:model-value'],
  template:
    '<select :value="modelValue" @change="$emit(\'update:model-value\', $event.target.value)">' +
    '<option v-for="o in options" :key="o.value" :value="o.value">{{ o.label }}</option></select>',
};

const PROVIDERS = [
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
];

const mountCard = (props = {}) =>
  mount(LlmProviderCard, {
    props: {
      title: 'Decision Maker',
      subtitle: 'sub',
      config: {
        provider: 'gemini',
        model: 'gemini-2.0-flash',
        endpoint: 'https://gg',
        api_key: '',
      },
      providers: PROVIDERS,
      apiKeyMasked: 'AIza...abcd',
      apiKeyPresent: true,
      ...props,
    },
    global: {
      stubs: { Input: InputStub, Button: ButtonStub, ComboBox: ComboBoxStub },
    },
  });

describe('LlmProviderCard', () => {
  it('shows the masked key and reveals the input on Change', async () => {
    const wrapper = mountCard();

    expect(wrapper.text()).toContain('AIza...abcd');
    expect(wrapper.find('input[type="password"]').exists()).toBe(false);

    await wrapper
      .findAll('button')
      .find(b => b.text() === 'MARINE_AI.LLM_SETTINGS.API_KEY.CHANGE')
      .trigger('click');

    expect(wrapper.find('input[type="password"]').exists()).toBe(true);
    expect(wrapper.emitted('update:apiKey')[0]).toEqual(['']);
  });

  it('starts in edit mode when no key is present', () => {
    const wrapper = mountCard({ apiKeyPresent: false, apiKeyMasked: null });
    expect(wrapper.find('input[type="password"]').exists()).toBe(true);
  });

  it('autofills model and endpoint defaults when the provider changes', async () => {
    const wrapper = mountCard();

    await wrapper.find('select').setValue('openrouter');

    expect(wrapper.emitted('update:provider')[0]).toEqual(['openrouter']);
    expect(wrapper.emitted('update:model')[0]).toEqual(['nemo']);
    expect(wrapper.emitted('update:endpoint')[0]).toEqual([
      'https://openrouter.ai/api',
    ]);
  });

  it('does not clobber a customized model when the provider changes', async () => {
    const wrapper = mountCard({
      config: {
        provider: 'gemini',
        model: 'my-custom-model',
        endpoint: 'https://custom',
        api_key: '',
      },
    });

    await wrapper.find('select').setValue('openrouter');

    expect(wrapper.emitted('update:provider')[0]).toEqual(['openrouter']);
    expect(wrapper.emitted('update:model')).toBeUndefined();
    expect(wrapper.emitted('update:endpoint')).toBeUndefined();
  });

  it('shows the inherited-key hint only while the masked key is inherited', async () => {
    const inherited = mountCard({ apiKeyInherited: true });
    expect(inherited.text()).toContain(
      'MARINE_AI.LLM_SETTINGS.API_KEY.INHERITED'
    );

    // Once the admin starts editing the key, the inherited hint disappears.
    await inherited
      .findAll('button')
      .find(b => b.text() === 'MARINE_AI.LLM_SETTINGS.API_KEY.CHANGE')
      .trigger('click');
    expect(inherited.text()).not.toContain(
      'MARINE_AI.LLM_SETTINGS.API_KEY.INHERITED'
    );

    // A card with its own key never shows the hint.
    const owned = mountCard({ apiKeyInherited: false });
    expect(owned.text()).not.toContain(
      'MARINE_AI.LLM_SETTINGS.API_KEY.INHERITED'
    );
  });

  it('emits test when the Test button is clicked', async () => {
    const wrapper = mountCard();

    await wrapper
      .findAll('button')
      .find(b => b.text() === 'MARINE_AI.LLM_SETTINGS.TEST.BUTTON')
      .trigger('click');

    expect(wrapper.emitted('test')).toHaveLength(1);
  });
});
