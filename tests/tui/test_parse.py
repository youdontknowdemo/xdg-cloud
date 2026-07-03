"""tests/tui/test_parse.py — parse_porcelain contract tests.

Covers: header refusal (first line != porcelain=1), exact-6-field rule,
unknown-state / short-row -> PorcelainError (surfaced never guessed), and
every enum state from the §2.6 golden fixture text.
"""
import os
import sys
import unittest

sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "bin")
)
import xdg_tui  # noqa: E402

from fixtures import (  # noqa: E402
    CLASSIFY_FIXTURE,
    GOLDEN_CLASSIFY_LINES,
    GOLDEN_STATUS_LINES,
    HEADER,
    STATUS_FIXTURE,
)


class TestHeaderRefusal(unittest.TestCase):
    def test_wrong_version_refused(self):
        with self.assertRaises(xdg_tui.PorcelainError):
            xdg_tui.parse_porcelain("porcelain=2\nxdg|a|A|absent||\n", "classify")

    def test_empty_output_refused(self):
        with self.assertRaises(xdg_tui.PorcelainError):
            xdg_tui.parse_porcelain("", "classify")

    def test_trailing_space_on_header_refused(self):
        with self.assertRaises(xdg_tui.PorcelainError):
            xdg_tui.parse_porcelain("porcelain=1 \n", "classify")

    def test_human_output_refused(self):
        # Old script / missing --porcelain support: human header must fail fast.
        with self.assertRaises(xdg_tui.PorcelainError):
            xdg_tui.parse_porcelain(
                "[cloud-xdg] classify: known top-level entries\n", "classify"
            )

    def test_header_only_is_zero_rows(self):
        self.assertEqual(xdg_tui.parse_porcelain(HEADER + "\n", "classify"), [])


class TestFieldDiscipline(unittest.TestCase):
    def test_short_row_surfaced_never_guessed(self):
        bad = "xdg|documents|Documents|symlink|/x"  # 5 fields
        with self.assertRaises(xdg_tui.PorcelainError) as ctx:
            xdg_tui.parse_porcelain(HEADER + "\n" + bad + "\n", "classify")
        self.assertIn(bad, str(ctx.exception))

    def test_long_row_surfaced(self):
        bad = "xdg|documents|Documents|symlink|/x||extra"  # 7 fields
        with self.assertRaises(xdg_tui.PorcelainError) as ctx:
            xdg_tui.parse_porcelain(HEADER + "\n" + bad + "\n", "classify")
        self.assertIn(bad, str(ctx.exception))

    def test_unknown_state_surfaced(self):
        bad = "xdg|documents|Documents|wedged||"
        with self.assertRaises(xdg_tui.PorcelainError) as ctx:
            xdg_tui.parse_porcelain(HEADER + "\n" + bad + "\n", "classify")
        self.assertIn(bad, str(ctx.exception))
        self.assertIn("wedged", str(ctx.exception))

    def test_state_enums_are_per_source(self):
        # 'offloaded' is an offload-status state, never a classify state...
        row = "code|repos|repos|offloaded|gdrive:x|"
        with self.assertRaises(xdg_tui.PorcelainError):
            xdg_tui.parse_porcelain(HEADER + "\n" + row + "\n", "classify")
        # ...and 'symlink' is a classify state, never an offload-status state.
        row = "code|repos|repos|symlink|/x|"
        with self.assertRaises(xdg_tui.PorcelainError):
            xdg_tui.parse_porcelain(HEADER + "\n" + row + "\n", "offload-status")

    def test_unknown_source_is_a_caller_error(self):
        with self.assertRaises(ValueError):
            xdg_tui.parse_porcelain(HEADER + "\n", "reclaim")


class TestGoldenFixtures(unittest.TestCase):
    def test_classify_fixture_parses_all_rows(self):
        rows = xdg_tui.parse_porcelain(CLASSIFY_FIXTURE, "classify")
        self.assertEqual(len(rows), 15)
        self.assertEqual([r.klass for r in rows].count("xdg"), 8)
        self.assertEqual([r.klass for r in rows].count("code"), 3)
        self.assertEqual([r.klass for r in rows].count("local"), 4)
        # classify git field is always empty
        self.assertTrue(all(r.git == "" for r in rows))

    def test_classify_row_fields(self):
        rows = xdg_tui.parse_porcelain(CLASSIFY_FIXTURE, "classify")
        documents = [r for r in rows if r.canonical == "documents"][0]
        self.assertEqual(documents.klass, "xdg")
        self.assertEqual(documents.local_name, "Documents")
        self.assertEqual(documents.state, "symlink")
        self.assertEqual(documents.remote, "/sandbox/cloud/documents")

    def test_status_fixture_parses_all_rows(self):
        rows = xdg_tui.parse_porcelain(STATUS_FIXTURE, "offload-status")
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0].state, "offloaded")
        self.assertEqual(rows[0].remote, "gdrive:xdg-offload/code/repos")
        self.assertEqual(rows[1].state, "absent")
        self.assertEqual(rows[1].git, "none")
        self.assertEqual(rows[2].state, "local")
        self.assertEqual(rows[2].git, "clean")

    def test_every_golden_classify_line(self):
        for line in GOLDEN_CLASSIFY_LINES:
            rows = xdg_tui.parse_porcelain(HEADER + "\n" + line + "\n", "classify")
            self.assertEqual(len(rows), 1, line)

    def test_every_golden_status_line(self):
        for line in GOLDEN_STATUS_LINES:
            rows = xdg_tui.parse_porcelain(HEADER + "\n" + line + "\n", "offload-status")
            self.assertEqual(len(rows), 1, line)

    def test_sanitized_placeholders_parse_as_plain_strings(self):
        rows = xdg_tui.parse_porcelain(
            HEADER + "\ncode|repos|repos|offloaded|<unknown remote>|\n",
            "offload-status",
        )
        self.assertEqual(rows[0].remote, "<unknown remote>")
        rows = xdg_tui.parse_porcelain(
            HEADER + "\nxdg|documents|Documents|symlink|<non-porcelain-target>|\n",
            "classify",
        )
        self.assertEqual(rows[0].remote, "<non-porcelain-target>")

    def test_git_field_is_mirrored_not_validated(self):
        # The porcelain is a faithful mirror; only `state` is enum-checked.
        # An unexpected git token passes through (surfaced by rendering).
        rows = xdg_tui.parse_porcelain(
            HEADER + "\ncode|repos|repos|local||weird\n", "offload-status"
        )
        self.assertEqual(rows[0].git, "weird")


if __name__ == "__main__":
    unittest.main()
