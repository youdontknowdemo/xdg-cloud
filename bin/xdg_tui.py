#!/usr/bin/env python3
"""xdg-tui — optional curses dashboard wrapping bin/cloud-xdg-provision.sh.

Location: bin/xdg_tui.py (launched via the bin/xdg-tui bash launcher; tests
import it directly as `xdg_tui` after a sys.path.insert on bin/).

Strict wrapper: every action is a normal dry-run/--apply invocation of the
provision script; the script's guards (lock, not-root, degenerate-path refusal,
master trap, read-back verify, evict gates) are the sole enforcement layer.
The TUI adds UX, never policy — refusals render verbatim, consent friction is
preserved (typed acknowledgment for icloud-evict), and argv is built only from
canonical registry keys and $HOME/<localName> joins.

Three-layer seam (docs/architecture/tui-offload-manager-diff.md §4):
  CORE      pure functions — no tty, no subprocess, no os.environ reads
  EXECUTOR  thin subprocess layer — capture (full-drain) vs handover (real tty)
  UI        curses loop — `import curses` ONLY inside UI entrypoints (lazy),
            so CORE + EXECUTOR import cleanly on a python without curses.
"""
# stdlib only. NO `import curses` at module top (lazy, inside UI) — the pure
# core + executor must import cleanly on a python without curses. Python 3.9
# floor (stock macOS CLT): no match statements, no `X | Y` annotations.
import collections
import os
import signal
import subprocess
import sys

PORCELAIN_VERSION = "porcelain=1"

USAGE = """usage: xdg-tui [--dump | --version]

  (no args)   launch the curses dashboard
  --dump      print one rendered frame to stdout (no tty needed) and exit
  --version   print the xdg-tui version and exit
"""

# ============================== CORE (pure) ==============================
# No tty, no subprocess, no os.environ reads inside these functions — every
# input arrives as a parameter. 100% branch coverage required on gating logic.


class PorcelainError(Exception):
    """Bad porcelain header, field count, or unknown state token."""


class ConsentError(Exception):
    """icloud-evict requested without the exact typed acknowledgment."""


# Parsed porcelain row: class|canonical|localName|state|remote|git (all str).
Row = collections.namedtuple(
    "Row", ["klass", "canonical", "local_name", "state", "remote", "git"]
)

# Joined dashboard entry. offload_state is None for non-code entries (or when
# no offload-status row exists); `state` is the render-derived summary and
# `note` is advisory text (migrate hint / inconsistent facts) — never policy.
Entry = collections.namedtuple(
    "Entry",
    [
        "klass",           # 'xdg' | 'code' | 'local'
        "canonical",
        "local_name",
        "classify_state",  # 'symlink' | 'localdir' | 'absent'
        "offload_state",   # 'offloaded' | 'local' | 'absent' | None
        "git",             # 'clean' | 'dirty' | 'none' | ''
        "remote",
        "state",           # derived — see build_model
        "note",            # advisory string ('' if none)
    ],
)

Outcome = collections.namedtuple("Outcome", ["status", "message"])

# Per-source state enums (frozen with porcelain=1; drift -> PorcelainError).
_STATE_ENUMS = {
    "classify": frozenset(["symlink", "localdir", "absent"]),
    "offload-status": frozenset(["offloaded", "local", "absent"]),
}

_ROW_FIELDS = 6

# Action/lane registry (§5). target='key' ops receive a canonical registry
# key; target='path' ops receive the absolute $HOME/<localName> join computed
# at call time. read_only ops never go through terminal handover.
ACTIONS = {
    "offload":         {"flag": "--offload",         "target": "key",  "read_only": False},
    "hydrate":         {"flag": "--hydrate",         "target": "key",  "read_only": False},
    "reclaim":         {"flag": "--reclaim",         "target": "path", "read_only": False},
    "icloud-status":   {"flag": "--icloud-status",   "target": "path", "read_only": True},
    "icloud-download": {"flag": "--icloud-download", "target": "path", "read_only": False},
    "icloud-evict":    {"flag": "--icloud-evict",    "target": "path", "read_only": False},
}

MIGRATE_NOTE = "cloud-symlinked; restore with --migrate-projects"
INCONSISTENT_NOTE = "state-file says offloaded · local dir populated"


