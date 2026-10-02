#!/usr/bin/env python3
"""Tests for the whatsapp_web_inbox patch applicator.

Fixtures are built in a temporary directory from the real (known-good) core files, so the
applicator is exercised end-to-end WITHOUT ever touching the actual repo. Run with:

    python3 custom/wijaya/batteries/whatsapp_web_inbox/patch/test_apply_patches.py
"""
import importlib.util
import json
import os
import re
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", ".."))
BLOCKS_PATH = os.path.join(HERE, "blocks.json")

_spec = importlib.util.spec_from_file_location("apply_patches", os.path.join(HERE, "apply_patches.py"))
applicator = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(applicator)

with open(BLOCKS_PATH, encoding="utf-8") as _fh:
    BLOCKS = json.load(_fh)
FEATURE = BLOCKS["feature"]
START_RE = re.compile(r"^\s*(?://|<!--)\s*WIJAYA_CUSTOM_START " + re.escape(FEATURE) + r"\b")
END_RE = re.compile(r"^\s*(?://|<!--)\s*WIJAYA_CUSTOM_END " + re.escape(FEATURE) + r"\b")


def strip_feature(text):
    lines = text.splitlines(keepends=True)
    out, i = [], 0
    while i < len(lines):
        if START_RE.match(lines[i]):
            while i < len(lines) and not END_RE.match(lines[i]):
                i += 1
            i += 1  # skip END
        else:
            out.append(lines[i])
            i += 1
    return "".join(out)


class PatchApplicatorTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="wijaya_patch_test_")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        # Source of truth: the real patched files.
        self.patched = {}
        for fspec in BLOCKS["files"]:
            with open(os.path.join(REPO_ROOT, fspec["path"]), encoding="utf-8") as fh:
                self.patched[fspec["path"]] = fh.read()

    # --- fixture helpers -------------------------------------------------
    def materialize(self, contents):
        """Write {rel: text} into a fresh root inside the temp dir; return the root."""
        root = tempfile.mkdtemp(dir=self.tmp)
        for rel, text in contents.items():
            path = os.path.join(root, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)
        return root

    def read_all(self, root, rels):
        out = {}
        for rel in rels:
            with open(os.path.join(root, rel), encoding="utf-8") as fh:
                out[rel] = fh.read()
        return out

    def apply(self, root, check=False):
        return applicator.run(root, BLOCKS_PATH, check)

    # --- required scenarios ----------------------------------------------
    def test_clean_fixture_applies_all_blocks_byte_identical(self):
        clean = {rel: strip_feature(text) for rel, text in self.patched.items()}
        # A clean fixture really is missing the markers.
        for rel, text in clean.items():
            self.assertNotIn(f"WIJAYA_CUSTOM_START {FEATURE}", text)
        root = self.materialize(clean)
        self.assertEqual(self.apply(root), 0)
        result = self.read_all(root, self.patched.keys())
        self.assertEqual(result, self.patched)

    def test_second_run_is_byte_identical(self):
        clean = {rel: strip_feature(text) for rel, text in self.patched.items()}
        root = self.materialize(clean)
        self.assertEqual(self.apply(root), 0)
        first = self.read_all(root, self.patched.keys())
        self.assertEqual(self.apply(root), 0)
        second = self.read_all(root, self.patched.keys())
        self.assertEqual(first, second)
        self.assertEqual(second, self.patched)

    def test_already_patched_fixture_is_untouched(self):
        root = self.materialize(self.patched)
        self.assertEqual(self.apply(root), 0)
        self.assertEqual(self.read_all(root, self.patched.keys()), self.patched)

    def test_only_missing_block_is_reinserted(self):
        # Remove exactly one block from Settings.vue; everything else stays patched.
        target = "app/javascript/dashboard/routes/dashboard/settings/inbox/Settings.vue"
        victim = BLOCKS["files"][-1]["blocks"][2]["block"]  # the tabs-building block
        self.assertIn(victim, self.patched[target])
        contents = dict(self.patched)
        contents[target] = self.patched[target].replace(victim, "", 1)
        root = self.materialize(contents)
        self.assertEqual(self.apply(root), 0)
        result = self.read_all(root, self.patched.keys())
        self.assertEqual(result, self.patched)

    def test_absent_anchor_fails_with_no_partial_write(self):
        target = "app/javascript/dashboard/components/widgets/ChannelItem.vue"
        block0 = BLOCKS["files"][0]["blocks"][0]
        contents = dict(self.patched)
        broken = self.patched[target].replace(block0["block"], "", 1)  # remove the block
        broken = broken.replace(block0["anchor"].rstrip("\n"), "// upstream moved this line")
        contents[target] = broken
        root = self.materialize(contents)
        before = self.read_all(root, self.patched.keys())
        self.assertEqual(self.apply(root), 1)
        after = self.read_all(root, self.patched.keys())
        self.assertEqual(before, after)  # nothing written anywhere

    def test_ambiguous_anchor_fails_with_no_partial_write(self):
        target = "app/javascript/dashboard/components/widgets/ChannelItem.vue"
        block0 = BLOCKS["files"][0]["blocks"][0]
        contents = dict(self.patched)
        removed = self.patched[target].replace(block0["block"], "", 1)
        # Duplicate the anchor line so it now matches twice.
        duplicated = removed.replace(block0["anchor"], block0["anchor"] + block0["anchor"], 1)
        contents[target] = duplicated
        root = self.materialize(contents)
        before = self.read_all(root, self.patched.keys())
        self.assertEqual(self.apply(root), 1)
        self.assertEqual(before, self.read_all(root, self.patched.keys()))

    def test_duplicate_block_trips_exact_count_check(self):
        target = "app/javascript/dashboard/components/widgets/ChannelItem.vue"
        block0 = BLOCKS["files"][0]["blocks"][0]["block"]
        contents = dict(self.patched)
        # Two copies of the same block -> START/END count exceeds the expected value.
        contents[target] = self.patched[target].replace(block0, block0 + block0, 1)
        root = self.materialize(contents)
        before = self.read_all(root, self.patched.keys())
        self.assertEqual(self.apply(root), 1)
        self.assertEqual(before, self.read_all(root, self.patched.keys()))

    def test_check_mode_detects_missing_and_passes_when_present(self):
        clean = {rel: strip_feature(text) for rel, text in self.patched.items()}
        root = self.materialize(clean)
        self.assertEqual(self.apply(root, check=True), 1)  # missing -> non-zero
        self.assertEqual(self.read_all(root, self.patched.keys()), clean)  # check never writes
        self.assertEqual(self.apply(root), 0)  # now apply
        self.assertEqual(self.apply(root, check=True), 0)  # present -> zero

    def test_expected_block_counts_match_live_files(self):
        expected = {
            "app/javascript/dashboard/components/widgets/ChannelItem.vue": 2,
            "app/javascript/dashboard/i18n/locale/en/index.js": 2,
            "app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelFactory.vue": 2,
            "app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelList.vue": 2,
            "app/javascript/dashboard/routes/dashboard/settings/inbox/Settings.vue": 5,
        }
        by_path = {f["path"]: f for f in BLOCKS["files"]}
        self.assertEqual(set(by_path), set(expected))
        for rel, count in expected.items():
            self.assertEqual(by_path[rel]["expected_blocks"], count)
            self.assertEqual(len(by_path[rel]["blocks"]), count)
            starts = self.patched[rel].count(f"WIJAYA_CUSTOM_START {FEATURE}")
            self.assertEqual(starts, count)


if __name__ == "__main__":
    unittest.main(verbosity=2)
