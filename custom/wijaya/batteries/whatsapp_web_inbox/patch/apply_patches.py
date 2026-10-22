#!/usr/bin/env python3
"""Battery-owned, deterministic, idempotent, context-safe patch applicator for the
whatsapp_web_inbox core hook blocks.

The battery keeps all business logic under custom/wijaya/batteries/whatsapp_web_inbox.
The only things it needs inside core files are a handful of minimal, exactly-named
WIJAYA_CUSTOM marker blocks. After an upstream pull those blocks can vanish; this script
reattaches every missing block at its exact anchor without ever reformatting or rewriting
the surrounding upstream code.

Guarantees:
  * Idempotent  — a block already present (byte-for-byte) is left untouched; a clean run
                  reinserts all blocks; a partially-patched file gets only its missing
                  blocks back. Running twice produces no diff.
  * Context-safe — each block is inserted immediately after an exact, line-aligned anchor
                  that must occur EXACTLY once. If an anchor is absent or ambiguous the
                  run fails loudly, naming the file and the extension point, and writes
                  NOTHING (all files are computed in memory first; writes happen only if
                  every file succeeds).
  * Count-checked — after applying, each file must contain exactly the expected number of
                  START and END markers for the feature.

Block definitions live in the sibling blocks.json (generated from the known-good tree and
round-trip verified). A --root override lets tests drive the applicator against temporary
fixtures without touching the real repo.
"""
import argparse
import json
import os
import re
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", "..", "..", ".."))
DEFAULT_BLOCKS = os.path.join(SCRIPT_DIR, "blocks.json")


class PatchError(Exception):
    pass


def line_aligned_occurrences(buf, needle):
    """Indices where `needle` occurs starting at a line boundary (SOF or after \\n)."""
    idxs, start = [], 0
    while True:
        i = buf.find(needle, start)
        if i < 0:
            break
        if i == 0 or buf[i - 1] == "\n":
            idxs.append(i)
        start = i + 1
    return idxs


def marker_counts(buf, feature):
    start_re = re.compile(r"WIJAYA_CUSTOM_START " + re.escape(feature) + r"\b")
    end_re = re.compile(r"WIJAYA_CUSTOM_END " + re.escape(feature) + r"\b")
    return len(start_re.findall(buf)), len(end_re.findall(buf))


def compute_file(root, feature, spec):
    """Return (rel_path, new_text, original_text, inserted_count). Raises PatchError."""
    rel = spec["path"]
    path = os.path.join(root, rel)
    try:
        with open(path, encoding="utf-8") as fh:
            original = fh.read()
    except FileNotFoundError as exc:
        raise PatchError(f"{rel}: core file not found (cannot reattach {feature} hooks)") from exc

    buf = original
    inserted = 0
    for ordinal, blk in enumerate(spec["blocks"], start=1):
        block_text, anchor = blk["block"], blk["anchor"]
        if block_text in buf:
            continue  # already present — leave byte-for-byte untouched
        occ = line_aligned_occurrences(buf, anchor)
        label = block_text.strip().splitlines()[1] if len(block_text.splitlines()) > 1 else block_text
        if len(occ) == 0:
            raise PatchError(
                f"{rel}: anchor for {feature} block #{ordinal} is ABSENT — upstream context "
                f"changed at extension point [{label.strip()}]. Refusing to guess; fix the anchor."
            )
        if len(occ) > 1:
            raise PatchError(
                f"{rel}: anchor for {feature} block #{ordinal} is AMBIGUOUS ({len(occ)} matches) "
                f"at extension point [{label.strip()}]. Refusing to insert."
            )
        at = occ[0] + len(anchor)
        buf = buf[:at] + block_text + buf[at:]
        inserted += 1

    starts, ends = marker_counts(buf, feature)
    expected = spec["expected_blocks"]
    if starts != expected or ends != expected:
        raise PatchError(
            f"{rel}: expected {expected} {feature} START/END markers but found "
            f"{starts}/{ends} after processing — possible duplicate or tampered block."
        )
    return rel, buf, original, inserted


def atomic_write(root, rel, text):
    path = os.path.join(root, rel)
    directory = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".wijaya_patch_")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def run(root, blocks_path, check_only):
    with open(blocks_path, encoding="utf-8") as fh:
        spec = json.load(fh)
    feature = spec["feature"]

    # Phase 1: compute every file in memory. Any failure aborts with no writes.
    computed, errors = [], []
    for file_spec in spec["files"]:
        try:
            computed.append(compute_file(root, feature, file_spec))
        except PatchError as exc:
            errors.append(str(exc))

    if errors:
        for msg in errors:
            print(f"[whatsapp_web_inbox patch] ERROR: {msg}", file=sys.stderr)
        return 1

    if check_only:
        missing = [(rel, ins) for (rel, _new, _orig, ins) in computed if ins > 0]
        if missing:
            for rel, ins in missing:
                print(f"[whatsapp_web_inbox patch] MISSING: {rel} is missing {ins} hook block(s)",
                      file=sys.stderr)
            return 1
        print(f"[whatsapp_web_inbox patch] check OK: all {feature} hook blocks present")
        return 0

    # Phase 2: write only the files that actually changed.
    changed = 0
    for rel, new_text, original, inserted in computed:
        if new_text != original:
            atomic_write(root, rel, new_text)
            changed += 1
            print(f"[whatsapp_web_inbox patch] reattached {inserted} block(s) -> {rel}")
    if changed == 0:
        print(f"[whatsapp_web_inbox patch] apply OK: all {feature} hook blocks already present")
    else:
        print(f"[whatsapp_web_inbox patch] apply OK: updated {changed} file(s)")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Apply whatsapp_web_inbox core hook blocks.")
    parser.add_argument("--root", default=DEFAULT_ROOT, help="repo root (override for fixtures)")
    parser.add_argument("--blocks", default=DEFAULT_BLOCKS, help="path to blocks.json")
    parser.add_argument("--check", action="store_true",
                        help="report missing/ambiguous blocks without writing")
    args = parser.parse_args(argv)
    try:
        return run(args.root, args.blocks, args.check)
    except PatchError as exc:
        print(f"[whatsapp_web_inbox patch] ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