def parse_porcelain(text, source):
    # type: (str, str) -> list
    """Parse one porcelain capture into Rows.

    First line must equal PORCELAIN_VERSION else PorcelainError (fail-fast on
    version drift). Each row: exactly 6 pipe-split fields; state must be in
    the source's enum set; unknown state / wrong field count raises
    PorcelainError carrying the raw line (surfaced, never guessed).
    """
    if source not in _STATE_ENUMS:
        raise ValueError("unknown porcelain source: %r" % (source,))
    lines = text.splitlines()
    if not lines or lines[0] != PORCELAIN_VERSION:
        got = lines[0] if lines else "<empty output>"
        raise PorcelainError(
            "expected first line %r, got %r — refusing to parse (%s)"
            % (PORCELAIN_VERSION, got, source)
        )
    states = _STATE_ENUMS[source]
    rows = []
    for raw in lines[1:]:
        if raw == "":
            continue  # trailing-newline artifact only; real rows are never empty
        fields = raw.split("|")
        if len(fields) != _ROW_FIELDS:
            raise PorcelainError(
                "expected %d fields, got %d in %s row: %r"
                % (_ROW_FIELDS, len(fields), source, raw)
            )
        row = Row(*fields)
        if row.state not in states:
            raise PorcelainError(
                "unknown state %r in %s row: %r" % (row.state, source, raw)
            )
        rows.append(row)
    return rows


def build_model(classify_rows, status_rows):
    # type: (list, list) -> list
    """Join classify + offload-status rows by canonical key (classify order).

    Derivations are render-only, never policy:
    - state = offload_state if the entry is code-class and has a status row,
      else classify_state — EXCEPT:
    - 'inconsistent' when classify_state == 'localdir' AND offload_state ==
      'offloaded' (state file + populated local dir); note renders BOTH facts.
    - note = migrate-projects hint when klass == 'code' and classify says
      'symlink' (the advisory line the porcelain deliberately omits).
    """
    status_by_canonical = {}
    for srow in status_rows:
        status_by_canonical[srow.canonical] = srow
    entries = []
    for crow in classify_rows:
        srow = status_by_canonical.get(crow.canonical) if crow.klass == "code" else None
        offload_state = srow.state if srow is not None else None
        git = srow.git if (srow is not None and srow.git) else crow.git
        if srow is not None and srow.state == "offloaded" and srow.remote:
            remote = srow.remote
        else:
            remote = crow.remote
        note = ""
        if offload_state is not None:
            if crow.state == "localdir" and offload_state == "offloaded":
                state = "inconsistent"
                note = INCONSISTENT_NOTE
            else:
                state = offload_state
        else:
            state = crow.state
        if crow.klass == "code" and crow.state == "symlink":
            note = MIGRATE_NOTE
        entries.append(
            Entry(
                klass=crow.klass,
                canonical=crow.canonical,
                local_name=crow.local_name,
                classify_state=crow.state,
                offload_state=offload_state,
                git=git,
                remote=remote,
                state=state,
                note=note,
            )
        )
    return entries


def plan_action(target, op, confirmed=False, typed_ack=None):
    # type: (str, str, bool, str) -> list
    """Build argv for one op from the ACTIONS table (script path NOT included).

    GATES (the P0-tested invariants):
      * '--apply' appears IFF confirmed is the literal True (strict identity —
        truthy stand-ins like 1 or 'y' never gate a mutation).
      * '--i-understand-data-loss-risk' appears IFF op == 'icloud-evict' AND
        typed_ack == target (exact string equality — no trimming, no case
        folding). 'icloud-evict' with a missing/mismatched typed_ack raises
        ConsentError BEFORE any argv exists — not even a preview argv.
    Unknown op -> ValueError. Empty/non-string target -> ValueError.
    """
    if op not in ACTIONS:
        raise ValueError("unknown op: %r" % (op,))
    if not isinstance(target, str) or target == "":
        raise ValueError("target must be a non-empty string, got %r" % (target,))
    spec = ACTIONS[op]
    if op == "icloud-evict":
        if not isinstance(typed_ack, str) or typed_ack != target:
            raise ConsentError(
                "icloud-evict requires typing the exact target path (%r) to "
                "acknowledge the data-loss risk" % (target,)
            )
        argv = [spec["flag"], target, "--i-understand-data-loss-risk"]
    else:
        argv = [spec["flag"], target]
    if confirmed is True:
        argv.append("--apply")
    return argv


