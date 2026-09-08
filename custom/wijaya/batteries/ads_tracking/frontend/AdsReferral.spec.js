import { mount } from '@vue/test-utils';
import AdsReferral from './AdsReferral.vue';

const mountReferral = (referral, attachments = []) =>
  mount(AdsReferral, { props: { referral, attachments } });

describe('AdsReferral', () => {
  it('plays the stored referral video inline using its normal attachment dataUrl', () => {
    const wrapper = mountReferral(
      {
        mediaType: 'video',
        // The raw Meta URL stays only for the fallback action, never as a src.
        videoUrl: 'https://cdn.example.com/creative',
        thumbnailUrl: 'https://cdn.example.com/thumb.jpg',
        headline: 'Playable ad',
        sourceUrl: 'https://example.com/landing',
        videoAttachmentId: 42,
      },
      [
        {
          id: 42,
          fileType: 'video',
          dataUrl: 'https://app.example.com/blob/42',
        },
      ]
    );

    const video = wrapper.find('video');
    expect(video.exists()).toBe(true);
    // The inline source is the stored attachment, not the external referral URL.
    expect(video.attributes('src')).toBe('https://app.example.com/blob/42');
    expect(video.attributes('controls')).toBeDefined();
    // The card must not be wrapped in a link while inline playback is active.
    expect(wrapper.find('a').exists()).toBe(false);
    expect(wrapper.find('img').exists()).toBe(false);
  });

  it('falls back to a thumbnail + Watch ad link when the stored video fails to load', async () => {
    const wrapper = mountReferral(
      {
        mediaType: 'video',
        videoUrl: 'https://cdn.example.com/creative.mp4',
        thumbnailUrl: 'https://cdn.example.com/thumb.jpg',
        headline: 'Playable ad',
        sourceUrl: 'https://example.com/landing',
        videoAttachmentId: 42,
      },
      [
        {
          id: 42,
          fileType: 'video',
          dataUrl: 'https://app.example.com/blob/42',
        },
      ]
    );

    await wrapper.find('video').trigger('error');

    expect(wrapper.find('video').exists()).toBe(false);
    expect(wrapper.find('img').attributes('src')).toBe(
      'https://cdn.example.com/thumb.jpg'
    );
    const link = wrapper.find('a');
    expect(link.exists()).toBe(true);
    // Video fallback keeps videoUrl as the primary external destination.
    expect(link.attributes('href')).toBe(
      'https://cdn.example.com/creative.mp4'
    );
    expect(link.attributes('rel')).toBe('noopener noreferrer');
    expect(link.attributes('target')).toBe('_blank');
  });

  it('never plays a Facebook Reel/page URL inline — with no stored attachment it stays a thumbnail + Watch ad link', () => {
    // A real CTWA payload carries both: source_url (the fb.me ad destination) and
    // video_url (the Reel/page). The Reel is not downloadable as video/*, so the
    // server stored no attachment: the card must render the fallback, never a
    // <video> pointed at the Reel URL.
    const wrapper = mountReferral({
      mediaType: 'video',
      videoUrl: 'https://www.facebook.com/reel/1234567890',
      sourceUrl: 'https://fb.me/ad-destination',
      thumbnailUrl: 'https://cdn.example.com/thumb.jpg',
      headline: 'Reel ad',
    });

    expect(wrapper.find('video').exists()).toBe(false);
    expect(wrapper.find('img').attributes('src')).toBe(
      'https://cdn.example.com/thumb.jpg'
    );
    const link = wrapper.find('a');
    expect(link.exists()).toBe(true);
    expect(link.attributes('href')).toBe(
      'https://www.facebook.com/reel/1234567890'
    );
  });

  it('does not play inline when the associated attachment is not present on the message', () => {
    // videoAttachmentId points at an attachment that is not in the list (e.g. it
    // was never stored). No match -> no inline video, fallback card instead.
    const wrapper = mountReferral(
      {
        mediaType: 'video',
        videoUrl: 'https://cdn.example.com/creative.mp4',
        thumbnailUrl: 'https://cdn.example.com/thumb.jpg',
        headline: 'Missing blob',
        videoAttachmentId: 99,
      },
      [{ id: 7, fileType: 'image', dataUrl: 'https://app.example.com/blob/7' }]
    );

    expect(wrapper.find('video').exists()).toBe(false);
    expect(wrapper.find('a').attributes('href')).toBe(
      'https://cdn.example.com/creative.mp4'
    );
  });

  it('renders image referrals as an external preview with no video element', () => {
    const wrapper = mountReferral({
      mediaType: 'image',
      imageUrl: 'https://cdn.example.com/image.jpg',
      headline: 'Image ad',
      sourceUrl: 'https://example.com/landing',
    });

    expect(wrapper.find('video').exists()).toBe(false);
    expect(wrapper.find('img').attributes('src')).toBe(
      'https://cdn.example.com/image.jpg'
    );
    const link = wrapper.find('a');
    expect(link.exists()).toBe(true);
    expect(link.attributes('href')).toBe('https://example.com/landing');
  });

  it('handles an absent video URL without attempting inline playback', () => {
    const wrapper = mountReferral({
      mediaType: 'video',
      thumbnailUrl: 'https://cdn.example.com/thumb.jpg',
      headline: 'No creative',
      sourceUrl: 'https://example.com/landing',
    });

    expect(wrapper.find('video').exists()).toBe(false);
    expect(wrapper.find('a').attributes('href')).toBe(
      'https://example.com/landing'
    );
  });

  it('rejects a relative URL rather than resolving it against the page origin', () => {
    const wrapper = mountReferral({
      mediaType: 'video',
      videoUrl: '/local/creative.mp4',
      sourceUrl: '../landing',
      headline: 'Relative ad',
    });

    // Relative paths are not absolute http(s) destinations, so nothing is
    // treated as an external link (and there is no stored attachment to play).
    expect(wrapper.find('video').exists()).toBe(false);
    expect(wrapper.find('a').exists()).toBe(false);
  });

  it('never emits an unsafe video URL as an external action', () => {
    const wrapper = mountReferral({
      mediaType: 'video',
      // eslint-disable-next-line no-script-url
      videoUrl: 'javascript:alert(1)',
      headline: 'Unsafe ad',
    });

    expect(wrapper.find('video').exists()).toBe(false);
    // No safe destination exists, so no link is rendered.
    expect(wrapper.find('a').exists()).toBe(false);
  });
});
