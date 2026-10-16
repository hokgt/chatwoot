import { isWhatsappWebDisconnectError } from '@wijaya/whatsapp_web_inbox/frontend/helpers/whatsappWebInbox';

describe('isWhatsappWebDisconnectError', () => {
  it('is true for the connector 503 disconnected-session error', () => {
    expect(isWhatsappWebDisconnectError('503 Service Unavailable')).toBe(true);
  });

  it('matches a plain "Service Unavailable" message case-insensitively', () => {
    expect(isWhatsappWebDisconnectError('service unavailable')).toBe(true);
  });

  it('is false for unrelated send failures (native display retained)', () => {
    expect(
      isWhatsappWebDisconnectError('connector rejected request (422)')
    ).toBe(false);
    expect(isWhatsappWebDisconnectError('500 Internal Server Error')).toBe(
      false
    );
  });

  it('is false for empty / non-string input', () => {
    expect(isWhatsappWebDisconnectError('')).toBe(false);
    expect(isWhatsappWebDisconnectError(null)).toBe(false);
    expect(isWhatsappWebDisconnectError(undefined)).toBe(false);
  });
});
