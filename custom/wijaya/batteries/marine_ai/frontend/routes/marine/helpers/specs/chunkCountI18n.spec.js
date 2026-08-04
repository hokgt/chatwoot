import { createI18n } from 'vue-i18n';
import marine from '@wijaya/marine_ai/frontend/i18n/marine.json';

// Proves the SOP chunk-count label pluralizes with this repo's real vue-i18n build and
// the actual string shipped in marine.json — i.e. that the fix uses supported syntax and
// the MarineDocumentCard `t(key, { count }, count)` call resolves singular vs. plural.
describe('SOP chunk-count pluralization', () => {
  const i18n = createI18n({
    legacy: false,
    locale: 'en',
    messages: { en: marine },
  });
  const label = count =>
    i18n.global.t('MARINE_AI.DOCUMENTS.SOP.CHUNK_COUNT', { count }, count);

  it('uses the singular form for exactly one chunk', () => {
    expect(label(1)).toBe('1 chunk indexed');
  });

  it('uses the plural form for multiple chunks', () => {
    expect(label(7)).toBe('7 chunks indexed');
  });

  it('uses the plural form for zero chunks', () => {
    expect(label(0)).toBe('0 chunks indexed');
  });
});
