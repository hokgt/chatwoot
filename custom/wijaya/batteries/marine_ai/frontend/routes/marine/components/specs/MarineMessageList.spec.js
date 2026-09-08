import { mount } from '@vue/test-utils';
import MarineMessageList from '../MarineMessageList.vue';

// i18n stub: keys pass through with {type}/{size} interpolation observable in the DOM.
vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) =>
      params ? `${key}:${Object.values(params).join('|')}` : key,
  }),
}));

// The message formatter is exercised elsewhere; here it just echoes content so the DOM is stable.
vi.mock('shared/composables/useMessageFormatter', () => ({
  useMessageFormatter: () => ({ formatMessage: content => content }),
}));

const mountList = messages =>
  mount(MarineMessageList, {
    props: { messages, isLoading: false },
    global: { stubs: { Avatar: true } },
  });

const catalogMessage = {
  sender: 'assistant',
  content: 'The Baby Doll catalog is available.',
  catalogPreview: {
    family_name: 'Baby Doll',
    filename: 'catalog.pdf',
    content_type: 'application/pdf',
    byte_size: 2048,
  },
};

describe('MarineMessageList catalog preview card', () => {
  it('renders a read-only catalog preview card with the allowlisted metadata', () => {
    const wrapper = mountList([catalogMessage]);
    const card = wrapper.find('[data-testid="catalog-preview-card"]');

    expect(card.exists()).toBe(true);
    expect(card.text()).toContain('Baby Doll');
    expect(card.text()).toContain('catalog.pdf');
    // Human-readable size + MIME via the FILE_META key interpolation.
    expect(card.text()).toContain('application/pdf');
    expect(card.text()).toContain('2.0 KB');
    expect(card.text()).toContain(
      'MARINE_AI.PLAYGROUND.CATALOG_PREVIEW.READ_ONLY_HINT'
    );
  });

  it('exposes NO download/link/button action on the card (non-delivering preview)', () => {
    const wrapper = mountList([catalogMessage]);
    const card = wrapper.find('[data-testid="catalog-preview-card"]');

    expect(card.findAll('a')).toHaveLength(0);
    expect(card.findAll('button')).toHaveLength(0);
    expect(card.html()).not.toContain('href');
    expect(card.html()).not.toContain('download');
  });

  it('renders no card for a plain assistant message', () => {
    const wrapper = mountList([{ sender: 'assistant', content: 'Just text.' }]);

    expect(wrapper.find('[data-testid="catalog-preview-card"]').exists()).toBe(
      false
    );
  });
});
