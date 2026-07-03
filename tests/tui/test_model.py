"""tests/tui/test_model.py — build_model join + derivation tests.

Covers: join by canonical (classify order), TUI-derived 'inconsistent'
(§4.2), the migrate-projects note, and offload_state None for non-code
entries.
"""
import os
import sys
import unittest

sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "bin")
)
import xdg_tui  # noqa: E402

from fixtures import CLASSIFY_FIXTURE, HEADER, STATUS_FIXTURE  # noqa: E402


def _model():
    classify = xdg_tui.parse_porcelain(CLASSIFY_FIXTURE, "classify")
    status = xdg_tui.parse_porcelain(STATUS_FIXTURE, "offload-status")
    return xdg_tui.build_model(classify, status)


def _entry(entries, canonical):
    return [e for e in entries if e.canonical == canonical][0]


class TestJoin(unittest.TestCase):
    def test_classify_order_preserved(self):
        entries = _model()
        self.assertEqual(len(entries), 15)
        classify = xdg_tui.parse_porcelain(CLASSIFY_FIXTURE, "classify")
        self.assertEqual(
            [e.canonical for e in entries], [r.canonical for r in classify]
        )

    def test_non_code_entries_have_offload_state_none(self):
        entries = _model()
        for e in entries:
            if e.klass != "code":
                self.assertIsNone(e.offload_state, e.canonical)

    def test_code_entries_join_their_status_row(self):
        entries = _model()
        projects = _entry(entries, "projects")
        self.assertEqual(projects.offload_state, "local")
        self.assertEqual(projects.git, "clean")
        androidstudio = _entry(entries, "androidstudio")
        self.assertEqual(androidstudio.offload_state, "absent")
        self.assertEqual(androidstudio.state, "absent")
        self.assertEqual(androidstudio.git, "none")

    def test_code_entry_without_status_row_falls_back_to_classify(self):
        classify = xdg_tui.parse_porcelain(CLASSIFY_FIXTURE, "classify")
        entries = xdg_tui.build_model(classify, [])
        repos = _entry(entries, "repos")
        self.assertIsNone(repos.offload_state)
        self.assertEqual(repos.state, "localdir")

    def test_status_row_for_non_code_canonical_is_ignored(self):
        classify = xdg_tui.parse_porcelain(CLASSIFY_FIXTURE, "classify")
        stray = xdg_tui.parse_porcelain(
            HEADER + "\ncode|documents|Documents|offloaded|gdrive:x|\n",
            "offload-status",
        )
        entries = xdg_tui.build_model(classify, stray)
        documents = _entry(entries, "documents")
        # documents is xdg-class in classify — the stray status row must not attach
        self.assertIsNone(documents.offload_state)
        self.assertEqual(documents.state, "symlink")


class TestInconsistentDerivation(unittest.TestCase):
    def test_localdir_plus_offloaded_is_inconsistent(self):
        entries = _model()
        repos = _entry(entries, "repos")  # classify=localdir, status=offloaded
        self.assertEqual(repos.state, "inconsistent")

    def test_inconsistent_renders_both_facts(self):
        repos = _entry(_model(), "repos")
        self.assertEqual(repos.classify_state, "localdir")
        self.assertEqual(repos.offload_state, "offloaded")
        self.assertIn("offloaded", repos.note)
        self.assertIn("local dir", repos.note)
        # the offloaded remote survives the join
        self.assertEqual(repos.remote, "gdrive:xdg-offload/code/repos")

    def test_offloaded_with_absent_local_is_plain_offloaded(self):
        classify = xdg_tui.parse_porcelain(
            HEADER + "\ncode|repos|repos|absent||\n", "classify"
        )
        status = xdg_tui.parse_porcelain(
            HEADER + "\ncode|repos|repos|offloaded|gdrive:x|\n", "offload-status"
        )
        entries = xdg_tui.build_model(classify, status)
        self.assertEqual(entries[0].state, "offloaded")
        self.assertEqual(entries[0].note, "")

    def test_inconsistent_appears_in_rendered_frame(self):
        lines = xdg_tui.render_frame(_model(), 0, 120)
        self.assertTrue(any("inconsistent" in line for line in lines))


class TestNotes(unittest.TestCase):
    def test_code_symlink_gets_migrate_note(self):
        projects = _entry(_model(), "projects")
        self.assertEqual(projects.classify_state, "symlink")
        self.assertIn("--migrate-projects", projects.note)

    def test_xdg_symlink_gets_no_migrate_note(self):
        documents = _entry(_model(), "documents")
        self.assertEqual(documents.classify_state, "symlink")
        self.assertEqual(documents.note, "")

    def test_ops_for_entry_classes(self):
        entries = _model()
        code_ops = xdg_tui.ops_for_entry(_entry(entries, "repos"))
        self.assertIn("offload", code_ops)
        self.assertIn("icloud-evict", code_ops)
        xdg_ops = xdg_tui.ops_for_entry(_entry(entries, "documents"))
        self.assertNotIn("offload", xdg_ops)
        self.assertIn("icloud-status", xdg_ops)
        self.assertEqual(xdg_tui.ops_for_entry(_entry(entries, "pyenv")), [])


if __name__ == "__main__":
    unittest.main()
