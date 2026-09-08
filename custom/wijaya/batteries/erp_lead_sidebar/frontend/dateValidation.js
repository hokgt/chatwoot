// WIJAYA_CUSTOM_START erp_lead_sidebar
// Strict YYYY-MM-DD real-calendar validation shared by the Lead Activity form.
// Mirrors the backend Date.iso8601 round-trip (LeadActivityPayloadBuilder): the
// parsed year/month/day must survive a UTC round-trip unchanged, so impossible
// dates (e.g. 2026-02-30) are rejected with no timezone drift. Extracted into its
// own module so it can be unit-tested directly (a browser <input type="date">
// never surfaces an impossible date, and jsdom sanitizes one away entirely).
export const isRealISODate = value => {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return false;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const date = new Date(Date.UTC(year, month - 1, day));
  return (
    date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day
  );
};
// WIJAYA_CUSTOM_END erp_lead_sidebar
