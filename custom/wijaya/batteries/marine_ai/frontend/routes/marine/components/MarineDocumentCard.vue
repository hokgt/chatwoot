<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { formatDistanceToNow, parseISO } from 'date-fns';

import CardLayout from 'dashboard/components-next/CardLayout.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import { ACTIVE_INDEXING_STATES } from '../helpers/documentHelpers';

const props = defineProps({
  id: {
    type: Number,
    required: true,
  },
  name: {
    type: String,
    default: '',
  },
  externalLink: {
    type: String,
    default: '',
  },
  sourceKind: {
    type: String,
    default: 'website',
  },
  sourceFile: {
    type: Object,
    default: null,
  },
  productFamilyCode: {
    type: String,
    default: null,
  },
  primaryCatalog: {
    type: Boolean,
    default: false,
  },
  indexingStatus: {
    type: String,
    default: null,
  },
  indexedChunkCount: {
    type: Number,
    default: null,
  },
  failureCode: {
    type: String,
    default: null,
  },
  assistant: {
    type: Object,
    default: () => ({}),
  },
  createdAt: {
    type: [Number, String],
    default: '',
  },
  syncStatus: {
    type: String,
    default: null,
  },
  showMenu: {
    type: Boolean,
    default: true,
  },
});

const emit = defineEmits(['action']);

const { t } = useI18n();

const showActionsDropdown = ref(false);
const toggleDropdown = value => {
  showActionsDropdown.value =
    typeof value === 'boolean' ? value : !showActionsDropdown.value;
};

const isSop = computed(() => props.sourceKind === 'sop_document');
const isProductCatalog = computed(() => props.sourceKind === 'product_catalog');

// SOP is "processing" while extraction runs or indexing has not reached a terminal
// state, so we hide reprocess and keep polling driven from the parent list.
const isProcessing = computed(() => {
  if (props.syncStatus === 'syncing') return true;
  return isSop.value && ACTIVE_INDEXING_STATES.includes(props.indexingStatus);
});

const menuItems = computed(() => {
  const options = [];
  if (isProductCatalog.value) {
    // Product catalogs are never sync/reprocess-able.
  } else if (isSop.value) {
    if (!isProcessing.value) {
      options.push({
        label: t('MARINE_AI.DOCUMENTS.SOP.REPROCESS.LABEL'),
        value: 'reprocess',
        action: 'reprocess',
        icon: 'i-lucide-refresh-cw',
      });
    }
  } else if (props.syncStatus !== 'syncing') {
    options.push({
      label: t('MARINE_AI.DOCUMENTS.OPTIONS.SYNC_NOW'),
      value: 'sync',
      action: 'sync',
      icon: 'i-lucide-refresh-cw',
    });
  }
  options.push({
    label: t('MARINE_AI.DOCUMENTS.OPTIONS.DELETE_DOCUMENT'),
    value: 'delete',
    action: 'delete',
    icon: 'i-lucide-trash',
  });
  return options;
});

const syncStatusBadge = computed(() => {
  if (props.syncStatus === 'synced') {
    return {
      label: t('MARINE_AI.DOCUMENTS.SYNC_STATUS.SYNCED'),
      class: 'bg-n-teal-3 text-n-teal-11',
    };
  }
  if (props.syncStatus === 'syncing') {
    return {
      label: t('MARINE_AI.DOCUMENTS.SYNC_STATUS.SYNCING'),
      class: 'bg-n-amber-3 text-n-amber-11',
    };
  }
  if (props.syncStatus === 'failed') {
    return {
      label: t('MARINE_AI.DOCUMENTS.SYNC_STATUS.FAILED'),
      class: 'bg-n-ruby-3 text-n-ruby-11',
    };
  }
  return {
    label: t('MARINE_AI.DOCUMENTS.SYNC_STATUS.NEVER_SYNCED'),
    class: 'bg-n-alpha-2 text-n-slate-11',
  };
});

