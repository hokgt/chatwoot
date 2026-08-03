#!/bin/sh
#
# Idempotent installer for the Marine AI SOP processing runtime dependencies.
# ==========================================================================
#
# Adds ONLY the Poppler PDF utilities, the Tesseract OCR engine (with English and
# Indonesian language data), and su-exec on top of the immutable Chatwoot application
# image (ruby:3.4.x-alpine). It installs nothing else and changes no application code.
#
# Alpine (apk) package names verified for the alpine3.21 base:
#   * poppler-utils          -> provides pdfinfo, pdftotext, pdftoppm
#   * tesseract-ocr          -> provides the `tesseract` binary
#   * tesseract-ocr-data-eng -> English OCR trained data (eng)
#   * tesseract-ocr-data-ind -> Indonesian OCR trained data (ind)
#   * su-exec                -> minimal privilege-drop re-exec used by CommandRunner to
#                               run every OCR/Poppler subprocess as the locked marine_sop
#                               account (retaining the parent-applied RLIMITs)
#
# It also creates a LOCKED, unprivileged `marine_sop` system group and user. CommandRunner
# drops every external command to this account (via su-exec) whenever the app runs as root
# in a derived image, so a hostile document is parsed with no ambient privilege. The account
# is a system user with no valid login shell, no home directory, and no password (locked).
#
# `apk add` is naturally idempotent (already-present packages are a no-op), the group/user
# creation is guarded so it is a no-op when they already exist, and the script re-verifies
# every required binary, OCR language, and the account on each run, so it is safe to invoke
# repeatedly from a Docker build or a manual bootstrap.
set -eu

PACKAGES="poppler-utils tesseract-ocr tesseract-ocr-data-eng tesseract-ocr-data-ind su-exec"

# Locked, unprivileged account external OCR/Poppler commands are dropped to.
SOP_GROUP="marine_sop"
SOP_USER="marine_sop"

echo "[marine:sop] installing SOP processing dependencies: ${PACKAGES}"
apk add --no-cache ${PACKAGES}

echo "[marine:sop] ensuring locked service group '${SOP_GROUP}'"
if ! getent group "${SOP_GROUP}" >/dev/null 2>&1; then
  addgroup -S "${SOP_GROUP}"
fi

echo "[marine:sop] ensuring locked service user '${SOP_USER}'"
if ! id "${SOP_USER}" >/dev/null 2>&1; then
  # -S system account, -D no password (locked), -H no home dir, -s nologin shell,
  # -G places it ONLY in the marine_sop group (no supplementary/privileged groups).
  adduser -S -D -H -s /sbin/nologin -G "${SOP_GROUP}" "${SOP_USER}"
fi

echo "[marine:sop] verifying required binaries"
for bin in pdfinfo pdftotext pdftoppm tesseract su-exec; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "[marine:sop] ERROR: required binary '${bin}' is not available after install" >&2
    exit 1
  fi
done

echo "[marine:sop] verifying locked service account '${SOP_USER}'"
if ! id "${SOP_USER}" >/dev/null 2>&1; then
  echo "[marine:sop] ERROR: service user '${SOP_USER}' is not present after install" >&2
  exit 1
fi

echo "[marine:sop] verifying Tesseract OCR languages (eng, ind)"
LANGS="$(tesseract --list-langs 2>/dev/null || true)"
for lang in eng ind; do
  if ! printf '%s\n' "${LANGS}" | grep -qx "${lang}"; then
    echo "[marine:sop] ERROR: Tesseract language data '${lang}' is missing" >&2
    exit 1
  fi
done

echo "[marine:sop] SOP processing dependencies installed and verified"
