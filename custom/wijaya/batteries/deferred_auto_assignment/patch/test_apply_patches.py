#!/usr/bin/env python3
"""Tests for the DeferredAutoAssignment schedule patch applicator."""

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('deferred_auto_assignment_apply', HERE / 'apply_patches.py')
APPLICATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APPLICATOR)


class PatchApplicatorTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.target = self.root / APPLICATOR.TARGET
        self.target.parent.mkdir(parents=True)
        self.pristine = f"before\n{APPLICATOR.ANCHOR}\nafter\n"
        self.current = self.pristine.replace(
            APPLICATOR.ANCHOR, f"{APPLICATOR.ANCHOR}\n{APPLICATOR.BLOCK}", 1
        )

    def write(self, content):
        self.target.write_text(content, encoding='utf-8')
        os.chmod(self.target, 0o640)

    def assert_fails_without_writing(self, content):
        self.write(content)
        before = self.target.read_bytes()
        with self.assertRaises(APPLICATOR.PatchError):
            APPLICATOR.apply(self.root)
        self.assertEqual(self.target.read_bytes(), before)

    def test_missing_block_is_inserted_atomically_and_second_apply_is_noop(self):
        self.write(self.pristine)

        self.assertTrue(APPLICATOR.apply(self.root))
        first = self.target.read_bytes()

        self.assertEqual(self.target.read_text(encoding='utf-8'), self.current)
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o640)
        self.assertFalse(APPLICATOR.apply(self.root))
        self.assertEqual(self.target.read_bytes(), first)

    def test_exact_block_is_a_noop(self):
        self.write(self.current)

        self.assertFalse(APPLICATOR.apply(self.root))
        APPLICATOR.check(self.root)
        self.assertEqual(self.target.read_text(encoding='utf-8'), self.current)

    def test_partial_marker_fails_without_writing(self):
        self.assert_fails_without_writing(self.current.replace(APPLICATOR.END, '', 1))

    def test_duplicate_marker_block_fails_without_writing(self):
        self.assert_fails_without_writing(f"{self.current}\n{APPLICATOR.BLOCK}")

    def test_changed_marker_block_fails_without_writing(self):
        changed = self.current.replace('  active_job: true\n', '  active_job: false\n', 1)
        self.assert_fails_without_writing(changed)

    def test_missing_or_ambiguous_insertion_context_fails_without_writing(self):
        self.assert_fails_without_writing('before\nafter\n')
        self.assert_fails_without_writing(f"{self.pristine}\n{APPLICATOR.ANCHOR}")


if __name__ == '__main__':
    unittest.main()
