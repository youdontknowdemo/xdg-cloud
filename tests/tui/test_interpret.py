"""tests/tui/test_interpret.py — interpret_result rc mapping.

rc 0 -> ok; rc 130 -> interrupted (NEVER success); rc 1 -> refused with
stderr verbatim; anything else -> error. No stderr parsing beyond
pass-through.
"""
import os
import sys
import unittest

sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "bin")
)
import xdg_tui  # noqa: E402


class TestInterpretResult(unittest.TestCase):
    def test_rc_zero_is_ok(self):
        outcome = xdg_tui.interpret_result("offload", 0, "synced\n", "")
        self.assertEqual(outcome.status, "ok")
        self.assertEqual(outcome.message, "synced\n")

    def test_rc_130_is_interrupted_never_success(self):
        outcome = xdg_tui.interpret_result("offload", 130, "", "recovery: lock released\n")
        self.assertEqual(outcome.status, "interrupted")
        self.assertNotEqual(outcome.status, "ok")
        self.assertEqual(outcome.message, "recovery: lock released\n")

    def test_rc_one_is_refused_with_stderr_verbatim(self):
        stderr = "[cloud-xdg] ERROR: refusing: repos has uncommitted changes\n  (2 lines)\n"
        outcome = xdg_tui.interpret_result("offload", 1, "partial stdout", stderr)
        self.assertEqual(outcome.status, "refused")
        self.assertEqual(outcome.message, stderr)  # verbatim — no parsing, no rewrite

    def test_other_rcs_are_error(self):
        for rc in (2, 64, 127, 141, 255, -9):
            outcome = xdg_tui.interpret_result("hydrate", rc, "", "boom\n")
            self.assertEqual(outcome.status, "error", rc)
            self.assertEqual(outcome.message, "boom\n")

    def test_130_not_conflated_with_generic_error(self):
        self.assertNotEqual(
            xdg_tui.interpret_result("offload", 130, "", "").status,
            xdg_tui.interpret_result("offload", 2, "", "").status,
        )


if __name__ == "__main__":
    unittest.main()
