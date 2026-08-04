import { mount, flushPromises } from '@vue/test-utils';
import MarineProductFamilySelect from '@wijaya/marine_ai/frontend/MarineProductFamilySelect.vue';

// i18n stub: keys pass through, with {code} interpolation observable in the DOM.
vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params?.code ? `${key}:${params.code}` : key),
  }),
}));
// Run the debounced search synchronously so we can assert without fake timers.
vi.mock('@chatwoot/utils', () => ({ debounce: fn => fn }));

const { familiesSpy } = vi.hoisted(() => ({ familiesSpy: vi.fn() }));
vi.mock('@wijaya/marine_ai/frontend/api/document', () => ({
  default: { productFamilies: familiesSpy },
}));

const families = [
  { code: 'ALPHA-1', name: 'Alpha Pumps' },
  { code: 'BETA-2', name: 'Beta Valves' },
];

describe('MarineProductFamilySelect', () => {
  beforeEach(() => vi.clearAllMocks());

  it('loads the bounded family list on mount', async () => {
    familiesSpy.mockResolvedValue({ data: { payload: families } });
    const wrapper = mount(MarineProductFamilySelect);
    await flushPromises();

    expect(familiesSpy).toHaveBeenCalledWith({ query: '' });
    expect(wrapper.findAll('li')).toHaveLength(2);
    expect(wrapper.text()).toContain('Alpha Pumps');
    expect(wrapper.text()).toContain('BETA-2');
  });

  it('emits the selected code and full family on click', async () => {
    familiesSpy.mockResolvedValue({ data: { payload: families } });
    const wrapper = mount(MarineProductFamilySelect);
    await flushPromises();

    await wrapper.findAll('li button')[0].trigger('click');

    expect(wrapper.emitted('update:modelValue')[0]).toEqual(['ALPHA-1']);
    expect(wrapper.emitted('select')[0]).toEqual([families[0]]);
  });

  it('searches with the typed query', async () => {
    familiesSpy.mockResolvedValue({ data: { payload: [] } });
    const wrapper = mount(MarineProductFamilySelect);
    await flushPromises();

    familiesSpy.mockResolvedValue({
      data: { payload: [{ code: 'PUMP-9', name: 'Pumps' }] },
    });
    await wrapper.find('input[type="search"]').setValue('pump');
    await flushPromises();

    expect(familiesSpy).toHaveBeenLastCalledWith({ query: 'pump' });
    expect(wrapper.text()).toContain('Pumps');
  });

  it('shows the empty state when no families match', async () => {
    familiesSpy.mockResolvedValue({ data: { payload: [] } });
    const wrapper = mount(MarineProductFamilySelect);
    await flushPromises();

    expect(wrapper.text()).toContain(
      'MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.FAMILY.EMPTY'
    );
    expect(wrapper.findAll('li')).toHaveLength(0);
  });

  it('surfaces an error state and retries the lookup', async () => {
    familiesSpy.mockRejectedValueOnce(new Error('catalog down'));
    const wrapper = mount(MarineProductFamilySelect);
    await flushPromises();

    expect(wrapper.text()).toContain(
      'MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.FAMILY.ERROR'
    );

    familiesSpy.mockResolvedValueOnce({
      data: { payload: [{ code: 'ALPHA-1', name: 'Alpha Pumps' }] },
    });
    await wrapper.find('button').trigger('click');
    await flushPromises();

    expect(wrapper.text()).toContain('Alpha Pumps');
    expect(wrapper.text()).not.toContain(
      'MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.FAMILY.ERROR'
    );
  });

  it('shows the selected family confirmation via modelValue', async () => {
    familiesSpy.mockResolvedValue({ data: { payload: families } });
    const wrapper = mount(MarineProductFamilySelect, {
      props: { modelValue: 'ALPHA-1' },
    });
    await flushPromises();

    expect(wrapper.text()).toContain(
      'MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.FAMILY.SELECTED:ALPHA-1'
    );
  });
});
