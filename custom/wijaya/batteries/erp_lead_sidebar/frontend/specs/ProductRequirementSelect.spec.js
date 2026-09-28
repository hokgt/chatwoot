import { mount, flushPromises } from '@vue/test-utils';
import { describe, it, expect, beforeEach, vi } from 'vitest';
import ProductRequirementSelect from '@wijaya/erp_lead_sidebar/frontend/ProductRequirementSelect.vue';

const { listSpy, createSpy } = vi.hoisted(() => ({
  listSpy: vi.fn(),
  createSpy: vi.fn(),
}));

vi.mock(
  '@wijaya/erp_lead_sidebar/frontend/api/wijayaErpProductRequirements',
  () => ({
    default: { list: listSpy, create: createSpy },
  })
);

const mountSelect = (props = {}) =>
  mount(ProductRequirementSelect, {
    props: { modelValue: '', configured: true, conversationId: 7, ...props },
  });

const openMenu = async wrapper => {
  await wrapper.find('input[role="combobox"]').trigger('focus');
  await flushPromises();
};

const findByText = (wrapper, selector, text) =>
  wrapper.findAll(selector).find(el => el.text().includes(text));

const openCreateDialog = async wrapper => {
  await openMenu(wrapper);
  await findByText(
    wrapper,
    'li',
    'Create a new Lead Product Requirement'
  ).trigger('mousedown');
  await flushPromises();
};

