#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('proxy_https_apply', HERE / 'apply_patches.py')
APPLICATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(APPLICATOR)


class PatchApplicatorTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.target = self.root / APPLICATOR.TARGET
        self.compose_target = self.root / APPLICATOR.COMPOSE_TARGET
        self.target.parent.mkdir(parents=True)
        self.write(APPLICATOR.UPSTREAM, APPLICATOR.COMPOSE_ANCHOR)

    def write(self, ssl_section, compose_section):
        self.target.write_text("Rails.application.configure do\n" + ssl_section + "end\n")
        self.compose_target.write_text("services:\n  rails:\n    environment:\n" + compose_section)

    def test_applies_hook_and_deploy_override_then_second_run_is_noop(self):
        self.assertTrue(APPLICATOR.apply(self.root))
        first = self.target.read_text()
        first_compose = self.compose_target.read_text()
        self.assertIn(APPLICATOR.BLOCK, first)
        self.assertIn(APPLICATOR.COMPOSE_BLOCK, first_compose)
        self.assertFalse(APPLICATOR.apply(self.root))
        self.assertEqual(self.target.read_text(), first)
        self.assertEqual(self.compose_target.read_text(), first_compose)

    def test_partial_marker_fails_without_writing(self):
        self.write(APPLICATOR.UPSTREAM + "  # WIJAYA_CUSTOM_START proxy_https\n", APPLICATOR.COMPOSE_ANCHOR)
        before = self.target.read_text()
        compose_before = self.compose_target.read_text()

        with self.assertRaises(APPLICATOR.PatchError):
            APPLICATOR.apply(self.root)

        self.assertEqual(self.target.read_text(), before)
        self.assertEqual(self.compose_target.read_text(), compose_before)

    def test_changed_production_anchor_fails_without_writing(self):
        self.write("  config.force_ssl = true\n", APPLICATOR.COMPOSE_ANCHOR)
        before = self.target.read_text()
        compose_before = self.compose_target.read_text()

        with self.assertRaises(APPLICATOR.PatchError):
            APPLICATOR.apply(self.root)

        self.assertEqual(self.target.read_text(), before)
        self.assertEqual(self.compose_target.read_text(), compose_before)

    def test_changed_compose_anchor_fails_before_writing_production_hook(self):
        self.write(APPLICATOR.UPSTREAM, "      - DIFFERENT_SETTING=true\n")
        before = self.target.read_text()
        compose_before = self.compose_target.read_text()

        with self.assertRaises(APPLICATOR.PatchError):
            APPLICATOR.apply(self.root)

        self.assertEqual(self.target.read_text(), before)
        self.assertEqual(self.compose_target.read_text(), compose_before)


if __name__ == '__main__':
    unittest.main()
