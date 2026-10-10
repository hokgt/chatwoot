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

// True for the disconnected-session send failure — the connector answers the signed
// api_inbox webhook with a 503 when the linked phone is logged out, which Webhooks::Trigger
// stores verbatim as the message external_error ("503 Service Unavailable"). Narrow on
// purpose: other failures (e.g. a 4xx connector rejection) keep the native error display.
export function isWhatsappWebDisconnectError(error) {
  if (typeof error !== 'string' || error === '') return false;
  return /^503\b/.test(error) || /service unavailable/i.test(error);
}

export default isWhatsappWebInbox;
