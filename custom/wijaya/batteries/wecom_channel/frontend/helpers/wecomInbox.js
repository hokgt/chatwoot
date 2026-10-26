// Generic predicate identifying a WeCom (微信客服) inbox from its serialized payload.
// WeCom is a native channel (Channel::Wecom), so the channel_type alone is authoritative.
// Battery-owned so the native Settings/Configuration pages carry only a one-line delegation.

export const WECOM_CHANNEL_TYPE = 'Channel::Wecom';

export function isWecomInbox(inbox) {
  if (!inbox) return false;
  return inbox.channel_type === WECOM_CHANNEL_TYPE;
}

// Predicate keyed on the raw channel_type string (the native ChannelName row passes
// props.channelType, not a serialized inbox).
export function isWecomChannelType(channelType) {
  return channelType === WECOM_CHANNEL_TYPE;
}

// Readable label for a WeCom inbox row, sourced from the battery i18n so the native
// ChannelName i18nMap needs no WeCom entry. Returns undefined for other channels so
// the native resolver keeps its existing behaviour.
export function wecomReadableChannelName({ t, channelType }) {
  if (!isWecomChannelType(channelType)) return undefined;
  return t('WECOM_INBOX.CHANNEL.TITLE');
}

export default isWecomInbox;
