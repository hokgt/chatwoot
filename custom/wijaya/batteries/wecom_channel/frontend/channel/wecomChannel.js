// Battery-owned channel definition for the "WeCom (微信客服)" Add-Inbox card.
// The native ChannelList imports buildWecomChannelCard and appends its result;
// the native ChannelItem imports isWecomChannelKey to make the card clickable;
// the native ChannelFactory maps the key to the battery setup component. All labels,
// the icon, and the key live here so the native files carry only a one-line delegation.

export const WECOM_CHANNEL_KEY = 'wecom';

export function buildWecomChannelCard({ t }) {
  return {
    key: WECOM_CHANNEL_KEY,
    title: t('WECOM_INBOX.CHANNEL.TITLE'),
    description: t('WECOM_INBOX.CHANNEL.DESCRIPTION'),
    icon: 'i-ri-wechat-fill',
  };
}

// Clickability predicate consulted by the native ChannelItem gate.
export function isWecomChannelKey(key) {
  return key === WECOM_CHANNEL_KEY;
}

export default buildWecomChannelCard;