def interpret_result(op, rc, out, err):
    # type: (str, int, str, str) -> Outcome
    """Map a child exit to an Outcome. rc 0 -> 'ok'; rc 130 -> 'interrupted'
    (NEVER success); rc 1 -> 'refused' (die/guard; message = stderr verbatim);
    other -> 'error'. No stderr parsing beyond pass-through."""
    if rc == 0:
        return Outcome("ok", out)
    if rc == 130:
        return Outcome("interrupted", err)
    if rc == 1:
        return Outcome("refused", err)
    return Outcome("error", err)


def preview_blocks(out):
    # type: (str) -> bool
    """True if a dry-run preview contains 'WOULD BLOCK' — UX nicety only
    (suppress the confirm prompt); not policy."""
    return "WOULD BLOCK" in out


def ops_for_entry(entry):
    # type: (Entry) -> list
    """Lanes offered in the action menu. Applicability filtering stays with
    the script (wrap-don't-bypass): every lane valid for the CLASS is shown;
    a lane the script refuses renders as a verbatim refusal."""
    if entry.klass == "code":
        return ["offload", "hydrate", "reclaim",
                "icloud-status", "icloud-download", "icloud-evict"]
    if entry.klass == "xdg":
        return ["icloud-status", "icloud-download", "icloud-evict"]
    return []  # 'local' class: machine-local, informational only


def _entry_detail(entry):
    # type: (Entry) -> str
    parts = []
    if entry.classify_state == "symlink" and entry.remote:
        parts.append("-> " + entry.remote)
    elif entry.offload_state == "offloaded" and entry.remote:
        parts.append(entry.remote)
    if entry.git:
        # 'dirty' gets a textual caution marker — no color-only encoding.
        parts.append("git:%s%s" % (entry.git, " (!)" if entry.git == "dirty" else ""))
    if entry.note:
        parts.append(entry.note)
    return " · ".join(parts)


def render_frame(entries, selected, width):
    # type: (list, int, int) -> list
    """Pure frame renderer shared by the curses UI and --dump."""
    width = max(20, width)
    lines = []
    lines.append("xdg-tui — cloud-xdg dashboard (%d entries)" % len(entries))
    lines.append("  %-5s %-24s %-13s %s" % ("class", "name", "state", "detail"))
    lines.append("-" * min(width, 72))
    for i, entry in enumerate(entries):
        cursor = ">" if i == selected else " "
        line = "%s %-5s %-24s %-13s %s" % (
            cursor, entry.klass, entry.local_name, entry.state, _entry_detail(entry)
        )
        lines.append(line.rstrip())
    lines.append("")
    lines.append("j/k move · enter act · r refresh · ? help · q quit")
    return [line[:width] for line in lines]


# ============================ EXECUTOR (thin) ============================


def _sigint_noop(signum, frame):
    # A HANDLER, never signal.SIG_IGN (§7): SIG_IGN survives exec and would
    # silently disable the child bash's `trap on_signal INT`; a handled signal
    # resets to SIG_DFL on exec, so the child's recovery trap arms normally.
    pass


class Executor:
    """Runs the provision script. Two modes, never mixed:

    capture  — read-only calls (porcelain reads, dry-run previews): full-drain
               pipes, output returned to the caller.
    handover — --apply calls: child inherits the real tty (rclone --progress,
               guard refusals, and trap recovery text render natively).
    """

    def __init__(self, script_path, env=None):
        # env=None -> os.environ resolved AT CALL TIME (never cached at
        # import/construct; tests inject a sandboxed env: HOME, XDG_*, shims).
        self.script_path = script_path
        self._env = env

    def environ(self):
        # type: () -> dict
        """The env the next child will see (fresh copy, resolved now)."""
        return dict(self._env) if self._env is not None else dict(os.environ)

    def capture(self, argv):
        # type: (list) -> tuple
        """READ-ONLY calls only. subprocess.run(capture_output=True) — full
        drain guaranteed, pipe never closed early (SIGPIPE-141 hazard). Never
        used for anything containing --apply."""
        proc = subprocess.run(
            [self.script_path] + list(argv),
            capture_output=True,
            text=True,
            errors="replace",
            env=self.environ(),
            # A captured child must never read the TUI's tty: a script prompt
            # would steal keystrokes from curses or block forever.
            stdin=subprocess.DEVNULL,
        )
        return (proc.returncode, proc.stdout, proc.stderr)

    def handover(self, argv):
        # type: (list) -> int
        """--apply calls only. Caller has already left curses (endwin). The
        child inherits stdin/stdout/stderr. A no-op SIGINT handler is installed
        around the run (and restored in finally) so Ctrl-C reaches the child's
        trap while the parent survives to report rc 130 (PEP-475 auto-retry)."""
        prev = signal.signal(signal.SIGINT, _sigint_noop)
        try:
            proc = subprocess.run(
                [self.script_path] + list(argv),
                env=self.environ(),
            )
            return proc.returncode
        finally:
            signal.signal(signal.SIGINT, prev)


