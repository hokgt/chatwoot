import { mount, flushPromises } from '@vue/test-utils';
import CreateDocumentDialog from '../CreateDocumentDialog.vue';

// i18n stub: keys pass through so we can assert on them in the rendered DOM.
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const { alertSpy, createSpy } = vi.hoisted(() => ({
  alertSpy: vi.fn(),
  createSpy: vi.fn().mockResolvedValue({}),
}));
vi.mock('dashboard/composables', () => ({ useAlert: alertSpy }));

vi.mock('dashboard/store/utils/api', () => ({
  parseAPIErrorResponse: () => 'error',
}));

vi.mock('dashboard/api/marine/document', () => ({
  default: { create: createSpy },
}));

// Render slot content so the file-picker button's staged-file label is observable, and
// so the form (inside Dialog's default slot) actually mounts.
const SlotStub = {
  template: '<div><slot /><slot name="footer" /></div>',
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

const mountDialog = () =>
  mount(CreateDocumentDialog, {
    props: { assistantId: 1 },
    global: {
      stubs: {
        Dialog: SlotStub,
        Input: InputStub,
        TextArea: true,
        Button: ButtonStub,
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

describe('CreateDocumentDialog source selection', () => {
  beforeEach(() => vi.clearAllMocks());

  it('offers exactly the website and sop source types (no empty deselect)', () => {
    const wrapper = mountDialog();
    const values = wrapper.findAll('option').map(o => o.element.value);
    expect(values).toEqual(['website', 'sop']);
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
