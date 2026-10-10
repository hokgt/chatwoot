import {
  WHATSAPP_WEB_CHANNEL_KEY,
  buildWhatsappWebChannelCard,
  isWhatsappWebChannelKey,
} from '@wijaya/whatsapp_web_inbox/frontend/channel/whatsappWebChannel';

const t = key => `t:${key}`;

describe('whatsappWebChannel', () => {
  it('exposes a stable, unique channel key', () => {
    expect(WHATSAPP_WEB_CHANNEL_KEY).toBe('whatsapp_web_unofficial');
  });

  it('builds a card with key, title, description and icon', () => {
    const card = buildWhatsappWebChannelCard({ t });
    expect(card).toEqual({
      key: 'whatsapp_web_unofficial',
      title: 't:WHATSAPP_WEB_INBOX.CHANNEL.TITLE',
      description: 't:WHATSAPP_WEB_INBOX.CHANNEL.DESCRIPTION',
      icon: 'i-woot-whatsapp',
    });
  });

  it('recognises only its own key as clickable', () => {
    expect(isWhatsappWebChannelKey('whatsapp_web_unofficial')).toBe(true);
    expect(isWhatsappWebChannelKey('api')).toBe(false);
    expect(isWhatsappWebChannelKey('whatsapp')).toBe(false);
  });
});
