import {
  isWhatsappWebInbox,
  WHATSAPP_WEB_PROVIDER,
} from '@wijaya/whatsapp_web_inbox/frontend/helpers/whatsappWebInbox';

describe('isWhatsappWebInbox', () => {
  it('is true only for a Channel::Api inbox carrying the provider marker', () => {
    expect(
      isWhatsappWebInbox({
        channel_type: 'Channel::Api',
        additional_attributes: { wijaya_provider: WHATSAPP_WEB_PROVIDER },
      })
    ).toBe(true);
  });

  it('is false for a plain API inbox without the marker', () => {
    expect(
      isWhatsappWebInbox({
        channel_type: 'Channel::Api',
        additional_attributes: {},
      })
    ).toBe(false);
  });

  it('is false for other channel types even with the marker', () => {
    expect(
      isWhatsappWebInbox({
        channel_type: 'Channel::Whatsapp',
        additional_attributes: { wijaya_provider: 'whatsapp_web' },
      })
    ).toBe(false);
  });

  it('is false for null/undefined/missing attributes', () => {
    expect(isWhatsappWebInbox(null)).toBe(false);
    expect(isWhatsappWebInbox(undefined)).toBe(false);
    expect(isWhatsappWebInbox({ channel_type: 'Channel::Api' })).toBe(false);
  });
});
