<script setup>
// WIJAYA_CUSTOM_START erp_lead_sidebar
// Searchable multi-select for the ERP Lead "Product Requirement" Table MultiSelect
// field. It is a dedicated component (kept separate from the inline SearchableSelect
// used by Source/Campaign/Industry/Territory/Owner) so that field's behaviour is
// never regressed. v-model is an ordered array of unique ERP document `name`s; each
// selection renders as a removable chip showing its product_name (never the raw ERP
// name). It offers an inline "Create a new Lead Product Requirement" action (no
// Advanced Search) and a focused create dialog that POSTs to ERP and then appends the
// returned record to the selection. On a conversation change all transient
// option/create state is cleared so a selection never leaks between conversations.
import {
  computed,
  nextTick,
  onBeforeUnmount,
  onMounted,
  ref,
  watch,
} from 'vue';
import ProductRequirementsAPI from '@wijaya/erp_lead_sidebar/frontend/api/wijayaErpProductRequirements';
import { parsePriceInput } from './priceFormat';

const props = defineProps({
  // The parent binds `id` to the actual combobox input (label `for` target).
  id: { type: String, default: '' },
  // Ordered array of unique ERP document names. A legacy scalar string is accepted
  // and normalized safely to a one-item array.
  modelValue: { type: [Array, String], default: () => [] },
  configured: { type: Boolean, default: false },
  conversationId: { type: [Number, String], default: '' },
});
const emit = defineEmits(['update:modelValue', 'change']);

// --- searchable list --------------------------------------------------------
const options = ref([]); // [{ value: ERP name, label: product_name }]
const listState = ref('idle'); // 'idle' | 'loading' | 'loaded' | 'error'
const listError = ref('');
const selectMessage = ref(''); // truthful "selected existing/created" note
const open = ref(false);
const query = ref('');
const highlight = ref(-1);
const rootEl = ref(null);
const inputEl = ref(null);
// name -> product_name label, cached so a chip keeps showing its product_name even
// after a remote search drops that record. Cleared on a conversation change.
const labelCache = ref({});

// The current selection as an ordered array of unique names. Legacy scalar props are
// normalized safely, so the picker never operates on a raw string.
const selectedNames = computed(() => {
  const raw = Array.isArray(props.modelValue)
    ? props.modelValue
    : [props.modelValue];
  const names = [];
  raw.forEach(value => {
    const name = typeof value === 'string' ? value.trim() : '';
    if (name && !names.includes(name)) names.push(name);
  });
  return names;
});

const labelFor = name => labelCache.value[name] || name;

// Chips shown for the current selection: product_name label + the stored name.
const selectedChips = computed(() =>
  selectedNames.value.map(name => ({ value: name, label: labelFor(name) }))
);

const isSelected = value => selectedNames.value.includes(value);

// Cache the product_name label for every resolved option so chips survive later
// remote searches that drop the record.
watch(options, list => {
  list.forEach(o => {
    labelCache.value[o.value] = o.label;
  });
});

const isLoading = computed(() => listState.value === 'loading');
const isError = computed(() => listState.value === 'error');

// Monotonic token so only the newest fetch may commit — a stale response from an
// earlier query or a superseded conversation can never win.
let requestSeq = 0;
let searchTimer = null;

const fetchList = async term => {
  requestSeq += 1;
  const seq = requestSeq;
  listState.value = 'loading';
  listError.value = '';
  try {
    const { data } = await ProductRequirementsAPI.list(term);
    if (seq !== requestSeq) return;
    options.value = Array.isArray(data.options) ? data.options : [];
    listState.value = 'loaded';
  } catch (e) {
    if (seq !== requestSeq) return;
    listError.value =
      e?.response?.data?.error || 'Product Requirements are unavailable.';
    listState.value = 'error';
  }
};

// Lazy first load on open; reuse the cache once loaded. Never fetch while ERP is
// unconfigured (the backend would reject it anyway).
const loadOnce = () => {
  if (!props.configured) return;
  if (listState.value === 'loaded' || listState.value === 'loading') return;
  fetchList('');
};

const openMenu = () => {
  // When ERP is unconfigured there is nothing to list and a create can only fail,
  // so the picker stays a truthful disabled state (input is also :disabled).
  if (!props.configured) return;
  open.value = true;
  highlight.value = -1;
  loadOnce();
};

const close = () => {
  open.value = false;
  query.value = '';
  highlight.value = -1;
};

// Server-side search (the list is bounded, so filtering must happen in ERP, not
// only over the first page). Debounced so typing does not spam the endpoint.
const onSearchInput = event => {
  query.value = event.target.value;
  open.value = true;
  highlight.value = -1;
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => fetchList(query.value.trim()), 250);
};

// Append a selection (never replace). Selecting an already-selected option is a
// no-op so a name can never be duplicated. The menu stays open so several
// requirements can be added in a row; the search remains usable throughout.
const select = option => {
  labelCache.value[option.value] = option.label;
  selectMessage.value = '';
  if (isSelected(option.value)) return;
  const next = [...selectedNames.value, option.value];
  emit('update:modelValue', next);
  emit('change', next);
};