def default_script_path():
    # type: () -> str
    """$XDG_TUI_SCRIPT if set (test seam), else the provision script beside
    this file — resolved via realpath at call time, never cached at import."""
    override = os.environ.get("XDG_TUI_SCRIPT")
    if override:
        return override
    here = os.path.dirname(os.path.realpath(__file__))
    return os.path.join(here, "cloud-xdg-provision.sh")


def read_version():
    # type: () -> str
    """<dir-of-this-file>/../VERSION, first whitespace-delimited token;
    '(version unknown)' on missing/empty — mirrors the script's print_version()."""
    here = os.path.dirname(os.path.realpath(__file__))
    path = os.path.join(here, "..", "VERSION")
    try:
        with open(path, "r") as fh:
            tokens = fh.read().split()
    except OSError:
        return "(version unknown)"
    return tokens[0] if tokens else "(version unknown)"


# ============================== UI (curses) ==============================
# `import curses` appears only inside these entrypoints so that --dump,
# --version, and all CORE/EXECUTOR imports work without curses.

HELP_TEXT = """xdg-tui key reference

  j / DOWN     move selection down          r   refresh (re-read porcelain)
  k / UP       move selection up            ?   this help
  ENTER        action menu for selection    q   quit

Every action is a normal run of cloud-xdg-provision.sh: dry-run preview
first, explicit y/N confirm (default N), then --apply with the terminal
handed to the child. Refusals from the script render verbatim — the TUI
never overrides them. icloud-evict additionally requires typing the full
local path to acknowledge the data-loss risk (the script's own consent
gate, preserved here).
"""

# Mirrors the script's gate-5 message (cmd_icloud_evict consent guard).
EVICT_WARNING = """icloud-evict can LOSE DATA if 'Optimize Mac Storage' is off or files
aren't uploaded; that OS setting has no reliable programmatic check.
(Safer alternative: --offload <dir> via the offload lane.)

Target: %s

To proceed you must type the full local path exactly.
"""


def refresh_model(executor):
    # type: (Executor) -> list
    """capture --classify --porcelain + --offload-status --porcelain, parse
    both, build_model. Raises PorcelainError on any failure (callers map it
    to a fatal message + exit 1)."""
    rc, out, err = executor.capture(["--classify", "--porcelain"])
    if rc != 0:
        raise PorcelainError(
            "--classify --porcelain failed (rc %d): %s" % (rc, err.strip())
        )
    classify_rows = parse_porcelain(out, "classify")
    rc, out, err = executor.capture(["--offload-status", "--porcelain"])
    if rc != 0:
        raise PorcelainError(
            "--offload-status --porcelain failed (rc %d): %s" % (rc, err.strip())
        )
    status_rows = parse_porcelain(out, "offload-status")
    return build_model(classify_rows, status_rows)


def _show_pane(stdscr, title, text):
    """Scrollable read-only text pane. q/ENTER/ESC closes; j/k/arrows scroll."""
    import curses
    lines = text.splitlines() or ["(no output)"]
    top = 0
    while True:
        stdscr.erase()
        height, width = stdscr.getmaxyx()
        body_rows = max(1, height - 3)
        stdscr.addnstr(0, 0, title, width - 1, curses.A_BOLD)
        for i, line in enumerate(lines[top:top + body_rows]):
            try:
                stdscr.addnstr(1 + i, 0, line, width - 1)
            except curses.error:
                pass  # bottom-right cell write — harmless
        footer = "[%d-%d/%d] j/k scroll · q/ENTER close" % (
            top + 1, min(top + body_rows, len(lines)), len(lines)
        )
        try:
            stdscr.addnstr(height - 1, 0, footer, width - 1, curses.A_REVERSE)
        except curses.error:
            pass
        stdscr.refresh()
        ch = stdscr.getch()
        if ch in (ord("q"), 27, curses.KEY_ENTER, 10, 13):
            return
        if ch in (ord("j"), curses.KEY_DOWN):
            top = min(top + 1, max(0, len(lines) - body_rows))
        elif ch in (ord("k"), curses.KEY_UP):
            top = max(0, top - 1)
        elif ch == curses.KEY_RESIZE:
            continue


