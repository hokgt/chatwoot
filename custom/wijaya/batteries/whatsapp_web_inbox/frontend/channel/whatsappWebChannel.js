// Battery-owned channel definition for the "WhatsApp Web (Unofficial)" Add-Inbox card.
// The native ChannelList imports buildWhatsappWebChannelCard and appends its result;
// the native ChannelItem imports isWhatsappWebChannelKey to make the card clickable;
// the native ChannelFactory maps the key to the battery wizard component. All labels,
// the icon, and the key live here so the native files carry only a one-line delegation.

export const WHATSAPP_WEB_CHANNEL_KEY = 'whatsapp_web_unofficial';

export function buildWhatsappWebChannelCard({ t }) {
  return {
    key: WHATSAPP_WEB_CHANNEL_KEY,
    title: t('WHATSAPP_WEB_INBOX.CHANNEL.TITLE'),
    description: t('WHATSAPP_WEB_INBOX.CHANNEL.DESCRIPTION'),
    icon: 'i-woot-whatsapp',
  };
}

// Clickability predicate consulted by the native ChannelItem gate.
export function isWhatsappWebChannelKey(key) {
  return key === WHATSAPP_WEB_CHANNEL_KEY;
}

export default buildWhatsappWebChannelCard;
