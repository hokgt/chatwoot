import {
  validateSopFile,
  isDocumentActive,
  hasActiveWork,
  nextPollDelay,
  SOP_MAX_BYTES,
  POLL_INTERVAL,
  POLL_BACKOFF_MAX,
} from '../documentHelpers';

const fakeFile = (type, size) => ({ type, size });

describe('documentHelpers', () => {
  describe('validateSopFile', () => {
    it('accepts an in-spec PDF/JPEG/PNG under the size cap', () => {
      expect(validateSopFile(fakeFile('application/pdf', 1024))).toEqual({
        valid: true,
        errorKey: null,
      });
      expect(validateSopFile(fakeFile('image/jpeg', 1024)).valid).toBe(true);
      expect(validateSopFile(fakeFile('image/png', 1024)).valid).toBe(true);
    });

    it('rejects an unsupported type', () => {
      expect(validateSopFile(fakeFile('text/plain', 10))).toEqual({
        valid: false,
        errorKey: 'MARINE_AI.DOCUMENTS.FORM.FILE.INVALID_TYPE',
      });
    });

    it('rejects a zero-byte file even with a valid type', () => {
      expect(validateSopFile(fakeFile('application/pdf', 0))).toEqual({
        valid: false,
        errorKey: 'MARINE_AI.DOCUMENTS.FORM.FILE.EMPTY',
      });
    });

    it('rejects a file over the 2 MiB cap', () => {
      expect(
        validateSopFile(fakeFile('application/pdf', SOP_MAX_BYTES + 1))
      ).toEqual({
        valid: false,
        errorKey: 'MARINE_AI.DOCUMENTS.FORM.FILE.TOO_LARGE',
      });
    });

    it('treats no file as invalid but with no error to surface', () => {
      expect(validateSopFile(null)).toEqual({ valid: false, errorKey: null });
      expect(validateSopFile(undefined)).toEqual({
        valid: false,
        errorKey: null,
      });
    });
  });

  describe('isDocumentActive', () => {
    it('is active while syncing regardless of source kind', () => {
      expect(isDocumentActive({ sync_status: 'syncing' })).toBe(true);
    });

    it('is active for a synced SOP still indexing', () => {
      expect(
        isDocumentActive({
          source_kind: 'sop_document',
          sync_status: 'synced',
          metadata: { indexing_status: 'embedding_pending' },
        })
      ).toBe(true);
    });

    it('is not active for a fully indexed SOP', () => {
      expect(
        isDocumentActive({
          source_kind: 'sop_document',
          sync_status: 'synced',
          metadata: { indexing_status: 'indexed' },
        })
      ).toBe(false);
    });

    it('is not active for a synced website document', () => {
      expect(
        isDocumentActive({ source_kind: 'website', sync_status: 'synced' })
      ).toBe(false);
    });

    it('is not active for a nullish document', () => {
      expect(isDocumentActive(null)).toBe(false);
    });
  });

  describe('hasActiveWork', () => {
    it('is true when any document is active', () => {
      expect(
        hasActiveWork([
          { source_kind: 'website', sync_status: 'synced' },
          { sync_status: 'syncing' },
        ])
      ).toBe(true);
    });

    it('is false for an empty list or a non-array', () => {
      expect(hasActiveWork([])).toBe(false);
      expect(hasActiveWork(null)).toBe(false);
    });
  });

  describe('nextPollDelay', () => {
    it('doubles from the base and caps at the max', () => {
      let delay = POLL_INTERVAL;
      delay = nextPollDelay(delay);
      expect(delay).toBe(6000);
      delay = nextPollDelay(delay);
      expect(delay).toBe(12000);
      delay = nextPollDelay(delay);
      expect(delay).toBe(POLL_BACKOFF_MAX);
      delay = nextPollDelay(delay);
      expect(delay).toBe(POLL_BACKOFF_MAX);
    });

    it('never returns below the base interval', () => {
      expect(nextPollDelay(0)).toBe(6000);
    });
  });
});