// Extraction (OCR/text) status, shown only for SOP sources.
const extractionBadge = computed(() => {
  if (props.syncStatus === 'synced') {
    return {
      label: t('MARINE_AI.DOCUMENTS.SOP.EXTRACTION_STATUS.EXTRACTED'),
      class: 'bg-n-teal-3 text-n-teal-11',
    };
  }
  if (props.syncStatus === 'syncing') {
    return {
      label: t('MARINE_AI.DOCUMENTS.SOP.EXTRACTION_STATUS.EXTRACTING'),
      class: 'bg-n-amber-3 text-n-amber-11',
    };
  }
  if (props.syncStatus === 'failed') {
    return {
      label: t('MARINE_AI.DOCUMENTS.SOP.EXTRACTION_STATUS.FAILED'),
      class: 'bg-n-ruby-3 text-n-ruby-11',
    };
  }
  return {
    label: t('MARINE_AI.DOCUMENTS.SOP.EXTRACTION_STATUS.PENDING'),
    class: 'bg-n-alpha-2 text-n-slate-11',
  };
});

// Indexing status, relevant only once extraction has produced content.
const indexingBadge = computed(() => {
  if (props.indexingStatus === 'indexed') {
    return {
      label: t('MARINE_AI.DOCUMENTS.SOP.INDEXING_STATUS.INDEXED'),
      class: 'bg-n-teal-3 text-n-teal-11',
    };
  }
  if (ACTIVE_INDEXING_STATES.includes(props.indexingStatus)) {
    return {
      label: t('MARINE_AI.DOCUMENTS.SOP.INDEXING_STATUS.INDEXING'),
      class: 'bg-n-amber-3 text-n-amber-11',
    };
  }
  if (props.indexingStatus === 'failed') {
    return {
      label: t('MARINE_AI.DOCUMENTS.SOP.INDEXING_STATUS.FAILED'),
      class: 'bg-n-ruby-3 text-n-ruby-11',
    };
  }
  return {
    label: t('MARINE_AI.DOCUMENTS.SOP.INDEXING_STATUS.NOT_INDEXED'),
    class: 'bg-n-alpha-2 text-n-slate-11',
  };
});

const showIndexingBadge = computed(
  () => isSop.value && props.syncStatus === 'synced'
);

const chunkCountLabel = computed(() => {
  if (!showIndexingBadge.value) return '';
  if (props.indexingStatus !== 'indexed') return '';
  if (props.indexedChunkCount == null) return '';
  return t(
    'MARINE_AI.DOCUMENTS.SOP.CHUNK_COUNT',
    { count: props.indexedChunkCount },
    props.indexedChunkCount
  );
});

const FILE_TYPE_LABELS = {
  'application/pdf': 'PDF',
  'image/jpeg': 'JPEG',
  'image/png': 'PNG',
};

const fileTypeLabel = computed(() => {
  const type = props.sourceFile?.content_type;
  if (!type) return '';
  return FILE_TYPE_LABELS[type] || type;
});

const fileSizeLabel = computed(() => {
  const size = props.sourceFile?.byte_size;
  if (size == null) return '';
  if (size >= 1024 * 1024) return `${(size / 1024 / 1024).toFixed(2)} MB`;
  return `${Math.max(1, Math.round(size / 1024))} KB`;
});

const fileMetaLabel = computed(() => {
  const parts = [fileTypeLabel.value, fileSizeLabel.value].filter(Boolean);
  return parts.join(' · ');
});

const timestamp = computed(() => {
  const raw = props.createdAt;
  if (!raw) return '';
  const date = typeof raw === 'number' ? new Date(raw * 1000) : parseISO(raw);
  return formatDistanceToNow(date, { addSuffix: true });
});

const handleAction = ({ action, value }) => {
  toggleDropdown(false);
  emit('action', { action, value, id: props.id });
};
</script>

