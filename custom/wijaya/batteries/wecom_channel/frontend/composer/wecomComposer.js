// Composer capability rules for a native WeCom (微信客服) inbox.
//
// WeCom supports outbound image, video, and generic file/document attachments
// (see SendOnWecomService), but NOT audio/voice attachments or voice recording.
// The native ReplyBox / ReplyBottomPanel / FileHelper consult these helpers so the
// core composer carries only one-line WIJAYA_CUSTOM delegations:
//   * ReplyBox decides the attach button / paste gate via inboxMixin's isAWecomChannel
//     and disables the audio recorder for WeCom.
//   * ReplyBottomPanel uses wecomAllowedFileTypes() for the file picker accept string.
//   * FileHelper routes paste/drop validation through wecomFileTypeAllowance().
import { getAllowedFileTypesByChannel } from '@chatwoot/utils';
import { isWecomChannelType } from '@wijaya/wecom_channel/frontend/helpers/wecomInbox';

export { isWecomChannelType };

// Accept string for the WeCom attachment picker: the native default allow-list
// (image/video/document/extensions) with every audio entry dropped — WeCom has no
// outbound voice/audio attachment support.
export function wecomAllowedFileTypes() {
  return getAllowedFileTypesByChannel()
    .split(',')
    .map(type => type.trim())
    .filter(type => type && !type.startsWith('audio/'))
    .join(', ');
}

function matchesAllowedType(file, allowedTypes) {
  const fileExtension = `.${file.name.split('.').pop()}`;
  return allowedTypes
    .split(',')
    .map(type => type.trim())
    .some(allowedType => {
      if (allowedType === fileExtension) return true;
      if (allowedType.endsWith('/*')) {
        return file.type.startsWith(`${allowedType.slice(0, -2)}/`);
      }
      return allowedType === file.type;
    });
}

// Paste/drop validation hook for the native isFileTypeAllowedForChannel seam.
// Returns true/false for a live WeCom reply, or undefined so every other channel
// (and WeCom private notes, which use the broad native list) keeps native behaviour.
export function wecomFileTypeAllowance(file, options = {}) {
  const { channelType, isOnPrivateNote } = options;
  if (isOnPrivateNote) return undefined;
  if (!isWecomChannelType(channelType)) return undefined;
  if (!file || file.size === 0) return false;
  return matchesAllowedType(file, wecomAllowedFileTypes());
}
