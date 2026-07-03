"""tests/tui/test_ui_prompts.py — consent-prompt input hygiene.

Pins the anti-type-ahead guard: _confirm and _prompt_line must call
curses.flushinp() AFTER the prompt renders and BEFORE reading, so buffered
paste/type-ahead can never auto-answer the y/N apply confirm or feed the
typed-consent (evict) prompt. The lazy `import curses` inside each UI
function is the seam: a fake module injected into sys.modules is what the
function's own import resolves, so these tests observe real call order
without a tty. Also pins default-N on EOF (getch -1) and on non-'y' keys.
"""
import os
import sys
import unittest
from unittest import mock

sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "bin")
)
import xdg_tui  # noqa: E402


class _FakeCurses(object):
    """Stands in for the curses module inside _confirm/_prompt_line."""

    A_BOLD = 0

    def __init__(self, events):
        self._events = events

    def flushinp(self):
        self._events.append("flushinp")

    def echo(self):
        self._events.append("echo")

    def noecho(self):
        self._events.append("noecho")


class _FakeStdscr(object):
    """Minimal window fake: records refresh/read order, serves canned input."""

    def __init__(self, events, key=-1, line=b""):
        self._events = events
        self._key = key
        self._line = line

    def getmaxyx(self):
        return (24, 80)

    def move(self, *args):
        pass

    def clrtoeol(self):
        pass

    def addnstr(self, *args):
        pass

    def refresh(self):
        self._events.append("refresh")

    def getch(self):
        self._events.append("getch")
        return self._key

    def getstr(self, *args):
        self._events.append("getstr")
        return self._line


class ConsentPromptCase(unittest.TestCase):
    def _run_confirm(self, key):
        events = []
        fake = _FakeCurses(events)
        stdscr = _FakeStdscr(events, key=key)
        with mock.patch.dict(sys.modules, {"curses": fake}):
            answer = xdg_tui._confirm(stdscr, "apply?")
        return answer, events

    def _run_prompt_line(self, line):
        events = []
        fake = _FakeCurses(events)
        stdscr = _FakeStdscr(events, line=line)
        with mock.patch.dict(sys.modules, {"curses": fake}):
            typed = xdg_tui._prompt_line(stdscr, "type the path: ")
        return typed, events

    def assert_flush_between_render_and_read(self, events, read):
        # Exactly one flush, after the prompt is on screen, before the read —
        # earlier (pre-render) or absent flushing leaves the paste window open.
        self.assertEqual(events.count("flushinp"), 1, events)
        self.assertLess(events.index("refresh"), events.index("flushinp"), events)
        self.assertLess(events.index("flushinp"), events.index(read), events)

    def test_confirm_flushes_typeahead_before_the_read(self):
        answer, events = self._run_confirm(key=ord("y"))
        self.assertTrue(answer)
        self.assert_flush_between_render_and_read(events, "getch")

    def test_confirm_defaults_no_on_eof(self):
        answer, _ = self._run_confirm(key=-1)  # curses getch EOF/no-input
        self.assertFalse(answer)

    def test_confirm_defaults_no_on_other_keys(self):
        for key in (ord("Y"), ord("n"), 10, 27):
            answer, _ = self._run_confirm(key=key)
            self.assertFalse(answer, "key %r answered yes" % (key,))

    def test_prompt_line_flushes_typeahead_before_the_read(self):
        typed, events = self._run_prompt_line(line=b"/some/path")
        self.assertEqual(typed, "/some/path")
        self.assert_flush_between_render_and_read(events, "getstr")

    def test_prompt_line_noecho_restored_after_read(self):
        _, events = self._run_prompt_line(line=b"")
        self.assertLess(events.index("echo"), events.index("getstr"), events)
        self.assertLess(events.index("getstr"), events.index("noecho"), events)


if __name__ == "__main__":
    unittest.main()