// Remove one chip and immediately emit the remaining array (triggers autosave).
const remove = value => {
  const next = selectedNames.value.filter(name => name !== value);
  emit('update:modelValue', next);
  emit('change', next);
};

const move = delta => {
  const len = options.value.length;
  if (!len) return;
  open.value = true;
  highlight.value = (highlight.value + delta + len) % len;
};

const onEnter = () => {
  if (highlight.value >= 0 && highlight.value < options.value.length) {
    select(options.value[highlight.value]);
  }
};

const onDocClick = event => {
  if (rootEl.value && !rootEl.value.contains(event.target)) close();
};
onMounted(() => document.addEventListener('click', onDocClick));
onBeforeUnmount(() => {
  document.removeEventListener('click', onDocClick);
  clearTimeout(searchTimer);
});

// --- create dialog ----------------------------------------------------------
const dialogOpen = ref(false);
const createName = ref('');
const priceDisplay = ref(''); // Indonesian grouped display (e.g. "50.000")
const priceError = ref(''); // local price validation error (never mutates value)
const creating = ref(false);
const createError = ref('');
const nameInputEl = ref(null);

const openCreate = () => {
  if (!props.configured) return;
  // Seed the name from the current search text for a faster create.
  createName.value = query.value.trim();
  priceDisplay.value = '';
  priceError.value = '';
  createError.value = '';
  dialogOpen.value = true;
  open.value = false;
  // Practical initial focus once the dialog is in the DOM.
  nextTick(() => nameInputEl.value?.focus());
};

const closeCreate = () => {
  dialogOpen.value = false;
  // Return focus to the combobox so keyboard users are not stranded.
  nextTick(() => inputEl.value?.focus());
};

const onPriceInput = event => {
  // Validate rather than silently coerce: a grouped Indonesian value ("50.000")
  // is accepted and grouped, but a minus/comma/decimal/letter is flagged and the
  // typed text is left untouched so no invalid value is ever rewritten or sent.
  const parsed = parsePriceInput(event.target.value);
  priceDisplay.value = parsed.display;
  priceError.value = parsed.error;
};

const canCreate = computed(
  () => Boolean(createName.value.trim()) && !priceError.value && !creating.value
);

const submitCreate = async () => {
  if (!canCreate.value) return;
  // Re-validate the price at submit so an invalid value can never be sent.
  const price = parsePriceInput(priceDisplay.value);
  if (!price.valid) {
    priceError.value = price.error;
    return;
  }
  creating.value = true;
  createError.value = '';
  try {
    const { data } = await ProductRequirementsAPI.create({
      productName: createName.value.trim(),
      productPrice: price.raw,
    });
    const option = { value: data.value, label: data.label };
    // Add (or refresh) the option, append it to the selection (never replacing the
    // existing chips), and surface a truthful note.
    if (!options.value.some(o => o.value === option.value)) {
      options.value = [option, ...options.value];
    }
    labelCache.value[option.value] = option.label;
    if (!isSelected(option.value)) {
      const next = [...selectedNames.value, option.value];
      emit('update:modelValue', next);
      emit('change', next);
    }
    selectMessage.value = data.message || '';
    dialogOpen.value = false;
    nextTick(() => inputEl.value?.focus());
  } catch (e) {
    // Preserve the create form so the agent can correct and retry.
    createError.value =
      e?.response?.data?.error ||
      'Could not create the Product Requirement. Please try again.';
  } finally {
    creating.value = false;
  }
};

// A conversation change clears every transient option/create state so a
// selection or open dialog never leaks between conversations. The selected value
// itself is owned by the parent draft and reloaded there.
watch(
  () => props.conversationId,
  () => {
    requestSeq += 1; // invalidate any in-flight fetch
    clearTimeout(searchTimer);
    options.value = [];
    listState.value = 'idle';
    listError.value = '';
    selectMessage.value = '';
    labelCache.value = {};
    open.value = false;
    query.value = '';
    highlight.value = -1;
    dialogOpen.value = false;
    createName.value = '';
    priceDisplay.value = '';
    priceError.value = '';
    createError.value = '';
  }
);
// WIJAYA_CUSTOM_END erp_lead_sidebar
</script>

