#!/bin/sh
#
# Idempotent installer for the Marine AI SOP processing runtime dependencies.
# ==========================================================================
#
# Adds ONLY the Poppler PDF utilities and Tesseract OCR engine (with English and
# Indonesian language data) on top of the immutable Chatwoot application image
# (ruby:3.4.x-alpine). It installs nothing else and changes no application code.
#
# Alpine (apk) package names verified for the alpine3.21 base:
#   * poppler-utils          -> provides pdfinfo, pdftotext, pdftoppm
#   * tesseract-ocr          -> provides the `tesseract` binary
#   * tesseract-ocr-data-eng -> English OCR trained data (eng)
#   * tesseract-ocr-data-ind -> Indonesian OCR trained data (ind)
#
# `apk add` is naturally idempotent (already-present packages are a no-op), and the
# script re-verifies every required binary and OCR language on each run, so it is safe
# to invoke repeatedly from a Docker build or a manual bootstrap.
set -eu

PACKAGES="poppler-utils tesseract-ocr tesseract-ocr-data-eng tesseract-ocr-data-ind"

echo "[marine:sop] installing SOP processing dependencies: ${PACKAGES}"
apk add --no-cache ${PACKAGES}

echo "[marine:sop] verifying required binaries"
for bin in pdfinfo pdftotext pdftoppm tesseract; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    echo "[marine:sop] ERROR: required binary '${bin}' is not available after install" >&2
    exit 1
  fi
done

echo "[marine:sop] verifying Tesseract OCR languages (eng, ind)"
LANGS="$(tesseract --list-langs 2>/dev/null || true)"
for lang in eng ind; do
  if ! printf '%s\n' "${LANGS}" | grep -qx "${lang}"; then
    echo "[marine:sop] ERROR: Tesseract language data '${lang}' is missing" >&2
    exit 1
  fi
done

echo "[marine:sop] SOP processing dependencies installed and verified"
