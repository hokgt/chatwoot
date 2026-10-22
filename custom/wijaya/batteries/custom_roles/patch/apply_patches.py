#!/usr/bin/env python3
"""Battery-owned, deterministic, idempotent, context-safe patch applicator for the
custom_roles_rbac Captain tasks_controller hook blocks.

Scope: ONLY app/controllers/api/v1/accounts/captain/tasks_controller.rb — the one
native core file the composer-task security fix touched. Business logic lives under
custom/wijaya/batteries/custom_roles (hooks.rb, follow_up_provenance.rb); the core
file carries only the four marker-wrapped blocks this applicator restores after an
upstream pull.

Guarantees (same contract as the whatsapp_web_inbox applicator):
  * Idempotent — a block already present byte-for-byte is left untouched; a clean
    run reinserts every missing block; running twice produces no diff.
  * Context-safe — every block is reinserted against an exact, line-aligned anchor
    that must occur EXACTLY once. An absent or ambiguous anchor fails loudly,
    naming the file and the extension point, and writes NOTHING (all patches are
    computed in memory first; a write happens only after every file validated).
  * Replaces-aware — the render_result block supersedes the exact upstream default
    follow_up_context assignment line; if that line is missing or changed the run
    fails instead of guessing.
  * Count-checked — after patching, the file must contain exactly the expected
    number of START and END markers for the feature, and each block exactly once,
    so a tampered or partial block fails loudly instead of duplicating.

Block definitions live in the sibling blocks.json (generated from the known-good
working tree and round-trip verified against pristine upstream). --root overrides
the repo root (tests drive temporary fixtures); --check verifies without writing.
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


def apply_blocks(content, spec, path, feature):
    """Return the fully patched content for one file, or raise PatchError."""
    for blk in spec["blocks"]:
        name, anchor, block = blk["name"], blk["anchor"], blk["block"]
        idxs = line_aligned_occurrences(content, anchor)
        if len(idxs) != 1:
            raise PatchError(
                "anchor for block %r occurs %d time(s), expected exactly 1, in %s"
                % (name, len(idxs), path)
            )
        at = idxs[0] + len(anchor)
        if content.startswith(block, at):
            if len(line_aligned_occurrences(content, block)) != 1:
                raise PatchError("block %r duplicated in %s" % (name, path))
            continue
        replaces = blk.get("replaces")
        if replaces:
            if content.startswith(replaces, at):
                content = content[:at] + block + content[at + len(replaces):]
                continue
            raise PatchError(
                "upstream default line for block %r missing or changed in %s"
                % (name, path)
            )
        # No replaces line: plain insertion right after the anchor. A tampered or
        # partial block still left in the file makes the marker-count validation
        # below fail loudly instead of silently duplicating provenance.
        content = content[:at] + block + content[at:]

    starts, ends = marker_counts(content, feature)
    expected = (spec["expected_start_markers"], spec["expected_end_markers"])
    if (starts, ends) != expected:
        raise PatchError(
            "marker count mismatch in %s: START=%d END=%d, expected %d/%d (tampered or partial block?)"
            % (path, starts, ends, expected[0], expected[1])
        )
    for blk in spec["blocks"]:
        if len(line_aligned_occurrences(content, blk["block"])) != 1:
            raise PatchError(
                "block %r not present exactly once after patching %s" % (blk["name"], path)
            )
    return content


def atomic_write(path, content):
    mode = os.stat(path).st_mode
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(content)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def run(root, blocks_path=DEFAULT_BLOCKS, check=False):
    """Apply every block of every spec file under `root`; returns a summary."""
    with open(blocks_path, encoding="utf-8") as handle:
        spec = json.load(handle)
    summary = {"applied": [], "noop": []}
    for file_spec in spec["files"]:
        rel = file_spec["path"]
        path = os.path.join(root, rel)
        if not os.path.isfile(path):
            raise PatchError("missing target file %s under root %s" % (rel, root))
        with open(path, encoding="utf-8") as handle:
            content = handle.read()
        patched = apply_blocks(content, file_spec, rel, spec["feature"])
        if patched == content:
            summary["noop"].append(rel)
            print("custom_roles_rbac hook blocks already present: %s" % rel)
        else:
            if check:
                raise PatchError(
                    "check mode: %s would be patched under root %s" % (rel, root)
                )
            atomic_write(path, patched)
            summary["applied"].append(rel)
            print("custom_roles_rbac hook blocks applied: %s" % rel)
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description="custom_roles_rbac block applicator")
    parser.add_argument("--root", default=DEFAULT_ROOT, help="repo root override (tests use temporary fixtures)")
    parser.add_argument("--check", action="store_true", help="verify only; never write; exit 1 if anything would change")
    args = parser.parse_args(argv)
    try:
        run(args.root, check=args.check)
    except PatchError as exc:
        print("custom_roles patch error: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())