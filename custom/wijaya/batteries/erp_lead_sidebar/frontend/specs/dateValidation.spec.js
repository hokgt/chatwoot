import { isRealISODate } from '@wijaya/erp_lead_sidebar/frontend/dateValidation';

// The Lead Activity form's date/follow_up_date validation must mirror the backend
// real-calendar check (Date.iso8601 round-trip), not a shape-only regex. These
// specs pin the impossible-date rejections a browser <input type="date"> would
// never even surface (and jsdom sanitizes away), which is why the helper is tested
// directly here.
describe('isRealISODate', () => {
  it('accepts real calendar dates', () => {
    expect(isRealISODate('2026-08-10')).toBe(true);
    expect(isRealISODate('2024-02-29')).toBe(true); // valid leap day
  });

  it('rejects impossible calendar dates', () => {
    expect(isRealISODate('2026-02-30')).toBe(false);
    expect(isRealISODate('2026-02-29')).toBe(false); // 2026 is not a leap year
    expect(isRealISODate('2026-04-31')).toBe(false);
    expect(isRealISODate('2026-13-01')).toBe(false);
    expect(isRealISODate('2026-00-10')).toBe(false);
    expect(isRealISODate('2026-08-00')).toBe(false);
  });

  it('rejects malformed or non-ISO shapes', () => {
    expect(isRealISODate('')).toBe(false);
    expect(isRealISODate('2026-8-10')).toBe(false);
    expect(isRealISODate('10/08/2026')).toBe(false);
    expect(isRealISODate('2026-08-10T00:00:00')).toBe(false);
    expect(isRealISODate(undefined)).toBe(false);
  });
});
