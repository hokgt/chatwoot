<script setup>
import { computed } from 'vue';
import { useToggle } from '@vueuse/core';
import { useI18n } from 'vue-i18n';
import { formatDistanceToNow, parseISO } from 'date-fns';

import CardLayout from 'dashboard/components-next/CardLayout.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';

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
    required: true,
  },
  assistant: {
    type: Object,
    default: () => ({}),
  },
  createdAt: {
    type: [Number, String],
    default: '',
  },
  status: {
    type: String,
    default: null,
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

const [showActionsDropdown, toggleDropdown] = useToggle();

const canSync = computed(
  () => props.status === 'available' && props.syncStatus !== 'syncing'
);

const menuItems = computed(() => {
  const options = [];
  if (canSync.value) {
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
    <div class="flex gap-4 justify-between items-center w-full">
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
