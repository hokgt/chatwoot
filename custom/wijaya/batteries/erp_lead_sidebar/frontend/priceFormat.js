// WIJAYA_CUSTOM_START erp_lead_sidebar
// Indonesian whole-number price display helpers for the Product Requirement
// create dialog. The UI shows dot grouping (50000 -> "50.000", 1000000 ->
// "1.000.000"), but ERP is only ever sent the raw digits (50000). Kept as a
// standalone module so the grouping/stripping rules are directly unit-testable.

// Keep only the digit characters of an input, dropping grouping dots, spaces,
// signs, decimals and any other non-digit. Returns a raw digit string ('' when
// there are no digits), so a negative or formatted paste can never survive.
export const stripToDigits = value => String(value ?? '').replace(/\D/g, '');

// Group a raw digit string with '.' every three digits from the right. A blank
// input stays blank; leading zeros are normalized away except a lone '0'.
export const formatIdGrouping = value => {
  const digits = stripToDigits(value);
  if (!digits) return '';
  const normalized = digits.replace(/^0+(?=\d)/, '');
  return normalized.replace(/\B(?=(\d{3})+(?!\d))/g, '.');
};

// The raw numeric string to send to ERP (digits only, leading zeros trimmed).
// '' when empty so the caller can omit the price entirely.
export const toRawPrice = value => {
  const digits = stripToDigits(value);
  if (!digits) return '';
  return digits.replace(/^0+(?=\d)/, '');
};

// Validate a price input under Indonesian whole-number rules and never silently
// change an invalid value into a different number. Digits and grouping dots are
// the only accepted characters (so "50.000" is fine); a minus sign, a comma, a
// decimal, letters or any other symbol are REJECTED rather than coerced (so
// "-500", "12,5" and "abc50" become an error, not 500 / 125 / 50). Blank is
// allowed (the price is optional). Returns
//   { valid, display, raw, error }
// where `display` is the grouped display value for a valid input (or the raw
// untouched text for an invalid one, so the field is never rewritten) and `raw`
// is the digits-only string to send to ERP ('' when blank/invalid).
export const parsePriceInput = value => {
  const text = String(value ?? '').trim();
  if (!text) return { valid: true, display: '', raw: '', error: '' };

  const INVALID = {
    valid: false,
    display: text,
    raw: '',
    error: 'Product Price must be a whole number (digits only, e.g. 50.000).',
  };
  // Anything other than digits and grouping dots (minus, comma, decimal,
  // letters, spaces, symbols) is invalid — do not strip it away silently.
  if (/[^\d.]/.test(text)) return INVALID;

  const digits = stripToDigits(text);
  if (!digits) return INVALID; // dots only, no digits

  return {
    valid: true,
    display: formatIdGrouping(digits),
    raw: toRawPrice(digits),
    error: '',
  };
};
// WIJAYA_CUSTOM_END erp_lead_sidebar
