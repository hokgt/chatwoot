#!/usr/bin/env python3
"""Self-contained tests for the wecom_channel applicator. Runs against a throwaway
copy of the real tree so it never mutates the working copy:

  * idempotency   — on the already-patched tree, --check passes and apply writes nothing
  * round-trip    — stripping every wecom_channel block then re-applying reproduces the
                    original files byte-for-byte (proves anchors are correct & unique)
  * ambiguity     — a duplicated anchor makes the run fail loudly and write nothing

Run:  python3 custom/wijaya/batteries/wecom_channel/patch/test_apply_patches.py
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", ".."))
APPLICATOR = os.path.join(HERE, "apply_patches.py")
BLOCKS = json.load(open(os.path.join(HERE, "blocks.json"), encoding="utf-8"))
FILES = [f["path"] for f in BLOCKS["files"]]
STRIP = re.compile(
    r"[ \t]*[^\n]*WIJAYA_CUSTOM_START wecom_channel.*?WIJAYA_CUSTOM_END wecom_channel[^\n]*\n",
    re.S,
)


def _mirror_tree():
    tmp = tempfile.mkdtemp(prefix="wecom_patch_test_")
    for rel in FILES:
        dst = os.path.join(tmp, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(os.path.join(ROOT, rel), dst)
    return tmp


def _apply(root, extra=None):
    return subprocess.run(
        [sys.executable, APPLICATOR, "--root", root] + (extra or []),
        capture_output=True, text=True,
    )


class ApplicatorTest(unittest.TestCase):
    def test_check_passes_on_patched_tree(self):
        self.assertEqual(_apply(ROOT, ["--check"]).returncode, 0)

    def test_round_trip_reconstructs_every_file(self):
        tmp = _mirror_tree()
        try:
            for rel in FILES:
                path = os.path.join(tmp, rel)
                stripped = STRIP.sub("", open(path, encoding="utf-8").read())
                self.assertNotIn("wecom_channel", stripped, rel)
                open(path, "w", encoding="utf-8").write(stripped)
            self.assertEqual(_apply(tmp).returncode, 0)
            for rel in FILES:
                self.assertEqual(
                    open(os.path.join(ROOT, rel), encoding="utf-8").read(),
                    open(os.path.join(tmp, rel), encoding="utf-8").read(),
                    f"{rel} not reconstructed",
                )
            # second apply is a no-op
            second = _apply(tmp)
            self.assertEqual(second.returncode, 0)
            self.assertIn("already present", second.stdout)
        finally:
            shutil.rmtree(tmp)

    def test_ambiguous_anchor_fails_without_writing(self):
        tmp = _mirror_tree()
        try:
            # Duplicate the first file's content so its anchor matches twice.
            rel = FILES[0]
            path = os.path.join(tmp, rel)
            original = open(path, encoding="utf-8").read()
            stripped = STRIP.sub("", original)
            open(path, "w", encoding="utf-8").write(stripped + stripped)
            result = _apply(tmp)
            self.assertEqual(result.returncode, 1)
            self.assertIn("AMBIGUOUS", result.stderr)
            self.assertEqual(open(path, encoding="utf-8").read(), stripped + stripped)
        finally:
            shutil.rmtree(tmp)


if __name__ == "__main__":
    unittest.main(verbosity=2)
