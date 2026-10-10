import { describe, it, expect } from 'vitest';
import {
  stripToDigits,
  formatIdGrouping,
  toRawPrice,
  parsePriceInput,
} from '@wijaya/erp_lead_sidebar/frontend/priceFormat';

describe('priceFormat', () => {
  describe('formatIdGrouping', () => {
    it('groups Indonesian whole numbers with dots', () => {
      expect(formatIdGrouping('50000')).toBe('50.000');
      expect(formatIdGrouping('1000000')).toBe('1.000.000');
      expect(formatIdGrouping('999')).toBe('999');
    });

    it('reformats an already-grouped or messy input', () => {
      expect(formatIdGrouping('50.000')).toBe('50.000');
      expect(formatIdGrouping('1.000.00')).toBe('100.000');
    });

    it('drops non-digits and handles empty input', () => {
      expect(formatIdGrouping('')).toBe('');
      expect(formatIdGrouping('abc')).toBe('');
      expect(formatIdGrouping('-500')).toBe('500');
    });
  });

  describe('stripToDigits / toRawPrice', () => {
    it('keeps only digits and never sends a formatted string', () => {
      expect(stripToDigits('50.000')).toBe('50000');
      expect(toRawPrice('50.000')).toBe('50000');
      expect(toRawPrice('1.000.000')).toBe('1000000');
    });

    it('returns empty for blank input so the price can be omitted', () => {
      expect(toRawPrice('')).toBe('');
      expect(toRawPrice('   ')).toBe('');
    });

    it('trims leading zeros', () => {
      expect(toRawPrice('000500')).toBe('500');
    });
  });

  describe('parsePriceInput', () => {
    it('accepts blank as valid with an empty raw (price is optional)', () => {
      expect(parsePriceInput('')).toEqual({
        valid: true,
        display: '',
        raw: '',
        error: '',
      });
      expect(parsePriceInput('   ')).toMatchObject({ valid: true, raw: '' });
    });

    it('accepts a plain or grouped Indonesian whole number', () => {
      expect(parsePriceInput('50000')).toMatchObject({
        valid: true,
        display: '50.000',
        raw: '50000',
      });
      expect(parsePriceInput('50.000')).toMatchObject({
        valid: true,
        display: '50.000',
        raw: '50000',
      });
    });

    it('rejects a negative value without coercing it into a positive number', () => {
      const result = parsePriceInput('-500');
      expect(result.valid).toBe(false);
      expect(result.raw).toBe('');
      expect(result.display).toBe('-500'); // left untouched, not rewritten to 500
      expect(result.error).toBeTruthy();
    });

    it('rejects a comma/decimal value rather than dropping the separator', () => {
      expect(parsePriceInput('12,5')).toMatchObject({ valid: false, raw: '' });
      expect(parsePriceInput('12.5.5')).toMatchObject({ valid: true }); // dots only -> digits
      expect(parsePriceInput('1,000.50')).toMatchObject({
        valid: false,
        raw: '',
      });
    });

    it('rejects alphabetic and mixed input rather than extracting stray digits', () => {
      expect(parsePriceInput('abc50')).toMatchObject({
        valid: false,
        raw: '',
        display: 'abc50',
      });
      expect(parsePriceInput('50k')).toMatchObject({ valid: false, raw: '' });
    });
  });
});
