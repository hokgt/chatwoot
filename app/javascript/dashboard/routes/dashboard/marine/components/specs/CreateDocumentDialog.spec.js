import { mount, flushPromises } from '@vue/test-utils';
import CreateDocumentDialog from '../CreateDocumentDialog.vue';

// i18n stub: keys pass through so we can assert on them in the rendered DOM.
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const { alertSpy, createSpy, productFamiliesSpy, createCatalogSpy } =
  vi.hoisted(() => ({
    alertSpy: vi.fn(),
    createSpy: vi.fn().mockResolvedValue({}),
    productFamiliesSpy: vi.fn().mockResolvedValue({ data: { payload: [] } }),
    createCatalogSpy: vi.fn().mockResolvedValue({}),
  }));
vi.mock('dashboard/composables', () => ({ useAlert: alertSpy }));

vi.mock('dashboard/store/utils/api', () => ({
  parseAPIErrorResponse: () => 'error',
}));

vi.mock('dashboard/api/marine/document', () => ({
  default: {
    create: createSpy,
    productFamilies: productFamiliesSpy,
    createProductCatalog: createCatalogSpy,
  },
}));

// Render slot content so the file-picker button's staged-file label is observable, and
// so the form (inside Dialog's default slot) actually mounts. open/close are exposed so
// the component's ref-driven dialog control (incl. the conflict dialog) works, and a
// confirm button lets us drive the primary-conflict confirmation flow.
const DialogStub = {
  props: ['type', 'title', 'description'],
  emits: ['confirm', 'close'],
  data() {
    return { isOpen: this.type !== 'alert' };
  },
  methods: {
    open() {
      this.isOpen = true;
    },
    close() {
      this.isOpen = false;
    },
    confirm() {
      this.$emit('confirm');
    },
    cancel() {
      this.isOpen = false;
      this.$emit('close');
    },
  },
  template: `
    <div v-if="isOpen" class="dialog-stub">
      <span class="dialog-title">{{ title }}</span>
      <p class="dialog-description">{{ description }}</p>
      <slot /><slot name="footer" />
      <button v-if="type === 'alert'" type="button" class="dialog-confirm" @click="confirm" />
      <button v-if="type === 'alert'" type="button" class="dialog-cancel" @click="cancel" />
    </div>
  `,
};
const ButtonStub = {
  props: ['label', 'disabled'],
  emits: ['click'],
  template: `<button :disabled="disabled" @click="$emit('click')"><slot />{{ label }}</button>`,
};
const InputStub = {
  props: ['modelValue'],
  emits: ['update:modelValue'],
  template: `<input class="input-stub" :value="modelValue" @input="$emit('update:modelValue', $event.target.value)" />`,
};
// Bounded family picker: emits a server-provided code on selection.
const FamilySelectStub = {
  props: ['modelValue', 'hasError'],
  emits: ['update:modelValue', 'select'],
  template: `<button type="button" class="family-stub" @click="$emit('update:modelValue', 'PUMP-100')" />`,
};

const mountDialog = () =>
  mount(CreateDocumentDialog, {
    props: { assistantId: 1 },
    global: {
      stubs: {
        Dialog: DialogStub,
        Input: InputStub,
        TextArea: true,
        Button: ButtonStub,
        MarineProductFamilySelect: FamilySelectStub,
      },
    },
  });

const fakeFile = (name, type, size) => ({ name, type, size });
const browserFile = (name, type, body = '%PDF-1.4 test') =>
  new File([body], name, { type });

// Injects a File list onto the native input and fires the change the component listens
// for (jsdom's input.files is otherwise read-only).
const selectFile = async (wrapper, file) => {
  const input = wrapper.find('input[type="file"]');
  Object.defineProperty(input.element, 'files', {
    value: [file],
    writable: true,
    configurable: true,
  });
  await input.trigger('change');
  await flushPromises();
};

const pickerLabel = wrapper =>
  wrapper.find('input[type="file"]').exists()
    ? wrapper.findAll('button').at(0).text()
    : '';

// Selects a canonical family via the stubbed picker.
const selectFamily = async wrapper => {
  await wrapper.find('.family-stub').trigger('click');
  await flushPromises();
};

// Stages a valid catalog file + family so a product-catalog submit is valid.
const stageCatalog = async wrapper => {
  await wrapper.find('select').setValue('product_catalog');
  await selectFamily(wrapper);
  await selectFile(wrapper, browserFile('catalog.pdf', 'application/pdf'));
};

// A rejection shaped like the backend 409 primary-conflict response.
const primaryConflictError = () => ({
  response: {
    status: 409,
    data: { i18n_key: 'MARINE.DOCUMENTS.ERRORS.PRIMARY_CONFLICT' },
  },
});

