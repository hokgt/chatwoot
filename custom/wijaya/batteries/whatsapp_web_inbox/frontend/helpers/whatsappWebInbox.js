// Generic predicate identifying a WhatsApp Web (Unofficial) inbox from its serialized
// payload. The underlying channel is a Channel::Api carrying the stable namespaced
// marker on additional_attributes (wijaya_provider: 'whatsapp_web'), mirroring how the
// native code distinguishes whatsapp_cloud via channel_type + provider. Battery-owned so
// the native Settings page carries only a one-line delegation.

export const WHATSAPP_WEB_PROVIDER = 'whatsapp_web';

export function isWhatsappWebInbox(inbox) {
  if (!inbox) return false;
  return (
    inbox.channel_type === 'Channel::Api' &&
    inbox.additional_attributes?.wijaya_provider === WHATSAPP_WEB_PROVIDER
  );
}

export default isWhatsappWebInbox;