def _prompt_line(stdscr, prompt):
    """Echoing single-line prompt on the bottom row. Returns the typed string
    with only the trailing newline removed — no other trimming (§6)."""
    import curses
    height, width = stdscr.getmaxyx()
    stdscr.move(height - 1, 0)
    stdscr.clrtoeol()
    stdscr.addnstr(height - 1, 0, prompt, width - 2)
    stdscr.refresh()
    curses.echo()
    try:
        # Typed consent must be typed AFTER the prompt renders: discard any
        # buffered type-ahead/paste so it cannot feed the acknowledgment.
        curses.flushinp()
        raw = stdscr.getstr(height - 1, min(len(prompt), width - 2), 4096)
    finally:
        curses.noecho()
    return raw.decode("utf-8", "replace")


def _confirm(stdscr, question):
    """Single-key y/N confirm; ONLY a lone 'y' keypress is yes (default N)."""
    import curses
    height, width = stdscr.getmaxyx()
    stdscr.move(height - 1, 0)
    stdscr.clrtoeol()
    stdscr.addnstr(height - 1, 0, question + " (y/N) ", width - 2, curses.A_BOLD)
    stdscr.refresh()
    # Buffered type-ahead/paste must not auto-answer a consent gate; only a
    # 'y' pressed after the question renders is yes (EOF/getch -1 stays No).
    curses.flushinp()
    return stdscr.getch() == ord("y")


def _action_menu(stdscr, entry):
    """Numbered lane menu for one entry; returns an op name or None."""
    import curses
    ops = ops_for_entry(entry)
    if not ops:
        _show_pane(stdscr, entry.local_name,
                   "class '%s' is machine-local/informational — no actions." % entry.klass)
        return None
    stdscr.erase()
    height, width = stdscr.getmaxyx()
    stdscr.addnstr(0, 0, "actions — %s (%s)" % (entry.local_name, entry.klass),
                   width - 1, curses.A_BOLD)
    for i, op in enumerate(ops):
        if 2 + i >= height - 1:
            break
        stdscr.addnstr(2 + i, 0, "  %d) %s" % (i + 1, op), width - 1)
    try:
        stdscr.addnstr(height - 1, 0, "1-%d select · q cancel" % len(ops),
                       width - 1, curses.A_REVERSE)
    except curses.error:
        pass
    stdscr.refresh()
    while True:
        ch = stdscr.getch()
        if ch in (ord("q"), 27):
            return None
        if ch == curses.KEY_RESIZE:
            return None  # cheap: cancel and let the main loop re-render
        if ord("1") <= ch <= ord("9") and (ch - ord("1")) < len(ops):
            return ops[ch - ord("1")]


def _tty_reset():
    """stty-sane-equivalent reset after the child owned the tty."""
    try:
        subprocess.run(["stty", "sane"], check=False)
    except OSError:
        pass


def run_action(stdscr, executor, entry, op):
    """The ONLY mutation path. Sequence (§5 flow / §6): (typed consent if
    required) -> dry-run preview via capture -> confirm -> curses.endwin() ->
    executor.handover -> 'exit N — press Enter' -> stty-sane reset -> curses
    re-init. Always returns a freshly refreshed model."""
    import curses
    home = executor.environ().get("HOME", "")
    if ACTIONS[op]["target"] == "key":
        target = entry.canonical
    else:
        # Path args are always $HOME/<localName> from the executor's env at
        # call time — never free text, never cached at import (§9).
        target = os.path.join(home, entry.local_name)

    typed_ack = None
    if op == "icloud-evict":
        # Typed consent precedes even the preview: the script checks the risk
        # flag before dry-run (gate 5 is unconditional), so no invocation of
        # any kind happens without the exact typed path (§6).
        _show_pane(stdscr, "DATA-LOSS WARNING — icloud-evict", EVICT_WARNING % target)
        typed = _prompt_line(
            stdscr, "Type the full local path to acknowledge the data-loss risk: "
        )
        if typed != target:
            _show_pane(stdscr, "aborted",
                       "Acknowledgment did not match %r — aborted; nothing was run." % target)
            return refresh_model(executor)
        typed_ack = typed

    try:
        argv = plan_action(target, op, confirmed=False, typed_ack=typed_ack)
    except (ConsentError, ValueError) as exc:
        _show_pane(stdscr, "refused (TUI gate)", str(exc))
        return refresh_model(executor)

    rc, out, err = executor.capture(argv)

    if ACTIONS[op]["read_only"]:
        # capture -> verbatim pane; no confirm, no apply (§5).
        _show_pane(stdscr, "%s — exit %d" % (op, rc), out + (("\n" + err) if err else ""))
        return refresh_model(executor)

    if rc != 0:
        # Preview refused: verbatim, NO confirm prompt, no apply (§5).
        _show_pane(stdscr, "%s refused (exit %d)" % (op, rc),
                   (err or out) or "(no output)")
        return refresh_model(executor)

    _show_pane(stdscr, "dry-run preview — %s %s" % (op, target), out)
    if preview_blocks(out):
        _show_pane(stdscr, "blocked", "Preview reports WOULD BLOCK — not offering apply.")
        return refresh_model(executor)
    if not _confirm(stdscr, "Apply %s to %s?" % (op, target)):
        return refresh_model(executor)

    argv_apply = plan_action(target, op, confirmed=True, typed_ack=typed_ack)
    curses.endwin()
    try:
        rc = executor.handover(argv_apply)
        outcome = interpret_result(op, rc, "", "")
        sys.stdout.write(
            "\n[xdg-tui] %s: exit %d (%s) — press Enter to return\n"
            % (op, rc, outcome.status)
        )
        sys.stdout.flush()
        try:
            input()
        except EOFError:
            pass
    finally:
        # Re-enter curses on EVERY path — a crash must never leave the tty raw.
        _tty_reset()
        try:
            curses.reset_prog_mode()
            stdscr.clear()
            stdscr.refresh()
        except curses.error:
            pass
    return refresh_model(executor)


