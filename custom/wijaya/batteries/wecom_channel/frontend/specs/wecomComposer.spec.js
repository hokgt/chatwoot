import {
  wecomAllowedFileTypes,
  wecomFileTypeAllowance,
} from '@wijaya/wecom_channel/frontend/composer/wecomComposer';

const WECOM = 'Channel::Wecom';

const fakeFile = ({ name, type, size = 1024 }) => ({ name, type, size });

describe('wecomAllowedFileTypes', () => {
  it('permits image, video and document/file types', () => {
    const accept = wecomAllowedFileTypes();
    expect(accept).toContain('image/*');
    expect(accept).toContain('video/*');
    // "file" = generic documents (pdf is part of the default application group)
    expect(accept).toContain('application/pdf');
  });

  it('excludes audio/voice entirely', () => {
    const accept = wecomAllowedFileTypes();
    expect(accept).not.toContain('audio/');
  });
});

describe('wecomFileTypeAllowance', () => {
  it('accepts an image on a live WeCom reply (clipboard paste case)', () => {
    const file = fakeFile({ name: 'photo.png', type: 'image/png' });
    expect(wecomFileTypeAllowance(file, { channelType: WECOM })).toBe(true);
  });

  it('accepts a video and a generic file/document on a WeCom reply', () => {
    const video = fakeFile({ name: 'clip.mp4', type: 'video/mp4' });
    const pdf = fakeFile({ name: 'spec.pdf', type: 'application/pdf' });
    expect(wecomFileTypeAllowance(video, { channelType: WECOM })).toBe(true);
    expect(wecomFileTypeAllowance(pdf, { channelType: WECOM })).toBe(true);
  });

  it('rejects an audio file on a WeCom reply', () => {
    const audio = fakeFile({ name: 'voice.mp3', type: 'audio/mpeg' });
    expect(wecomFileTypeAllowance(audio, { channelType: WECOM })).toBe(false);
  });

  it('rejects an empty/zero-byte file on a WeCom reply', () => {
    const empty = fakeFile({ name: 'photo.png', type: 'image/png', size: 0 });
    expect(wecomFileTypeAllowance(empty, { channelType: WECOM })).toBe(false);
  });

  it('defers (returns undefined) for non-WeCom channels so native validation is unchanged', () => {
    const audio = fakeFile({ name: 'voice.mp3', type: 'audio/mpeg' });
    expect(
      wecomFileTypeAllowance(audio, { channelType: 'Channel::Api' })
    ).toBeUndefined();
    expect(wecomFileTypeAllowance(audio, {})).toBeUndefined();
  });

  it('defers for WeCom private notes (native broad list applies)', () => {
    const audio = fakeFile({ name: 'voice.mp3', type: 'audio/mpeg' });
    expect(
      wecomFileTypeAllowance(audio, {
        channelType: WECOM,
        isOnPrivateNote: true,
      })
    ).toBeUndefined();
  });
});
