// Generic predicate identifying a WeCom (微信客服) inbox from its serialized payload.
// WeCom is a native channel (Channel::Wecom), so the channel_type alone is authoritative.
// Battery-owned so the native Settings/Configuration pages carry only a one-line delegation.

export const WECOM_CHANNEL_TYPE = 'Channel::Wecom';

export function isWecomInbox(inbox) {
  if (!inbox) return false;
  return inbox.channel_type === WECOM_CHANNEL_TYPE;
}

export default isWecomInbox;