def main_tui(stdscr, executor):
    """Thin loop: render_frame + getch dispatch. Installs the no-op SIGINT
    handler for the whole session (menu-time Ctrl-C must not kill the TUI;
    'q' is the quit path) and restores it on exit."""
    import curses
    prev = signal.signal(signal.SIGINT, _sigint_noop)
    try:
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        stdscr.keypad(True)
        entries = refresh_model(executor)
        selected = 0
        while True:
            stdscr.erase()
            height, width = stdscr.getmaxyx()
            for i, line in enumerate(render_frame(entries, selected, width)):
                if i >= height:
                    break
                try:
                    stdscr.addnstr(i, 0, line, width - 1)
                except curses.error:
                    pass
            stdscr.refresh()
            ch = stdscr.getch()
            if ch in (ord("q"), ord("Q")):
                break
            elif ch in (ord("j"), curses.KEY_DOWN):
                selected = min(selected + 1, max(0, len(entries) - 1))
            elif ch in (ord("k"), curses.KEY_UP):
                selected = max(selected - 1, 0)
            elif ch == ord("r"):
                entries = refresh_model(executor)
                selected = min(selected, max(0, len(entries) - 1))
            elif ch == ord("?"):
                _show_pane(stdscr, "help", HELP_TEXT)
            elif ch == curses.KEY_RESIZE:
                continue  # loop top re-renders at the new size
            elif ch in (curses.KEY_ENTER, 10, 13):
                if not entries:
                    continue
                op = _action_menu(stdscr, entries[selected])
                if op is not None:
                    entries = run_action(stdscr, executor, entries[selected], op)
                    selected = min(selected, max(0, len(entries) - 1))
    finally:
        signal.signal(signal.SIGINT, prev)


def dump(executor):
    # type: (Executor) -> int
    """--dump: one render_frame to stdout, no tty, no curses import. rc 0;
    rc 1 with a message on PorcelainError."""
    try:
        entries = refresh_model(executor)
    except PorcelainError as exc:
        sys.stderr.write("xdg-tui: %s\n" % (exc,))
        return 1
    for line in render_frame(entries, 0, 80):
        sys.stdout.write(line + "\n")
    return 0


def main(argv):
    """--version -> 'xdg-tui <ver>', rc 0. --dump -> dump(). No args -> curses
    dashboard. Unknown/extra args -> usage to stderr, rc 1. --dump/--version
    leave the default SIGINT disposition untouched (§7)."""
    if argv == ["--version"]:
        sys.stdout.write("xdg-tui %s\n" % read_version())
        return 0
    if argv == ["--dump"]:
        return dump(Executor(default_script_path()))
    if argv:
        sys.stderr.write(USAGE)
        return 1
    executor = Executor(default_script_path())
    import curses  # lazy: only the interactive path needs it
    try:
        curses.wrapper(main_tui, executor)  # wrapper guarantees endwin on ANY exit
    except PorcelainError as exc:
        sys.stderr.write("xdg-tui: %s\n" % (exc,))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
