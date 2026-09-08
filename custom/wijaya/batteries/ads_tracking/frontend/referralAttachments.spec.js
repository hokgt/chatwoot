import { excludeReferralVideoAttachment } from './referralAttachments';

describe('excludeReferralVideoAttachment', () => {
  const referralVideo = { id: 42, fileType: 'video', dataUrl: 'blob/42' };
  const customerImage = { id: 7, fileType: 'image', dataUrl: 'blob/7' };
  const customerVideo = { id: 9, fileType: 'video', dataUrl: 'blob/9' };

  it('drops only the referral video attachment from the bubble-path list', () => {
    const result = excludeReferralVideoAttachment(
      [referralVideo, customerImage, customerVideo],
      { videoAttachmentId: 42 }
    );

    // The inline-played creative is gone from the ordinary bubble inputs...
    expect(result).not.toContainEqual(referralVideo);
    // ...while unrelated customer attachments (including other videos) remain.
    expect(result).toEqual([customerImage, customerVideo]);
  });

  it('empties the bubble-path list when the message only holds the referral video', () => {
    const result = excludeReferralVideoAttachment([referralVideo], {
      videoAttachmentId: 42,
    });

    // No single-attachment Video bubble is selected, so nothing renders twice.
    expect(result).toEqual([]);
  });

  it('never hides an unrelated attachment that shares the id but is not a video', () => {
    const lookalike = { id: 42, fileType: 'image', dataUrl: 'blob/42-image' };
    const result = excludeReferralVideoAttachment([lookalike], {
      videoAttachmentId: 42,
    });

    expect(result).toEqual([lookalike]);
  });

  it('returns the list unchanged when there is no stored referral video', () => {
    const attachments = [customerImage, customerVideo];

    expect(excludeReferralVideoAttachment(attachments, null)).toBe(attachments);
    expect(excludeReferralVideoAttachment(attachments, {})).toBe(attachments);
  });

  it('tolerates a missing attachment list', () => {
    expect(
      excludeReferralVideoAttachment(undefined, { videoAttachmentId: 42 })
    ).toEqual([]);
  });
});
