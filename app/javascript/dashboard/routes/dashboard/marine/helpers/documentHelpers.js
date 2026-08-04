// Framework-free helpers for the Marine documents UI. Extracted so the blocker
// behaviors (local SOP file validation, active-work detection, and poll backoff) can be
// unit-tested directly without mounting the full page/dialog.

// Mirrors the backend contract (Marine::Document): PDF/JPEG/PNG up to 2 MiB. Backend
// magic-byte validation stays authoritative; these are client-side guards only.
export const SOP_MAX_BYTES = 2 * 1024 * 1024;
export const SOP_ACCEPT_TYPES = ['application/pdf', 'image/jpeg', 'image/png'];
export const SOP_ACCEPT_HINT =
  '.pdf,.jpg,.jpeg,.png,application/pdf,image/jpeg,image/png';

// Validates a locally-selected SOP file. Returns { valid, errorKey } where errorKey is
// an i18n key to surface (null when valid, or when no file was chosen at all). Rejects
// unsupported types, zero-byte files, and anything over the size cap.
export const validateSopFile = file => {
  if (!file) return { valid: false, errorKey: null };
  if (!SOP_ACCEPT_TYPES.includes(file.type)) {
    return {
      valid: false,
      errorKey: 'MARINE_AI.DOCUMENTS.FORM.FILE.INVALID_TYPE',
    };
  }
  if (file.size === 0) {
    return { valid: false, errorKey: 'MARINE_AI.DOCUMENTS.FORM.FILE.EMPTY' };
  }
  if (file.size > SOP_MAX_BYTES) {
    return {
      valid: false,
      errorKey: 'MARINE_AI.DOCUMENTS.FORM.FILE.TOO_LARGE',
    };
  }
  return { valid: true, errorKey: null };
};

// SOP extraction/OCR then indexing can outlast a single refresh. A document is "active"
// (worth polling) while it is syncing, or an SOP whose indexing has not yet reached a
// terminal state.
export const ACTIVE_INDEXING_STATES = ['pending', 'embedding_pending'];

export const isDocumentActive = document => {
  if (!document) return false;
  if (document.sync_status === 'syncing') return true;
  if (
    document.source_kind === 'sop_document' &&
    document.sync_status === 'synced'
  ) {
    return ACTIVE_INDEXING_STATES.includes(document.metadata?.indexing_status);
  }
  return false;
};

export const hasActiveWork = documents =>
  Array.isArray(documents) && documents.some(isDocumentActive);

// Poll cadence + exponential backoff for transient GET failures. Backoff is capped so
// polling never permanently stops while there is active work, but a failing endpoint is
// not hammered at the base interval.
export const POLL_INTERVAL = 3000;
export const POLL_BACKOFF_MAX = 24000;

export const nextPollDelay = (
  currentDelay,
  base = POLL_INTERVAL,
  max = POLL_BACKOFF_MAX
) => Math.min(Math.max(currentDelay || base, base) * 2, max);