<template>
  <!-- eslint-disable vue/no-bare-strings-in-template, @intlify/vue-i18n/no-raw-text -->
  <!-- WIJAYA_CUSTOM_START erp_lead_sidebar -->
  <div ref="rootEl" class="relative">
    <!-- Selected requirements as removable chips. Each chip shows product_name and
         carries an accessible remove control. -->
    <ul
      v-if="selectedChips.length"
      class="mb-1 flex flex-wrap gap-1"
      aria-label="Selected product requirements"
    >
      <li
        v-for="chip in selectedChips"
        :key="chip.value"
        class="flex items-center gap-1 rounded-md bg-n-alpha-2 px-2 py-0.5 text-sm text-n-slate-12"
      >
        <span>{{ chip.label }}</span>
        <button
          type="button"
          class="leading-none text-n-slate-11 hover:text-n-ruby-10"
          :aria-label="`Remove ${chip.label}`"
          @click="remove(chip.value)"
        >
          ×
        </button>
      </li>
    </ul>
    <input
      :id="id || undefined"
      ref="inputEl"
      class="input"
      type="text"
      role="combobox"
      aria-autocomplete="list"
      :aria-expanded="open ? 'true' : 'false'"
      :aria-describedby="selectMessage ? `${id}-msg` : undefined"
      :disabled="!configured"
      :value="query"
      :placeholder="
        configured ? 'Search product requirements…' : 'ERP is not configured'
      "
      @focus="openMenu"
      @click="openMenu"
      @input="onSearchInput"
      @keydown.down.prevent="move(1)"
      @keydown.up.prevent="move(-1)"
      @keydown.enter.prevent="onEnter"
      @keydown.esc="close"
    />
    <ul
      v-if="open"
      role="listbox"
      class="absolute left-0 right-0 z-50 mt-1 max-h-48 overflow-y-auto rounded-md border border-n-weak bg-n-solid-1 py-1 shadow-lg"
    >
      <li v-if="isLoading" class="px-2 py-1 text-n-slate-10">Loading…</li>
      <li v-else-if="isError" class="px-2 py-1 text-n-ruby-10" role="alert">
        {{ listError }}
      </li>
      <li v-else-if="!options.length" class="px-2 py-1 text-n-slate-10">
        No product requirements found.
      </li>
      <template v-else>
        <li
          v-for="(option, index) in options"
          :key="option.value"
          role="option"
          :aria-selected="isSelected(option.value) ? 'true' : 'false'"
          :aria-disabled="isSelected(option.value) ? 'true' : undefined"
          class="flex items-center justify-between px-2 py-1 text-n-slate-12"
          :class="[
            isSelected(option.value)
              ? 'cursor-default text-n-slate-10'
              : 'cursor-pointer',
            index === highlight && !isSelected(option.value)
              ? 'bg-n-alpha-2'
              : 'hover:bg-n-alpha-1',
          ]"
          @mousedown.prevent="select(option)"
          @mouseenter="highlight = index"
        >
          <span>{{ option.label }}</span>
          <span v-if="isSelected(option.value)" aria-hidden="true">✓</span>
        </li>
      </template>
      <!-- Inline create action (no Advanced Search). Always available. -->
      <li
        class="mt-1 cursor-pointer border-t border-n-weak px-2 py-1 font-medium text-n-brand hover:bg-n-alpha-1"
        @mousedown.prevent="openCreate"
      >
        Create a new Lead Product Requirement
      </li>
    </ul>

    <span
      v-if="selectMessage"
      :id="`${id}-msg`"
      class="mt-1 block text-xs text-n-teal-11"
    >
      {{ selectMessage }}
    </span>

    <!-- Focused create dialog layered over the ERP Lead modal. Its own overlay +
         Escape handling (stopped so the parent modal never closes) keep the Lead
         draft intact behind it. -->
    <div
      v-if="dialogOpen"
      class="fixed inset-0 z-[60] flex items-center justify-center bg-n-alpha-black2 p-4"
      @mousedown.self="closeCreate"
      @keydown.esc.stop.prevent="closeCreate"
    >
      <div
        class="flex w-full max-w-sm flex-col gap-3 rounded-lg border border-n-weak bg-n-solid-1 p-4 shadow-xl"
        role="dialog"
        aria-modal="true"
        aria-label="Create a new Lead Product Requirement"
      >
        <h4 class="font-semibold text-n-slate-12">
          Create a new Lead Product Requirement
        </h4>

        <label class="flex flex-col gap-1" for="erp-pr-name">
          <span>Product Name</span>
          <input
            id="erp-pr-name"
            ref="nameInputEl"
            v-model="createName"
            class="input"
            type="text"
          />
        </label>

        <label class="flex flex-col gap-1" for="erp-pr-price">
          <span>Product Price</span>
          <input
            id="erp-pr-price"
            class="input"
            type="text"
            inputmode="numeric"
            :aria-invalid="priceError ? 'true' : undefined"
            :aria-describedby="priceError ? 'erp-pr-price-err' : undefined"
            :value="priceDisplay"
            placeholder="0"
            @input="onPriceInput"
          />
          <span
            v-if="priceError"
            id="erp-pr-price-err"
            class="text-xs text-n-ruby-10"
            role="alert"
          >
            {{ priceError }}
          </span>
        </label>

        <span v-if="createError" class="text-xs text-n-ruby-10" role="alert">
          {{ createError }}
        </span>

        <div class="flex justify-end gap-2 pt-1">
          <button
            type="button"
            class="rounded-md px-3 py-1 text-n-slate-11 hover:bg-n-alpha-1"
            @click="closeCreate"
          >
            Cancel
          </button>
          <button
            type="button"
            class="rounded-md bg-n-brand px-3 py-1 font-medium text-white disabled:opacity-50"
            :disabled="!canCreate"
            @click="submitCreate"
          >
            {{ creating ? 'Creating…' : 'Create' }}
          </button>
        </div>
      </div>
    </div>
  </div>
  <!-- WIJAYA_CUSTOM_END erp_lead_sidebar -->
</template>
