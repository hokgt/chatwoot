<script setup>
import { ref, computed, onMounted } from 'vue';
// WIJAYA_CUSTOM_START wecom_channel
import { watch } from 'vue';
// WIJAYA_CUSTOM_END wecom_channel
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useMapGetter } from 'dashboard/composables/store';

import { useAccount } from 'dashboard/composables/useAccount';

import ChannelItem from 'dashboard/components/widgets/ChannelItem.vue';
// WIJAYA_CUSTOM_START whatsapp_web_inbox
import { buildWhatsappWebChannelCard } from '@wijaya/whatsapp_web_inbox/frontend/channel/whatsappWebChannel';
// WIJAYA_CUSTOM_END whatsapp_web_inbox
// WIJAYA_CUSTOM_START wecom_channel
import { buildWecomChannelCard } from '@wijaya/wecom_channel/frontend/channel/wecomChannel';
// WIJAYA_CUSTOM_END wecom_channel

const { t } = useI18n();
const router = useRouter();
const { accountId, currentAccount } = useAccount();

const globalConfig = useMapGetter('globalConfig/get');

const enabledFeatures = ref({});

const hasTiktokConfigured = computed(() => {
  return window.chatwootConfig?.tiktokAppId;
});

const channelList = computed(() => {
  // WIJAYA_CUSTOM_START wecom_channel
  if (!globalConfig.value) return [];
  // WIJAYA_CUSTOM_END wecom_channel
  const { apiChannelName } = globalConfig.value;
  const channels = [
    {
      key: 'website',
      title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.WEBSITE.TITLE'),
      description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.WEBSITE.DESCRIPTION'),
      icon: 'i-woot-website',
    },
    {
      key: 'facebook',
      title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.FACEBOOK.TITLE'),
      description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.FACEBOOK.DESCRIPTION'),
      icon: 'i-woot-messenger',
    },
    {
      key: 'whatsapp',
      title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.WHATSAPP.TITLE'),
      description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.WHATSAPP.DESCRIPTION'),
      icon: 'i-woot-whatsapp',
    },
    {
      key: 'sms',
      title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.SMS.TITLE'),
      description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.SMS.DESCRIPTION'),
      icon: 'i-woot-sms',
    },
    {
      key: 'email',
      title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.EMAIL.TITLE'),
      description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.EMAIL.DESCRIPTION'),
      icon: 'i-woot-mail',
    },
    {
      key: 'api',
      title: apiChannelName || t('INBOX_MGMT.ADD.AUTH.CHANNEL.API.TITLE'),
      description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.API.DESCRIPTION'),
      icon: 'i-woot-api',
    },
    {
      key: 'telegram',
      title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.TELEGRAM.TITLE'),
      description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.TELEGRAM.DESCRIPTION'),
      icon: 'i-woot-telegram',
    },
    {
      key: 'line',
      title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.LINE.TITLE'),
      description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.LINE.DESCRIPTION'),
      icon: 'i-woot-line',
    },
    {
      key: 'instagram',
      title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.INSTAGRAM.TITLE'),
      description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.INSTAGRAM.DESCRIPTION'),
      icon: 'i-woot-instagram',
    },
  ];

  if (hasTiktokConfigured.value) {
    channels.push({
      key: 'tiktok',
      title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.TIKTOK.TITLE'),
      description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.TIKTOK.DESCRIPTION'),
      icon: 'i-woot-tiktok',
    });
  }

  channels.push({
    key: 'voice',
    title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.VOICE.TITLE'),
    description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.VOICE.DESCRIPTION'),
    icon: 'i-woot-voice',
  });

  channels.push({
    key: 'whatsapp_call',
    title: t('INBOX_MGMT.ADD.AUTH.CHANNEL.WHATSAPP_CALL.TITLE'),
    description: t('INBOX_MGMT.ADD.AUTH.CHANNEL.WHATSAPP_CALL.DESCRIPTION'),
    icon: 'i-woot-whatsapp',
  });

  // WIJAYA_CUSTOM_START whatsapp_web_inbox
  channels.push(buildWhatsappWebChannelCard({ t }));
  // WIJAYA_CUSTOM_END whatsapp_web_inbox

  // WIJAYA_CUSTOM_START wecom_channel
  channels.push(buildWecomChannelCard({ t }));
  // WIJAYA_CUSTOM_END wecom_channel

  return channels;
});

const initializeEnabledFeatures = async () => {
  // WIJAYA_CUSTOM_START wecom_channel
  if (!currentAccount.value?.features) return;
  // WIJAYA_CUSTOM_END wecom_channel
  enabledFeatures.value = currentAccount.value.features;
};

const initChannelAuth = channel => {
  const params = {
    sub_page: channel,
    accountId: accountId.value,
  };
  router.push({ name: 'settings_inboxes_page_channel', params });
};

onMounted(() => {
  initializeEnabledFeatures();
});
// WIJAYA_CUSTOM_START wecom_channel
watch(() => currentAccount.value?.features, initializeEnabledFeatures);
// WIJAYA_CUSTOM_END wecom_channel
</script>

<template>
  <div
    class="grid max-w-3xl grid-cols-1 xs:grid-cols-2 mx-0 gap-6 sm:grid-cols-3 p-8"
  >
    <ChannelItem
      v-for="channel in channelList"
      :key="channel.key"
      :channel="channel"
      :enabled-features="enabledFeatures"
      @channel-item-click="initChannelAuth"
    />
  </div>
</template>
