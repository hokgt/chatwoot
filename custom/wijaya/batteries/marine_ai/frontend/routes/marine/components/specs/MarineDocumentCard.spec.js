import { mount } from '@vue/test-utils';
import MarineDocumentCard from '../MarineDocumentCard.vue';

// i18n stub: keys pass through, with {code} interpolation observable in the DOM.
vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params?.code ? `${key}:${params.code}` : key),
  }),
}));

const CardLayoutStub = { template: '<div><slot /></div>' };
const ButtonStub = {
  emits: ['click'],
  template: `<button @click="$emit('click')"><slot /></button>`,
};
const DropdownMenuStub = {
  props: ['menuItems'],
  template: `<ul class="menu"><li v-for="item in menuItems" :key="item.value" :data-action="item.action">{{ item.label }}</li></ul>`,
};

const mountCard = props =>
  mount(MarineDocumentCard, {
    props: { id: 1, ...props },
    global: {
      stubs: {
        CardLayout: CardLayoutStub,
        Button: ButtonStub,
        DropdownMenu: DropdownMenuStub,
        Icon: true,
      },
      directives: { 'on-clickaway': {} },
    },
  });

const catalogProps = {
  name: 'Pump Catalog',
  sourceKind: 'product_catalog',
  primaryCatalog: true,
  productFamilyCode: 'PUMP-100',
  sourceFile: {
    filename: 'catalog.pdf',
    content_type: 'application/pdf',
    byte_size: 1024 * 1024,
  },
  createdAt: '',
};

const openMenu = async wrapper => {
  await wrapper.find('button').trigger('click');
};

describe('MarineDocumentCard product catalog', () => {
  it('renders the catalog badge, family code, primary badge, and file metadata', () => {
    const wrapper = mountCard(catalogProps);
    const text = wrapper.text();

    expect(text).toContain('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.BADGE');
    expect(text).toContain('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.PRIMARY_BADGE');
    expect(text).toContain(
      'MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.FAMILY_CODE:PUMP-100'
    );
    expect(text).toContain('catalog.pdf');
    expect(text).toContain('PDF');
    expect(text).toContain('1.00 MB');
  });

  it('shows no website sync, SOP extraction, or indexing status', () => {
    const wrapper = mountCard(catalogProps);
    const text = wrapper.text();

    expect(text).not.toContain('SYNC_STATUS');
    expect(text).not.toContain('EXTRACTION_STATUS');
    expect(text).not.toContain('INDEXING_STATUS');
  });

  it('hides the primary badge when the catalog is not primary', () => {
    const wrapper = mountCard({ ...catalogProps, primaryCatalog: false });
    expect(wrapper.text()).not.toContain(
      'MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.PRIMARY_BADGE'
    );
  });

  it('exposes a delete-only action menu (no sync or reprocess)', async () => {
    const wrapper = mountCard(catalogProps);
    await openMenu(wrapper);

    const actions = wrapper
      .findAll('.menu li')
      .map(li => li.attributes('data-action'));
    expect(actions).toEqual(['delete']);
  });
});