describe('CreateDocumentDialog source selection', () => {
  beforeEach(() => vi.clearAllMocks());

  it('offers exactly website, sop and product_catalog source types (no empty deselect)', () => {
    const wrapper = mountDialog();
    const values = wrapper.findAll('option').map(o => o.element.value);
    expect(values).toEqual(['website', 'sop', 'product_catalog']);
  });

  it('shows the file picker only for the sop source', async () => {
    const wrapper = mountDialog();
    expect(wrapper.find('input[type="file"]').exists()).toBe(false);

    await wrapper.find('select').setValue('sop');
    expect(wrapper.find('input[type="file"]').exists()).toBe(true);
  });
});

describe('CreateDocumentDialog file clearing', () => {
  beforeEach(() => vi.clearAllMocks());

  it('stages a valid file and surfaces its name', async () => {
    const wrapper = mountDialog();
    await wrapper.find('select').setValue('sop');

    await selectFile(wrapper, fakeFile('manual.pdf', 'application/pdf', 2048));

    expect(pickerLabel(wrapper)).toContain('manual.pdf');
    expect(alertSpy).not.toHaveBeenCalled();
  });

  it('drops the staged file when leaving the sop source', async () => {
    const wrapper = mountDialog();
    await wrapper.find('select').setValue('sop');
    await selectFile(wrapper, fakeFile('manual.pdf', 'application/pdf', 2048));

    // Leave SOP, then return: the previously staged file must be gone.
    await wrapper.find('select').setValue('website');
    await wrapper.find('select').setValue('sop');

    expect(pickerLabel(wrapper)).toContain(
      'MARINE_AI.DOCUMENTS.FORM.FILE.CHOOSE_FILE'
    );
    expect(pickerLabel(wrapper)).not.toContain('manual.pdf');
  });

  it('clears a stale file and alerts when a new invalid selection is made', async () => {
    const wrapper = mountDialog();
    await wrapper.find('select').setValue('sop');
    await selectFile(wrapper, fakeFile('manual.pdf', 'application/pdf', 2048));
    expect(pickerLabel(wrapper)).toContain('manual.pdf');

    await selectFile(wrapper, fakeFile('note.txt', 'text/plain', 10));

    expect(alertSpy).toHaveBeenCalledWith(
      'MARINE_AI.DOCUMENTS.FORM.FILE.INVALID_TYPE'
    );
    expect(pickerLabel(wrapper)).not.toContain('manual.pdf');
    expect(pickerLabel(wrapper)).toContain(
      'MARINE_AI.DOCUMENTS.FORM.FILE.CHOOSE_FILE'
    );
  });

  it('submits the exact nested SOP multipart contract', async () => {
    const wrapper = mountDialog();
    await wrapper.find('select').setValue('sop');
    await wrapper.find('.input-stub').setValue('Safety SOP');
    const file = browserFile('manual.pdf', 'application/pdf');
    await selectFile(wrapper, file);

    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(createSpy).toHaveBeenCalledTimes(1);
    const payload = createSpy.mock.calls[0][0];
    expect(payload).toBeInstanceOf(FormData);
    expect(payload.get('document[source_kind]')).toBe('sop_document');
    expect(payload.get('document[assistant_id]')).toBe('1');
    expect(payload.get('document[name]')).toBe('Safety SOP');
    expect(payload.get('document[source_file]')).toBe(file);
    expect(payload.has('document[external_link]')).toBe(false);
    expect(payload.has('document[content]')).toBe(false);
  });

  it('rejects a zero-byte file locally with the empty-file message', async () => {
    const wrapper = mountDialog();
    await wrapper.find('select').setValue('sop');

    await selectFile(wrapper, fakeFile('empty.pdf', 'application/pdf', 0));

    expect(alertSpy).toHaveBeenCalledWith(
      'MARINE_AI.DOCUMENTS.FORM.FILE.EMPTY'
    );
    expect(pickerLabel(wrapper)).toContain(
      'MARINE_AI.DOCUMENTS.FORM.FILE.CHOOSE_FILE'
    );
  });
});

describe('CreateDocumentDialog website workflow (unchanged)', () => {
  beforeEach(() => vi.clearAllMocks());

  it('posts the original JSON website payload untouched', async () => {
    const wrapper = mountDialog();
    // website is the default source; fill URL + name via the stubbed inputs.
    const inputs = wrapper.findAll('.input-stub');
    await inputs[0].setValue('Docs'); // name
    await inputs[1].setValue('https://example.com'); // url

    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(createSpy).toHaveBeenCalledTimes(1);
    expect(createSpy).toHaveBeenCalledWith({
      assistantId: 1,
      name: 'Docs',
      externalLink: 'https://example.com',
      content: '',
    });
    expect(createCatalogSpy).not.toHaveBeenCalled();
  });
});

