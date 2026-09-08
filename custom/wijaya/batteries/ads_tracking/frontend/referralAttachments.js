// Excludes the Wijaya-owned referral video attachment — the ad creative the
// server safely downloaded and stored, identified by the Chatwoot-owned
// `videoAttachmentId` on the ads referral — from the ordinary message-bubble
// rendering path. That single attachment is already played inline by the
// AdsReferral card, so without this it would render a second time as a normal
// Video bubble. It stays on the message (the full list is still passed to
// AdsReferral and used for API/media-history semantics); only the bubble
// path's input is narrowed. Unrelated customer attachments are always kept.
//
// The match mirrors AdsReferral's own lookup: same id AND a video fileType, so
// an unrelated attachment that happens to share the id is never hidden.
export const excludeReferralVideoAttachment = (attachments, adsReferral) => {
  if (!Array.isArray(attachments)) return [];

  const videoAttachmentId = adsReferral?.videoAttachmentId;
  if (!videoAttachmentId) return attachments;

  return attachments.filter(
    attachment =>
      !(
        attachment?.id === videoAttachmentId &&
        (attachment?.fileType || '').toString().toLowerCase() === 'video'
      )
  );
};
