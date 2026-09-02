import { mount } from '@vue/test-utils';
import AdsReferral from './AdsReferral.vue';

const mountReferral = referral => mount(AdsReferral, { props: { referral } });

describe('AdsReferral', () => {
  it('plays a direct video referral inline without an enclosing external link', () => {
    const wrapper = mountReferral({
      mediaType: 'video',
      videoUrl: 'https://cdn.example.com/creative',
      thumbnailUrl: 'https://cdn.example.com/thumb.jpg',
      headline: 'Playable ad',
      sourceUrl: 'https://example.com/landing',
    });

    const video = wrapper.find('video');
    expect(video.exists()).toBe(true);
    expect(video.attributes('src')).toBe('https://cdn.example.com/creative');
    expect(video.attributes('controls')).toBeDefined();
    // The card must not be wrapped in a link while inline playback is active.
    expect(wrapper.find('a').exists()).toBe(false);
    expect(wrapper.find('img').exists()).toBe(false);
  });

  it('falls back to a thumbnail + external link when media fails to load', async () => {
    const wrapper = mountReferral({
      mediaType: 'video',
      videoUrl: 'https://cdn.example.com/creative.mp4',
      thumbnailUrl: 'https://cdn.example.com/thumb.jpg',
      headline: 'Playable ad',
      sourceUrl: 'https://example.com/landing',
    });

    await wrapper.find('video').trigger('error');

    expect(wrapper.find('video').exists()).toBe(false);
    expect(wrapper.find('img').attributes('src')).toBe(
      'https://cdn.example.com/thumb.jpg'
    );
    const link = wrapper.find('a');
    expect(link.exists()).toBe(true);
    // Video fallback preserves the prior behavior: videoUrl is the primary
    // external destination, ahead of sourceUrl.
    expect(link.attributes('href')).toBe(
      'https://cdn.example.com/creative.mp4'
    );
    expect(link.attributes('rel')).toBe('noopener noreferrer');
    expect(link.attributes('target')).toBe('_blank');
  });

  it('cannot keep a Facebook Reel/page URL as playable — media error reveals the external fallback pointing at the Reel', async () => {
    // A real CTWA payload carries both: source_url (the fb.me ad destination)
    // and video_url (the Reel/page). When inline playback fails the fallback
    // must still point at the video URL, not silently divert to source_url.
    const wrapper = mountReferral({
      mediaType: 'video',
      videoUrl: 'https://www.facebook.com/reel/1234567890',
      sourceUrl: 'https://fb.me/ad-destination',
      thumbnailUrl: 'https://cdn.example.com/thumb.jpg',
      headline: 'Reel ad',
    });

    // Classified as a video from media_type, so playback is attempted...
    expect(wrapper.find('video').exists()).toBe(true);
    expect(wrapper.find('a').exists()).toBe(false);

    // ...but the browser cannot decode a webpage as media, so it fails safely.
    await wrapper.find('video').trigger('error');

    expect(wrapper.find('video').exists()).toBe(false);
    const link = wrapper.find('a');
    expect(link.exists()).toBe(true);
    expect(link.attributes('href')).toBe(
      'https://www.facebook.com/reel/1234567890'
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
    // treated as playable media nor emitted as an external link.
    expect(wrapper.find('video').exists()).toBe(false);
    expect(wrapper.find('a').exists()).toBe(false);
  });

  it('never emits an unsafe video URL as media source or external action', () => {
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