describe('CreateDocumentDialog product catalog workflow', () => {
  beforeEach(() => vi.clearAllMocks());

  it('shows the family picker (not a website URL field) for product_catalog', async () => {
    const wrapper = mountDialog();
    await wrapper.find('select').setValue('product_catalog');
    expect(wrapper.find('.family-stub').exists()).toBe(true);
    expect(wrapper.find('input[type="file"]').exists()).toBe(true);
  });

  it('submits the exact flat product-catalog FormData with replace=false', async () => {
    const wrapper = mountDialog();
    await stageCatalog(wrapper);

    await wrapper.find('form').trigger('submit');
    await flushPromises();

    expect(createSpy).not.toHaveBeenCalled();
    expect(createCatalogSpy).toHaveBeenCalledTimes(1);
    const arg = createCatalogSpy.mock.calls[0][0];
    expect(arg.assistantId).toBe(1);
    expect(arg.productFamilyCode).toBe('PUMP-100');
    expect(arg.replace).toBe(false);
    expect(arg.file).toBeInstanceOf(File);
  });

  it('requires an explicit confirmation on 409 and does not replace beforehand', async () => {
    createCatalogSpy.mockRejectedValueOnce(primaryConflictError());
    const wrapper = mountDialog();
    await stageCatalog(wrapper);

    await wrapper.find('form').trigger('submit');
    await flushPromises();

    // First attempt used replace=false; no silent replace retry happened, and the
    // explicit replacement dialog is now visible with the approved warning copy.
    expect(createCatalogSpy).toHaveBeenCalledTimes(1);
    expect(createCatalogSpy.mock.calls[0][0].replace).toBe(false);
    expect(wrapper.find('.dialog-confirm').exists()).toBe(true);
    expect(wrapper.text()).toContain(
      'MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.CONFLICT.TITLE'
    );
    expect(wrapper.text()).toContain(
      'MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.CONFLICT.MESSAGE'
    );
  });

  it('retries with replace=true only after the conflict is confirmed', async () => {
    createCatalogSpy.mockRejectedValueOnce(primaryConflictError());
    const wrapper = mountDialog();
    await stageCatalog(wrapper);
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    // Confirmation is only reachable after the conflict dialog actually opens.
    expect(wrapper.find('.dialog-confirm').exists()).toBe(true);
    await wrapper.find('.dialog-confirm').trigger('click');
    await flushPromises();

    expect(createCatalogSpy).toHaveBeenCalledTimes(2);
    expect(createCatalogSpy.mock.calls[1][0].replace).toBe(true);
  });

  it('does not replace when the conflict confirmation is cancelled', async () => {
    createCatalogSpy.mockRejectedValueOnce(primaryConflictError());
    const wrapper = mountDialog();
    await stageCatalog(wrapper);
    await wrapper.find('form').trigger('submit');
    await flushPromises();

    // Cancel closes the conflict dialog without confirming and leaves the form open.
    expect(wrapper.find('.dialog-cancel').exists()).toBe(true);
    await wrapper.find('.dialog-cancel').trigger('click');
    await flushPromises();
    expect(wrapper.find('.dialog-confirm').exists()).toBe(false);
    expect(wrapper.find('form').exists()).toBe(true);

    expect(createCatalogSpy).toHaveBeenCalledTimes(1);
    expect(createCatalogSpy.mock.calls[0][0].replace).toBe(false);
  });

  it('clears the staged catalog file and family when switching away', async () => {
    const wrapper = mountDialog();
    await stageCatalog(wrapper);
    expect(wrapper.text()).toContain('catalog.pdf');

    // Leave product_catalog, then return: file and family must be gone.
    await wrapper.find('select').setValue('website');
    await wrapper.find('select').setValue('product_catalog');

    expect(wrapper.text()).toContain(
      'MARINE_AI.DOCUMENTS.FORM.FILE.CHOOSE_FILE'
    );
    expect(wrapper.text()).not.toContain('catalog.pdf');
    expect(wrapper.findComponent(FamilySelectStub).props('modelValue')).toBe(
      ''
    );

    // A submit now is invalid (no family/file) so no upload is attempted.
    await wrapper.find('form').trigger('submit');
    await flushPromises();
    expect(createCatalogSpy).not.toHaveBeenCalled();
  });
});