describe('ProductRequirementSelect', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    listSpy.mockResolvedValue({
      data: { options: [{ value: 'LPR-1', label: 'Blue Shirt' }] },
    });
  });

  it('displays product_name but stores/emits the ERP document name', async () => {
    const wrapper = mountSelect();
    await openMenu(wrapper);

    const option = findByText(wrapper, 'li[role="option"]', 'Blue Shirt');
    expect(option.text()).toBe('Blue Shirt');

    await option.trigger('mousedown');
    expect(wrapper.emitted('update:modelValue')[0]).toEqual(['LPR-1']);
    expect(wrapper.emitted('change')[0]).toEqual(['LPR-1']);
  });

  it('binds the id prop to the combobox input so a parent label `for` associates', () => {
    const wrapper = mountSelect({ id: 'erp-product-requirement' });
    const input = wrapper.find('input[role="combobox"]');
    expect(input.attributes('id')).toBe('erp-product-requirement');
    // The id must land on the input, not fall through to the root element.
    expect(wrapper.element.getAttribute('id')).toBe(null);
  });

  it('has no Advanced Search affordance', async () => {
    const wrapper = mountSelect();
    await openMenu(wrapper);
    expect(wrapper.text()).not.toContain('Advanced Search');
  });

  it('opens the create dialog from the inline action', async () => {
    const wrapper = mountSelect();
    await openCreateDialog(wrapper);
    expect(wrapper.find('[role="dialog"]').exists()).toBe(true);
  });

  it('cancel closes the dialog without selecting or creating', async () => {
    const wrapper = mountSelect();
    await openCreateDialog(wrapper);

    await findByText(wrapper, '[role="dialog"] button', 'Cancel').trigger(
      'click'
    );

    expect(wrapper.find('[role="dialog"]').exists()).toBe(false);
    expect(createSpy).not.toHaveBeenCalled();
    expect(wrapper.emitted('update:modelValue')).toBeFalsy();
  });

  it('renders 50000 as 50.000 and sends the raw 50000 on create', async () => {
    createSpy.mockResolvedValue({
      data: {
        value: 'LPR-9',
        label: 'Red Cap',
        duplicate: false,
        message: 'Product Requirement created.',
      },
    });
    const wrapper = mountSelect();
    await openCreateDialog(wrapper);

    await wrapper.find('#erp-pr-name').setValue('Red Cap');
    const price = wrapper.find('#erp-pr-price');
    await price.setValue('50000');
    expect(price.element.value).toBe('50.000');

    await findByText(wrapper, '[role="dialog"] button', 'Create').trigger(
      'click'
    );
    await flushPromises();

    expect(createSpy).toHaveBeenCalledWith({
      productName: 'Red Cap',
      productPrice: '50000',
    });
  });

  it('auto-selects the created record and closes the dialog on success', async () => {
    createSpy.mockResolvedValue({
      data: {
        value: 'LPR-9',
        label: 'Red Cap',
        duplicate: false,
        message: 'Product Requirement created.',
      },
    });
    const wrapper = mountSelect();
    await openCreateDialog(wrapper);
    await wrapper.find('#erp-pr-name').setValue('Red Cap');

    await findByText(wrapper, '[role="dialog"] button', 'Create').trigger(
      'click'
    );
    await flushPromises();

    expect(wrapper.emitted('update:modelValue').at(-1)).toEqual(['LPR-9']);
    expect(wrapper.emitted('change').at(-1)).toEqual(['LPR-9']);
    expect(wrapper.find('[role="dialog"]').exists()).toBe(false);
    expect(wrapper.text()).toContain('Product Requirement created.');
  });

  it('selects the existing record on a duplicate response', async () => {
    createSpy.mockResolvedValue({
      data: {
        value: 'LPR-1',
        label: 'Blue Shirt',
        duplicate: true,
        message: 'A matching Product Requirement already exists; selecting it.',
      },
    });
    const wrapper = mountSelect();
    await openCreateDialog(wrapper);
    await wrapper.find('#erp-pr-name').setValue('blue shirt');

    await findByText(wrapper, '[role="dialog"] button', 'Create').trigger(
      'click'
    );
    await flushPromises();

    expect(wrapper.emitted('update:modelValue').at(-1)).toEqual(['LPR-1']);
    expect(wrapper.text()).toContain('already exists');
  });

  it('preserves the create form and shows a safe error on failure', async () => {
    createSpy.mockRejectedValue({
      response: { data: { error: 'Product Name is required' } },
    });
    const wrapper = mountSelect();
    await openCreateDialog(wrapper);
    await wrapper.find('#erp-pr-name').setValue('Red Cap');

    await findByText(wrapper, '[role="dialog"] button', 'Create').trigger(
      'click'
    );
    await flushPromises();

    expect(wrapper.find('[role="dialog"]').exists()).toBe(true);
    expect(wrapper.find('#erp-pr-name').element.value).toBe('Red Cap');
    expect(wrapper.text()).toContain('Product Name is required');
    expect(wrapper.emitted('update:modelValue')).toBeFalsy();
  });

  it('rejects an invalid price locally and never submits a coerced value', async () => {
    const wrapper = mountSelect();
    await openCreateDialog(wrapper);
    await wrapper.find('#erp-pr-name').setValue('Red Cap');

    const price = wrapper.find('#erp-pr-price');
    await price.setValue('-500');
    // The field is left untouched (not silently rewritten to 500) and flagged.
    expect(price.element.value).toBe('-500');
    expect(wrapper.find('#erp-pr-price-err').exists()).toBe(true);

    // Create is disabled and clicking it issues no POST.
    const createBtn = findByText(wrapper, '[role="dialog"] button', 'Create');
    expect(createBtn.attributes('disabled')).toBeDefined();
    await createBtn.trigger('click');
    await flushPromises();
    expect(createSpy).not.toHaveBeenCalled();
    expect(wrapper.find('[role="dialog"]').exists()).toBe(true);
  });

  it('presents a truthful disabled state and opens nothing when ERP is unconfigured', async () => {
    const wrapper = mountSelect({ configured: false });
    const input = wrapper.find('input[role="combobox"]');
    expect(input.attributes('disabled')).toBeDefined();

    await input.trigger('focus');
    await flushPromises();
    // No fetch, no menu, no create affordance.
    expect(listSpy).not.toHaveBeenCalled();
    expect(wrapper.find('ul[role="listbox"]').exists()).toBe(false);
  });

  it('keeps the selected product_name label across a remote search that drops it', async () => {
    const wrapper = mountSelect();
    await openMenu(wrapper);
    await findByText(wrapper, 'li[role="option"]', 'Blue Shirt').trigger(
      'mousedown'
    );
    expect(wrapper.emitted('update:modelValue').at(-1)).toEqual(['LPR-1']);
    // Simulate the parent v-model committing the selected value.
    await wrapper.setProps({ modelValue: 'LPR-1' });

    // A later search returns a list WITHOUT the selected record.
    listSpy.mockResolvedValueOnce({
      data: { options: [{ value: 'LPR-2', label: 'Green Hat' }] },
    });
    const input = wrapper.find('input[role="combobox"]');
    vi.useFakeTimers();
    await input.setValue('green');
    await vi.advanceTimersByTimeAsync(300); // fire the debounced fetch
    vi.useRealTimers();
    await flushPromises();
    await input.trigger('keydown', { key: 'Escape' });

    // The closed control still shows the product_name, never the raw ERP name.
    expect(input.element.value).toBe('Blue Shirt');
  });

  it('clears transient option state on a conversation change', async () => {
    const wrapper = mountSelect();
    await openMenu(wrapper);
    expect(listSpy).toHaveBeenCalledTimes(1);
    expect(findByText(wrapper, 'li[role="option"]', 'Blue Shirt')).toBeTruthy();

    await wrapper.setProps({ conversationId: 99 });
    await flushPromises();

    // Menu is closed and the cache is dropped: reopening refetches (no leaked list).
    expect(wrapper.find('ul[role="listbox"]').exists()).toBe(false);
    await openMenu(wrapper);
    expect(listSpy).toHaveBeenCalledTimes(2);
  });
});
