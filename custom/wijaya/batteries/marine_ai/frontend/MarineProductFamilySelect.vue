<script setup>
import { ref, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { debounce } from '@chatwoot/utils';
import MarineDocumentAPI from '@wijaya/marine_ai/frontend/api/document';

// Bounded product-family picker: a debounced, case-insensitive search over the canonical
// families exposed by the read-only product_families endpoint plus a click-to-select list.
// Free-form family codes are never accepted — the parent only ever receives a code the
// user picked from this server-provided list. Loading, empty, and API-unavailable states
// are surfaced explicitly.
defineProps({
  modelValue: {
    type: String,
    default: '',
  },
  hasError: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits(['update:modelValue', 'select']);

const { t } = useI18n();

const query = ref('');
const results = ref([]);
const loading = ref(false);
const loadFailed = ref(false);
const hasLoaded = ref(false);

// Monotonic token so a slow/failed earlier request can never overwrite a newer one.
let requestToken = 0;

const fetchFamilies = async () => {
  requestToken += 1;
  const token = requestToken;
  loading.value = true;
  loadFailed.value = false;
  try {
    const { data } = await MarineDocumentAPI.productFamilies({
      query: query.value,
    });
    if (token !== requestToken) return;
    results.value = data?.payload || [];
    hasLoaded.value = true;
  } catch (error) {
    if (token !== requestToken) return;
    results.value = [];
    loadFailed.value = true;
  } finally {
    if (token === requestToken) loading.value = false;
  }
};

const debouncedFetch = debounce(fetchFamilies, 300);

const handleQueryInput = () => debouncedFetch();

const selectFamily = family => {
  emit('update:modelValue', family.code);
  emit('select', family);
};

onMounted(fetchFamilies);

defineExpose({ fetchFamilies });
</script>

<template>
  <div class="flex flex-col gap-2">
    <label
      for="marineProductFamilyQuery"
      class="text-sm font-medium text-n-slate-12"
    >
      {{ t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.FAMILY.LABEL') }}
    </label>
    <input
      id="marineProductFamilyQuery"
      v-model="query"
      type="search"
      autocomplete="off"
      :placeholder="
        t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.FAMILY.SEARCH_PLACEHOLDER')
      "
      class="w-full px-3 py-2.5 text-sm rounded-xl border outline-none bg-n-alpha-black2 border-n-weak text-n-slate-12 focus:border-n-brand"
      @input="handleQueryInput"
    />

    <p v-if="loading" class="text-xs text-n-slate-11">
      {{ t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.FAMILY.LOADING') }}
    </p>

    <div
      v-else-if="loadFailed"
      class="flex items-center justify-between gap-2 rounded-lg bg-n-alpha-2 px-3 py-2"
    >
      <span class="text-xs text-n-ruby-11">
        {{ t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.FAMILY.ERROR') }}
      </span>
      <button
        type="button"
        class="text-xs font-medium text-n-blue-11 hover:underline shrink-0"
        @click="fetchFamilies"
      >
        {{ t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.FAMILY.RETRY') }}
      </button>
    </div>

    <p
      v-else-if="hasLoaded && results.length === 0"
      class="text-xs text-n-slate-11"
    >
      {{ t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.FAMILY.EMPTY') }}
    </p>

    <ul
      v-else-if="results.length"
      class="flex flex-col gap-1 overflow-y-auto rounded-lg border border-n-weak max-h-48"
    >
      <li v-for="family in results" :key="family.code">
        <button
          type="button"
          class="flex flex-col items-start w-full gap-0.5 px-3 py-2 text-start hover:bg-n-alpha-2"
          :class="
            family.code === modelValue ? 'bg-n-alpha-2 text-n-slate-12' : ''
          "
          @click="selectFamily(family)"
        >
          <span class="text-sm text-n-slate-12">{{ family.name }}</span>
          <span class="text-xs text-n-slate-11">{{ family.code }}</span>
        </button>
      </li>
    </ul>

    <p v-if="modelValue" class="text-xs text-n-teal-11">
      {{
        t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.FAMILY.SELECTED', {
          code: modelValue,
        })
      }}
    </p>
    <p v-else-if="hasError" class="text-xs text-n-ruby-9">
      {{ t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.FAMILY.REQUIRED') }}
    </p>
  </div>
</template>
