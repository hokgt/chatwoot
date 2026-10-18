import {
  WECOM_CHANNEL_KEY,
  buildWecomChannelCard,
  isWecomChannelKey,
} from '@wijaya/wecom_channel/frontend/channel/wecomChannel';

const t = key => `t:${key}`;

describe('wecomChannel', () => {
  it('exposes a stable, unique channel key', () => {
    expect(WECOM_CHANNEL_KEY).toBe('wecom');
  });

  it('builds a card with key, title, description and icon', () => {
    const card = buildWecomChannelCard({ t });
    expect(card).toEqual({
      key: 'wecom',
      title: 't:WECOM_INBOX.CHANNEL.TITLE',
      description: 't:WECOM_INBOX.CHANNEL.DESCRIPTION',
      icon: 'i-ri-wechat-fill',
    });
  });

  it('recognises only its own key as clickable', () => {
    expect(isWecomChannelKey('wecom')).toBe(true);
    expect(isWecomChannelKey('api')).toBe(false);
    expect(isWecomChannelKey('whatsapp')).toBe(false);
  });
});
