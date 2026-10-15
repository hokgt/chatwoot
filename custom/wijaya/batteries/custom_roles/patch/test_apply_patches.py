#!/usr/bin/env python3
"""Tests for the custom_roles_rbac Captain tasks_controller patch applicator.

The pristine upstream fixture is DERIVED IN MEMORY from the real known-good
working-tree file by inverting the blocks.json operations (no git, no
subprocess), so the suite stays durable once this change is committed (HEAD
then already contains the patched core). All tests run against a temporary
root and never touch the actual repo, production systems, or customer data.

Run with:

    python3 custom/wijaya/batteries/custom_roles/patch/test_apply_patches.py
"""
import importlib.util
import json
import os
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", ".."))
TARGET_REL = "app/controllers/api/v1/accounts/captain/tasks_controller.rb"

_spec = importlib.util.spec_from_file_location("cr_apply_patches", os.path.join(HERE, "apply_patches.py"))
applicator = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(applicator)

with open(os.path.join(HERE, "blocks.json"), encoding="utf-8") as _fh:
    SPEC = json.load(_fh)
FILE_SPEC = SPEC["files"][0]
BLOCKS = {blk["name"]: blk for blk in FILE_SPEC["blocks"]}


def read_current():
    with open(os.path.join(REPO_ROOT, TARGET_REL), encoding="utf-8") as fh:
        return fh.read()


def derive_pristine(current):
    """Deterministically rebuild pristine upstream from the known-good patched
    file by inverting every blocks.json operation: blocks that supersede
    upstream text (`replaces`) are swapped back, insert-only blocks are
    removed. Fails loudly when any block is missing, duplicated, or ambiguous,
    and when the derived pristine still carries feature markers."""
    pristine = current
    for blk in FILE_SPEC["blocks"]:
        block = blk["block"]
        if pristine.count(block) != 1:
            raise AssertionError("block %r not present exactly once" % blk["name"])
        pristine = pristine.replace(block, blk.get("replaces", ""), 1)
    starts, ends = applicator.marker_counts(pristine, SPEC["feature"])
    if (starts, ends) != (0, 0):
        raise AssertionError("derived pristine still carries %d/%d markers" % (starts, ends))
    return pristine


class PatchApplicatorTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="wijaya_custom_roles_patch_test_")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.current = read_current()
        self.pristine = derive_pristine(self.current)

    def target(self, content):
        path = os.path.join(self.tmp, TARGET_REL)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
        return path

    def run_apply(self):
        return applicator.run(self.tmp)

    # 1. Pristine upstream receives every block in the correct places — proven
    #    byte-exact against the real known-good working tree.
    def test_pristine_receives_all_blocks(self):
        path = self.target(self.pristine)
        summary = self.run_apply()
        self.assertEqual(summary["applied"], [TARGET_REL])
        with open(path, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), self.current)
        starts, ends = applicator.marker_counts(self.current, SPEC["feature"])
        self.assertEqual((starts, ends), (4, 4))

    # 2. Second run is a byte-identical no-op.
    def test_second_apply_is_noop(self):
        path = self.target(self.pristine)
        self.run_apply()
        with open(path, encoding="utf-8") as fh:
            first = fh.read()
        summary = self.run_apply()
        self.assertEqual(summary["noop"], [TARGET_REL])
        with open(path, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), first)

    # 3. A single missing block is restored (insert-style block vanished,
    #    upstream lines intact — the realistic upstream-pull case).
    def test_one_missing_block_is_restored(self):
        block = BLOCKS["class_require_before_action"]["block"]
        self.assertIn(block, self.current)
        path = self.target(self.current.replace(block, "", 1))
        summary = self.run_apply()
        self.assertEqual(summary["applied"], [TARGET_REL])
        with open(path, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), self.current)

    # 4. Missing anchor fails loudly, no partial write.
    def test_missing_anchor_fails_without_partial_write(self):
        anchor = BLOCKS["render_result_provenance"]["anchor"]
        self.assertIn(anchor, self.pristine)
        path = self.target(self.pristine.replace(anchor, "", 1))
        with open(path, encoding="utf-8") as fh:
            before = fh.read()
        with self.assertRaises(applicator.PatchError):
            self.run_apply()
        with open(path, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), before)

    # 5. Ambiguous anchor fails loudly, no partial write.
    def test_ambiguous_anchor_fails_without_partial_write(self):
        anchor = BLOCKS["private_authorization_method"]["anchor"]
        path = self.target(self.pristine + "\n" + anchor)
        with open(path, encoding="utf-8") as fh:
            before = fh.read()
        with self.assertRaises(applicator.PatchError):
            self.run_apply()
        with open(path, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), before)

    # 6. Tampered block content (markers intact) fails loudly, no partial write.
    def test_tampered_block_fails_without_partial_write(self):
        tampered = self.current.replace(
            "  before_action :authorize_conversation_for_ai_task\n",
            "  before_action :tampered\n",
            1,
        )
        self.assertNotEqual(tampered, self.current)
        path = self.target(tampered)
        with open(path, encoding="utf-8") as fh:
            before = fh.read()
        with self.assertRaises(applicator.PatchError):
            self.run_apply()
        with open(path, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), before)

    # 7. Partial markers (a dropped END line) fail loudly, no partial write.
    def test_partial_marker_fails_without_partial_write(self):
        partial = self.current.replace(
            "  # WIJAYA_CUSTOM_END custom_roles_rbac\n", "", 1
        )
        self.assertNotEqual(partial, self.current)
        path = self.target(partial)
        with open(path, encoding="utf-8") as fh:
            before = fh.read()
        with self.assertRaises(applicator.PatchError):
            self.run_apply()
        with open(path, encoding="utf-8") as fh:
            self.assertEqual(fh.read(), before)


if __name__ == "__main__":
    unittest.main()