<template>
  <CardLayout class="relative">
    <div class="flex gap-1 justify-between w-full">
      <span class="text-base text-n-slate-12 line-clamp-1">
        {{ name }}
      </span>
      <div v-if="showMenu" class="flex gap-2 items-center">
        <div
          v-on-clickaway="() => toggleDropdown(false)"
          class="flex relative items-center group"
        >
          <Button
            icon="i-lucide-ellipsis-vertical"
            color="slate"
            size="xs"
            class="rounded-md group-hover:bg-n-alpha-2"
            @click="toggleDropdown()"
          />
          <DropdownMenu
            v-if="showActionsDropdown"
            :menu-items="menuItems"
            class="top-full mt-1 ltr:right-0 rtl:left-0"
            @action="handleAction($event)"
          />
        </div>
      </div>
    </div>

    <!-- Website: external source link + sync badge -->
    <div
      v-if="sourceKind === 'website'"
      class="flex gap-4 justify-between items-center w-full"
    >
      <a
        :href="externalLink"
        :title="externalLink"
        target="_blank"
        rel="noopener noreferrer"
        class="flex flex-1 gap-1 justify-start items-center text-sm truncate text-n-slate-11 hover:text-n-slate-12 hover:underline"
        @click.stop
      >
        <Icon icon="i-ph-link-simple" class="shrink-0" />
        <span class="truncate">{{ externalLink }}</span>
        <Icon icon="i-lucide-external-link size-3 shrink-0 opacity-70" />
      </a>
      <span
        class="rounded-full px-2 py-0.5 text-xs font-medium shrink-0"
        :class="syncStatusBadge.class"
      >
        {{ syncStatusBadge.label }}
      </span>
    </div>

    <!-- File-backed (SOP / product catalog): safe file metadata, no URL/checksum -->
    <div v-else class="flex flex-col gap-2 w-full">
      <div class="flex gap-4 justify-between items-center w-full">
        <span
          class="flex flex-1 gap-1 justify-start items-center text-sm truncate text-n-slate-11"
        >
          <Icon icon="i-ph-file-text" class="shrink-0" />
          <span class="truncate">{{ sourceFile?.filename || name }}</span>
          <span v-if="fileMetaLabel" class="shrink-0 text-n-slate-10">
            {{ fileMetaLabel }}
          </span>
        </span>
        <span
          v-if="isSop"
          class="rounded-full px-2 py-0.5 text-xs font-medium shrink-0"
          :class="extractionBadge.class"
        >
          {{ extractionBadge.label }}
        </span>
      </div>
      <!-- Product catalog: source badge, primary badge, and family code only. No sync,
           extraction, or indexing status is ever shown for catalogs. -->
      <div
        v-if="isProductCatalog"
        class="flex flex-wrap gap-2 justify-start items-center w-full"
      >
        <span
          class="rounded-full px-2 py-0.5 text-xs font-medium shrink-0 bg-n-slate-3 text-n-slate-11"
        >
          {{ t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.BADGE') }}
        </span>
        <span
          v-if="primaryCatalog"
          class="rounded-full px-2 py-0.5 text-xs font-medium shrink-0 bg-n-teal-3 text-n-teal-11"
        >
          {{ t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.PRIMARY_BADGE') }}
        </span>
        <span v-if="productFamilyCode" class="text-xs text-n-slate-11">
          {{
            t('MARINE_AI.DOCUMENTS.PRODUCT_CATALOG.FAMILY_CODE', {
              code: productFamilyCode,
            })
          }}
        </span>
      </div>
      <div
        v-if="showIndexingBadge"
        class="flex gap-2 justify-start items-center w-full"
      >
        <span
          class="rounded-full px-2 py-0.5 text-xs font-medium shrink-0"
          :class="indexingBadge.class"
        >
          {{ indexingBadge.label }}
        </span>
        <span v-if="chunkCountLabel" class="text-xs text-n-slate-11">
          {{ chunkCountLabel }}
        </span>
      </div>
      <span v-if="isSop && failureCode" class="text-xs text-n-ruby-11">
        {{ t('MARINE_AI.DOCUMENTS.SOP.ERROR_CODE', { code: failureCode }) }}
      </span>
    </div>

    <div class="flex gap-3 justify-between items-center w-full">
      <span
        v-if="assistant?.name"
        class="flex gap-1 items-center text-sm truncate shrink-0 text-n-slate-11"
      >
        <Icon icon="i-lucide-bot" class="size-3.5" />
        {{ assistant.name }}
      </span>
      <div
        v-if="timestamp"
        class="shrink-0 text-sm text-n-slate-11 line-clamp-1 inline-flex items-center gap-1"
      >
        <Icon icon="i-ph-calendar-dot" class="size-3.5" />
        {{ timestamp }}
      </div>
    </div>
  </CardLayout>
</template>
