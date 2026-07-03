"""tests/tui/test_plan.py — plan_action argv matrix + safety gates.

P0 invariants at 100% branch coverage (§5/§6):
  * --apply appears IFF confirmed is the literal True.
  * --i-understand-data-loss-risk appears IFF op == icloud-evict AND
    typed_ack == target (exact string equality); otherwise ConsentError
    BEFORE any argv exists.
Adversarial: default-no, empty input, trailing slash, case drift,
truthy-but-not-True confirms.
"""
import os
import sys
import unittest

sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "bin")
)
import xdg_tui  # noqa: E402

KEY = "repos"
PATH = "/sandbox/home/repos"
RISK = "--i-understand-data-loss-risk"


def _valid_argv(op, confirmed=False):
    """plan_action with valid inputs for any op (evict gets its typed_ack)."""
    spec = xdg_tui.ACTIONS[op]
    target = KEY if spec["target"] == "key" else PATH
    typed_ack = target if op == "icloud-evict" else None
    return xdg_tui.plan_action(target, op, confirmed=confirmed, typed_ack=typed_ack)


class TestArgvMatrix(unittest.TestCase):
    def test_offload(self):
        self.assertEqual(_valid_argv("offload"), ["--offload", KEY])
        self.assertEqual(_valid_argv("offload", True), ["--offload", KEY, "--apply"])

    def test_hydrate(self):
        self.assertEqual(_valid_argv("hydrate"), ["--hydrate", KEY])
        self.assertEqual(_valid_argv("hydrate", True), ["--hydrate", KEY, "--apply"])

    def test_reclaim(self):
        self.assertEqual(_valid_argv("reclaim"), ["--reclaim", PATH])
        self.assertEqual(_valid_argv("reclaim", True), ["--reclaim", PATH, "--apply"])

    def test_icloud_status(self):
        self.assertEqual(_valid_argv("icloud-status"), ["--icloud-status", PATH])

    def test_icloud_download(self):
        self.assertEqual(_valid_argv("icloud-download"), ["--icloud-download", PATH])
        self.assertEqual(
            _valid_argv("icloud-download", True),
            ["--icloud-download", PATH, "--apply"],
        )

    def test_icloud_evict_with_ack(self):
        self.assertEqual(
            xdg_tui.plan_action(PATH, "icloud-evict", typed_ack=PATH),
            ["--icloud-evict", PATH, RISK],
        )
        self.assertEqual(
            xdg_tui.plan_action(PATH, "icloud-evict", confirmed=True, typed_ack=PATH),
            ["--icloud-evict", PATH, RISK, "--apply"],
        )

    def test_unknown_op(self):
        with self.assertRaises(ValueError):
            xdg_tui.plan_action(KEY, "dotfiles-init")

    def test_empty_or_non_string_target(self):
        for bad in ("", None, 0, ["repos"]):
            for op in xdg_tui.ACTIONS:
                with self.assertRaises((ValueError, xdg_tui.ConsentError)):
                    xdg_tui.plan_action(bad, op)


class TestApplyGate(unittest.TestCase):
    def test_no_apply_without_confirm_every_op(self):
        for op in xdg_tui.ACTIONS:
            self.assertNotIn("--apply", _valid_argv(op, confirmed=False), op)

    def test_apply_present_iff_confirmed_true(self):
        for op in xdg_tui.ACTIONS:
            self.assertIn("--apply", _valid_argv(op, confirmed=True), op)

    def test_truthy_stand_ins_never_gate_a_mutation(self):
        # 'confirmed is True' is a strict identity gate: 1 == True in python,
        # but a data-loss gate must not accept accidental truthiness.
        for stand_in in (1, "y", "yes", "yy", [True], object()):
            argv = xdg_tui.plan_action(KEY, "offload", confirmed=stand_in)
            self.assertNotIn("--apply", argv, repr(stand_in))

    def test_default_is_no(self):
        self.assertNotIn("--apply", xdg_tui.plan_action(KEY, "offload"))


class TestEvictConsentGate(unittest.TestCase):
    def test_missing_ack_raises_before_any_argv(self):
        with self.assertRaises(xdg_tui.ConsentError):
            xdg_tui.plan_action(PATH, "icloud-evict")

    def test_missing_ack_raises_even_for_preview(self):
        # §6: the script checks the risk flag before dry-run, so the TUI must
        # not build even a confirmed=False preview argv without the ack.
        with self.assertRaises(xdg_tui.ConsentError):
            xdg_tui.plan_action(PATH, "icloud-evict", confirmed=False, typed_ack=None)

    def test_adversarial_acks_all_fail(self):
        adversarial = [
            "",                # empty input
            "y",               # confirm-key reflex at the typed prompt
            "yy",              # double keypress
            PATH + "/",        # trailing slash
            PATH.upper(),      # case drift
            " " + PATH,        # leading whitespace
            PATH + "\n",       # embedded newline survives (only tty strips it)
            PATH[:-1],         # near miss
        ]
        for ack in adversarial:
            with self.assertRaises(xdg_tui.ConsentError):
                xdg_tui.plan_action(PATH, "icloud-evict", typed_ack=ack)

    def test_non_string_ack_fails(self):
        for ack in (True, 1, [PATH], PATH.encode()):
            with self.assertRaises(xdg_tui.ConsentError):
                xdg_tui.plan_action(PATH, "icloud-evict", typed_ack=ack)

    def test_risk_flag_never_on_other_ops(self):
        # Even a caller passing typed_ack on a non-evict op never gets the flag.
        for op in xdg_tui.ACTIONS:
            if op == "icloud-evict":
                continue
            spec = xdg_tui.ACTIONS[op]
            target = KEY if spec["target"] == "key" else PATH
            argv = xdg_tui.plan_action(target, op, confirmed=True, typed_ack=target)
            self.assertNotIn(RISK, argv, op)

    def test_exact_match_is_the_only_pass(self):
        argv = xdg_tui.plan_action(PATH, "icloud-evict", typed_ack=PATH)
        self.assertIn(RISK, argv)

    def test_confirmed_true_does_not_bypass_consent(self):
        with self.assertRaises(xdg_tui.ConsentError):
            xdg_tui.plan_action(PATH, "icloud-evict", confirmed=True, typed_ack="")


class TestPreviewBlocks(unittest.TestCase):
    def test_would_block_detected(self):
        self.assertTrue(xdg_tui.preview_blocks("plan:\nWOULD BLOCK: dirty git tree\n"))

    def test_clean_preview_not_blocked(self):
        self.assertFalse(xdg_tui.preview_blocks("plan:\nwould sync repos -> remote\n"))


if __name__ == "__main__":
    unittest.main()
