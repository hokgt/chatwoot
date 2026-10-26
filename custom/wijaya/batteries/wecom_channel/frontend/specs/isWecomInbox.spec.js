import {
  isWecomInbox,
  WECOM_CHANNEL_TYPE,
} from '@wijaya/wecom_channel/frontend/helpers/wecomInbox';

describe('isWecomInbox', () => {
  it('is true only for a Channel::Wecom inbox', () => {
    expect(isWecomInbox({ channel_type: WECOM_CHANNEL_TYPE })).toBe(true);
  });

  it('is false for other channel types', () => {
    expect(isWecomInbox({ channel_type: 'Channel::Api' })).toBe(false);
    expect(isWecomInbox({ channel_type: 'Channel::Whatsapp' })).toBe(false);
  });

  it('is false for null/undefined/missing channel_type', () => {
    expect(isWecomInbox(null)).toBe(false);
    expect(isWecomInbox(undefined)).toBe(false);
    expect(isWecomInbox({})).toBe(false);
  });
});
