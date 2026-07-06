"""tests/tui/test_integration.py — TEST-phase integration for the xdg-tui seams.

Drives the REAL bin/cloud-xdg-provision.sh through the TUI's own seams
(Executor.capture for porcelain reads, Executor.handover for the interrupt
contract, plan_action for every argv) inside a throwaway sandbox. Nothing here
ever touches the real $HOME: the executor env is fully injected (HOME, XDG_*,
GIT_CEILING_DIRECTORIES, RCLONE_CONFIG, CODE_REMOTE/CODE_DEST), and every
--apply is preceded by a containment self-check that the resolved target lives
under the sandbox.

Covered (plan Test Phase P1 + spec §7):
  * Round-trip: offload a pushed repo container via a real `rclone` [loc]
    type=local remote -> porcelain shows offloaded -> hydrate -> payload
    byte-identical.  (skips without rclone/git)
  * SIGINT mid-apply (spec §7, split in two):
      - mid-copy: rc == +130 (the trap's `exit 130`, NOT -SIGINT death),
        interpret_result -> 'interrupted', lock released, container
        byte-intact, no state file, refresh truthfully shows 'local'.
      - drop-window (--aside re-verify): the child's "INTERRUPTED
        mid-offload-drop" recovery message appears in the captured tty
        stream — the SIG_IGN-regression message tripwire the research doc
        demands. (The message only exists inside the OFFLOAD_ACTIVE window,
        which an interrupt-during-copy never reaches; hence two tests.)
  * Read-back-fail relay: SHIM_CHECK=fail -> nonzero rc surfaced as a
    failure state ('refused'), container intact, no state file.
  * Aborted evict is read-only: a mismatched typed acknowledgment builds NO
    mutating argv ever; only the two read-only porcelain refresh reads run.
    RULING (spec-strictness question settled): the post-abort refresh_model
    IS spec-conformant — §5 classes `refresh` as a read-only capture op and
    run_action's contract is "always returns a freshly refreshed model".

Design note — deterministic SIGINT delivery: Executor.handover hides the
child pid (subprocess.run), so instead of racing a timer against process
discovery, the interrupt shims deliver `kill -INT $PPID` from INSIDE the
rclone call. run() executes commands in the script's own shell process, so
$PPID is the provision-script bash — exactly where tty Ctrl-C would land.
This is strictly less flaky than sleep-then-signal and still catches the
SIG_IGN inheritance regression: if handover ever installs SIG_IGN, the child
bash cannot trap INT (POSIX: signals ignored on entry to a non-interactive
shell cannot be trapped), the shim's signal is discarded, the offload runs
to completion, and the rc==130 assertions fail loudly.
"""
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "bin")
)
import xdg_tui  # noqa: E402

from fixtures import CLASSIFY_FIXTURE, STATUS_FIXTURE  # noqa: E402

REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
)
PROVISION = os.path.join(REPO_ROOT, "bin", "cloud-xdg-provision.sh")

HAVE_GIT = shutil.which("git") is not None
HAVE_RCLONE = shutil.which("rclone") is not None


def _have_curses():
    try:
        import curses  # noqa: F401
        return True
    except ImportError:
        return False


def tree_digest(root, files_only=False):
    """Sorted (relpath, kind, sha256) snapshot — byte-level intactness proof.

    files_only=True compares file/symlink content and ignores empty dirs:
    rclone copy does not replicate empty directories (no
    --create-empty-src-dirs in the script), so a hydrate round-trip is
    file-identical but may drop empty .git/* dirs — known rclone semantics,
    accepted by the C12 smoke round-trip too. Intactness assertions on a
    NEVER-transferred container still use the strict full-tree form."""
    items = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        if not files_only:
            rel = os.path.relpath(dirpath, root)
            items.append(("d", rel, ""))
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            rel_f = os.path.relpath(path, root)
            if os.path.islink(path):
                items.append(("l", rel_f, os.readlink(path)))
                continue
            with open(path, "rb") as fh:
                items.append(("f", rel_f, hashlib.sha256(fh.read()).hexdigest()))
    return sorted(items)


class SandboxCase(unittest.TestCase):
    """Throwaway sandbox + injected env + git/rclone fixtures (smoke.sh idioms
    ported to python: mk_pushed_repo, mk_rclone_shim, capture-then-inspect)."""

    PAYLOAD = b"PAYLOAD-tui-integration\x00\xffbytes\n"

    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="xdg-tui-itest."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = os.path.join(self.tmp, "home")
        self.remote_root = os.path.join(self.tmp, "remote")
        os.makedirs(self.home)
        os.makedirs(os.path.join(self.tmp, "tmp"))

    # --- env -------------------------------------------------------------
    def sandbox_env(self, path_prefix=None, **extra):
        path = os.environ.get("PATH", "/usr/bin:/bin")
        if path_prefix:
            path = path_prefix + os.pathsep + path
        env = {
            "HOME": self.home,
            "PATH": path,
            "TMPDIR": os.path.join(self.tmp, "tmp"),
            "XDG_STATE_HOME": os.path.join(self.home, "state"),
            "XDG_CACHE_HOME": os.path.join(self.home, ".cache"),
            "GIT_CEILING_DIRECTORIES": self.home,
            "CODE_REMOTE": "loc",
            "CODE_DEST": self.remote_root,
        }
        env.update(extra)
        return env

    def assert_contained(self, env, canonical="repos"):
        """Containment self-check — MUST pass before any --apply reaches the
        real script (plan P0 harness rule)."""
        real_home = os.path.realpath(os.path.expanduser("~"))
        for key in ("HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "CODE_DEST"):
            resolved = os.path.realpath(env[key])
            self.assertTrue(
                resolved == self.tmp or resolved.startswith(self.tmp + os.sep),
                "%s=%r escapes the sandbox %r" % (key, env[key], self.tmp),
            )
        self.assertNotEqual(os.path.realpath(env["HOME"]), real_home,
                            "sandbox HOME must never be the real $HOME")
        target = os.path.realpath(os.path.join(env["HOME"], canonical))
        self.assertTrue(
            target.startswith(self.tmp + os.sep),
            "resolved --apply target %r escapes the sandbox" % (target,),
        )
        self.assertIn("GIT_CEILING_DIRECTORIES", env)

    # --- fixtures ----------------------------------------------------------
    def mk_pushed_repo(self):
        """~/repos/proj: clean, committed, pushed to an in-sandbox bare remote
        (so the offload guards G2/G3/G4 all pass), carrying a known payload."""
        proj = os.path.join(self.home, "repos", "proj")
        bare = os.path.join(self.tmp, "origin.git")
        os.makedirs(proj)
        with open(os.path.join(proj, "data.bin"), "wb") as fh:
            fh.write(self.PAYLOAD)
        def git(*args, **kw):
            subprocess.run(
                ["git"] + list(args),
                cwd=kw.pop("cwd", proj), check=True,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        git("init", "-q")
        git("add", "-A")
        git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init")
        git("init", "-q", "--bare", bare, cwd=self.tmp)
        git("remote", "add", "origin", bare)
        git("push", "-q", "-u", "origin", "HEAD")
        return os.path.join(self.home, "repos")

    def write_shim(self, body):
        """PATH-shim `rclone` (smoke.sh mk_rclone_shim idiom). Returns its dir."""
        shim_dir = os.path.join(self.tmp, "shim")
        os.makedirs(shim_dir, exist_ok=True)
        path = os.path.join(shim_dir, "rclone")
        with open(path, "w") as fh:
            fh.write("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)
        return shim_dir

    # --- executor plumbing ------------------------------------------------
    def executor(self, env):
        return xdg_tui.Executor(PROVISION, env=env)

    def apply_via_subprocess(self, argv, env):
        """--apply through a direct child (argv from plan_action; handover
        needs no curses in tests and capture gives deterministic output)."""
        self.assert_contained(env)
        proc = subprocess.run(
            [PROVISION] + list(argv),
            capture_output=True, text=True, errors="replace",
            env=env, stdin=subprocess.DEVNULL,
        )
        return proc.returncode, proc.stdout, proc.stderr

    def handover_captured(self, executor, argv):
        """Run Executor.handover (the REAL seam) with fds 1/2 pointed at a
        capture file (spec §7: 'handover fds pointed at a capture file')."""
        cap_path = os.path.join(self.tmp, "handover-capture.txt")
        sys.stdout.flush()
        sys.stderr.flush()
        cap_fd = os.open(cap_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        saved_out = os.dup(1)
        saved_err = os.dup(2)
        try:
            os.dup2(cap_fd, 1)
            os.dup2(cap_fd, 2)
            rc = executor.handover(argv)
        finally:
            os.dup2(saved_out, 1)
            os.dup2(saved_err, 2)
            os.close(saved_out)
            os.close(saved_err)
            os.close(cap_fd)
        with open(cap_path, "r", errors="replace") as fh:
            return rc, fh.read()

    def porcelain_status(self, executor):
        rc, out, err = executor.capture(["--offload-status", "--porcelain"])
        self.assertEqual(rc, 0, err)
        return {r.canonical: r for r in xdg_tui.parse_porcelain(out, "offload-status")}

    def lock_dir(self, env):
        return os.path.join(env["XDG_CACHE_HOME"], "cloud-xdg-provision.lock")

    def state_file(self, env, canonical="repos"):
        return os.path.join(env["XDG_STATE_HOME"], "xdg-cloud", "offloaded", canonical)


@unittest.skipUnless(HAVE_GIT, "git not installed")
@unittest.skipUnless(HAVE_RCLONE, "rclone not installed (round-trip needs a real [loc] type=local remote)")
class TestRoundTripThroughExecutor(SandboxCase):
    """P1 #1: TUI-driven offload -> porcelain offloaded -> hydrate -> bytes identical."""

    def setUp(self):
        super(TestRoundTripThroughExecutor, self).setUp()
        rconf = os.path.join(self.tmp, "rclone.conf")
        with open(rconf, "w") as fh:
            fh.write("[loc]\ntype = local\n")
        self.env = self.sandbox_env(RCLONE_CONFIG=rconf)
        self.container = self.mk_pushed_repo()
        self.payload_path = os.path.join(self.container, "proj", "data.bin")

    def test_offload_hydrate_round_trip(self):
        executor = self.executor(self.env)
        self.assert_contained(self.env)
        before = tree_digest(self.container)
        before_files = tree_digest(self.container, files_only=True)

        # 0) porcelain baseline: repos is local.
        self.assertEqual(self.porcelain_status(executor)["repos"].state, "local")

        # 1) dry-run preview through capture (the TUI's preview path).
        preview_argv = xdg_tui.plan_action("repos", "offload")
        self.assertNotIn("--apply", preview_argv)
        rc, out, err = executor.capture(preview_argv)
        self.assertEqual(rc, 0, err)
        self.assertFalse(xdg_tui.preview_blocks(out), out)
        # dry-run must not have locked or mutated anything:
        self.assertFalse(os.path.exists(self.lock_dir(self.env)))
        self.assertEqual(tree_digest(self.container), before)

        # 2) apply offload with the exact argv plan_action builds.
        rc, out, err = self.apply_via_subprocess(
            xdg_tui.plan_action("repos", "offload", confirmed=True), self.env
        )
        self.assertEqual(rc, 0, "offload --apply failed:\n%s\n%s" % (out, err))
        self.assertEqual(xdg_tui.interpret_result("offload", rc, out, err).status, "ok")
        self.assertFalse(os.path.exists(self.container), "local container not freed")
        self.assertTrue(os.path.isfile(self.state_file(self.env)))
        self.assertFalse(os.path.exists(self.lock_dir(self.env)), "lock left behind")

        # 3) porcelain now reports offloaded, with the loc remote recorded.
        row = self.porcelain_status(executor)["repos"]
        self.assertEqual(row.state, "offloaded")
        self.assertEqual(row.remote, "loc:%s/repos" % self.remote_root)

        # 4) hydrate: preview then apply, same seams.
        rc, out, err = executor.capture(xdg_tui.plan_action("repos", "hydrate"))
        self.assertEqual(rc, 0, err)
        rc, out, err = self.apply_via_subprocess(
            xdg_tui.plan_action("repos", "hydrate", confirmed=True), self.env
        )
        self.assertEqual(rc, 0, "hydrate --apply failed:\n%s\n%s" % (out, err))

        # 5) payload bytes identical; every file byte-identical (empty dirs
        #    excluded — see tree_digest docstring); state cleared.
        with open(self.payload_path, "rb") as fh:
            self.assertEqual(fh.read(), self.PAYLOAD)
        self.assertEqual(tree_digest(self.container, files_only=True), before_files)
        self.assertFalse(os.path.exists(self.state_file(self.env)))
        self.assertEqual(self.porcelain_status(executor)["repos"].state, "local")


@unittest.skipUnless(HAVE_GIT, "git not installed")
class TestSigintMidApply(SandboxCase):
    """P1 #2 (spec §7): the load-bearing interrupt contract, via Executor.handover."""

    # Shim delivers SIGINT to the provision-script bash from INSIDE the copy —
    # deterministic stand-in for Ctrl-C landing mid-copy (see module docstring).
    SHIM_INTERRUPT_MID_COPY = (
        'case "$1" in\n'
        '  listremotes) echo "loc:"; exit 0 ;;\n'
        "  copy) kill -INT $PPID; sleep 1; exit 0 ;;\n"
        "  *) exit 0 ;;\n"
        "esac\n"
    )

    # Faithful copy + passing read-back; the SIGINT lands during the --aside
    # re-verify, i.e. INSIDE the OFFLOAD_ACTIVE drop window, where the master
    # trap prints its recovery message.
    SHIM_INTERRUPT_IN_DROP_WINDOW = (
        'case "$1" in\n'
        '  listremotes) echo "loc:"; exit 0 ;;\n'
        '  copy) d="${4#loc:}"; mkdir -p "$d"; cp -a "$3/." "$d/" 2>/dev/null; exit 0 ;;\n'
        "  check)\n"
        '    case "$4" in\n'
        "      *.pre-offload-*) kill -INT $PPID; sleep 1; exit 0 ;;\n"
        "      *) exit 0 ;;\n"
        "    esac ;;\n"
        "  *) exit 0 ;;\n"
        "esac\n"
    )

    def test_sigint_mid_copy_is_interrupted_lock_released_container_intact(self):
        shim_dir = self.write_shim(self.SHIM_INTERRUPT_MID_COPY)
        env = self.sandbox_env(path_prefix=shim_dir, RCLONE_CONFIG="/dev/null")
        container = self.mk_pushed_repo()
        before = tree_digest(container)
        executor = self.executor(env)
        self.assert_contained(env)

        argv = xdg_tui.plan_action("repos", "offload", confirmed=True)
        rc, captured = self.handover_captured(executor, argv)

        # rc is the trap's own `exit 130` — a +130 int, never -SIGINT death
        # (subprocess reports signal-death as a negative returncode, so this
        # single assertion proves on_signal RAN, not merely that bash died).
        self.assertEqual(rc, 130, "captured child output:\n%s" % captured)
        self.assertEqual(
            xdg_tui.interpret_result("offload", rc, "", captured).status,
            "interrupted",  # NEVER 'ok' (spec §7)
        )
        # the interrupt landed mid-apply, after the copy started:
        self.assertIn("rclone copy", captured)
        # lock: acquired (cache dir exists) and released by the child's trap.
        self.assertTrue(os.path.isdir(env["XDG_CACHE_HOME"]))
        self.assertFalse(os.path.exists(self.lock_dir(env)),
                         "lock wedged after SIGINT — trap did not release it")
        # container byte-intact; the drop window was never reached.
        self.assertEqual(tree_digest(container), before,
                         "container changed across an interrupted offload")
        self.assertFalse(os.path.exists(self.state_file(env)),
                         "state file written despite the interrupt before verify")
        # post-interrupt refresh tells the truth: still local, never 'offloaded'.
        self.assertEqual(self.porcelain_status(executor)["repos"].state, "local")

    def test_sigint_in_drop_window_prints_recovery_message(self):
        """The SIG_IGN-regression MESSAGE tripwire (spec §7 bullet 4): the
        child's own trap output must appear in the captured tty stream. The
        recovery message only exists inside the OFFLOAD_ACTIVE window, so this
        test uses --aside (whose re-verify is shim-controlled) to land the
        interrupt there; payload safety is then proven on the aside dir."""
        shim_dir = self.write_shim(self.SHIM_INTERRUPT_IN_DROP_WINDOW)
        env = self.sandbox_env(path_prefix=shim_dir, RCLONE_CONFIG="/dev/null")
        container = self.mk_pushed_repo()
        executor = self.executor(env)
        self.assert_contained(env)

        # plan_action argv + the script's own --aside modifier (the TUI never
        # builds --aside; this test drives the script's drop window directly
        # through the same handover seam).
        argv = xdg_tui.plan_action("repos", "offload", confirmed=True) + ["--aside"]
        rc, captured = self.handover_captured(executor, argv)

        self.assertEqual(rc, 130, "captured child output:\n%s" % captured)
        self.assertIn("INTERRUPTED mid-offload-drop", captured,
                      "trap recovery message missing — SIG_IGN regression?")
        self.assertIn("your data is SAFE", captured)
        self.assertFalse(os.path.exists(self.lock_dir(env)))
        # the payload survives in the aside dir (mv done, rm never reached):
        asides = [d for d in os.listdir(self.home) if d.startswith("repos.pre-offload-")]
        self.assertEqual(len(asides), 1, "expected exactly one aside dir")
        aside_payload = os.path.join(self.home, asides[0], "proj", "data.bin")
        with open(aside_payload, "rb") as fh:
            self.assertEqual(fh.read(), self.PAYLOAD)


@unittest.skipUnless(HAVE_GIT, "git not installed")
class TestReadBackFailRelay(SandboxCase):
    """P1 #3: SHIM_CHECK=fail — the read-back gate's refusal is surfaced as a
    failure state through the TUI seam and the container is untouched."""

    SHIM_CHECKABLE = (
        'case "$1" in\n'
        '  listremotes) echo "loc:"; exit 0 ;;\n'
        '  copy) d="${4#loc:}"; mkdir -p "$d"; cp -a "$3/." "$d/" 2>/dev/null; exit 0 ;;\n'
        "  check)\n"
        '    case "${SHIM_CHECK:-pass}" in\n'
        "      fail) exit 1 ;;\n"
        "      *)    exit 0 ;;\n"
        "    esac ;;\n"
        "  *) exit 0 ;;\n"
        "esac\n"
    )

    def test_read_back_failure_is_surfaced_and_container_intact(self):
        shim_dir = self.write_shim(self.SHIM_CHECKABLE)
        env = self.sandbox_env(path_prefix=shim_dir, RCLONE_CONFIG="/dev/null",
                               SHIM_CHECK="fail")
        container = self.mk_pushed_repo()
        before = tree_digest(container)
        executor = self.executor(env)

        argv = xdg_tui.plan_action("repos", "offload", confirmed=True)
        rc, out, err = self.apply_via_subprocess(argv, env)

        self.assertNotEqual(rc, 0, "read-back failure must not exit 0")
        outcome = xdg_tui.interpret_result("offload", rc, out, err)
        self.assertNotEqual(outcome.status, "ok")
        self.assertEqual(outcome.status, "refused")  # rc 1 = die/guard
        self.assertIn("read-back verify FAILED", outcome.message)  # verbatim relay
        self.assertEqual(tree_digest(container), before,
                         "container changed after a failed read-back")
        self.assertFalse(os.path.exists(self.state_file(env)))
        self.assertFalse(os.path.exists(self.lock_dir(env)))
        self.assertEqual(self.porcelain_status(executor)["repos"].state, "local")


class RecordingExecutor(object):
    """Duck-typed Executor: serves the porcelain fixtures, records every call,
    and treats any handover as an automatic failure."""

    def __init__(self, test):
        self._test = test
        self.calls = []

    def environ(self):
        return {"HOME": "/sandbox/home"}

    def capture(self, argv):
        argv = list(argv)
        self.calls.append(("capture", argv))
        if argv == ["--classify", "--porcelain"]:
            return (0, CLASSIFY_FIXTURE, "")
        if argv == ["--offload-status", "--porcelain"]:
            return (0, STATUS_FIXTURE, "")
        self._test.fail("unexpected capture argv for an aborted evict: %r" % (argv,))

    def handover(self, argv):
        self.calls.append(("handover", list(argv)))
        self._test.fail("handover ran for an ABORTED evict: %r" % (argv,))


@unittest.skipUnless(_have_curses(), "stdlib curses not importable")
class TestAbortedEvictIsReadOnly(SandboxCase):
    """P1 #5 (auditor focus b): an aborted evict builds NO mutating argv ever;
    the only invocations are the two read-only porcelain refresh reads.
    RULING: refresh-after-abort is spec-conformant (§5 'refresh' = read-only
    capture; run_action always returns a freshly refreshed model)."""

    READ_ONLY_REFRESH = [
        ("capture", ["--classify", "--porcelain"]),
        ("capture", ["--offload-status", "--porcelain"]),
    ]

    def _entry(self, executor):
        entries = xdg_tui.build_model(
            xdg_tui.parse_porcelain(CLASSIFY_FIXTURE, "classify"),
            xdg_tui.parse_porcelain(STATUS_FIXTURE, "offload-status"),
        )
        return [e for e in entries if e.canonical == "projects"][0]

    def _run_aborted_evict(self, typed):
        rex = RecordingExecutor(self)
        entry = self._entry(rex)
        panes = []
        with mock.patch.object(xdg_tui, "_show_pane",
                               lambda stdscr, title, text: panes.append(title)), \
             mock.patch.object(xdg_tui, "_prompt_line",
                               lambda stdscr, prompt: typed), \
             mock.patch.object(xdg_tui, "_confirm",
                               lambda stdscr, q: self.fail(
                                   "y/N confirm reached on an aborted evict")):
            entries = xdg_tui.run_action(None, rex, entry, "icloud-evict")
        return rex, panes, entries

    def test_mismatched_ack_never_builds_a_mutating_argv(self):
        target = "/sandbox/home/Projects"
        for typed in ["/wrong/path", "", target + "/", target + "\n", "projects"]:
            rex, panes, entries = self._run_aborted_evict(typed)
            # ONLY the two read-only refresh reads ran — nothing else, ever:
            self.assertEqual(rex.calls, self.READ_ONLY_REFRESH,
                             "typed=%r leaked an invocation" % (typed,))
            for kind, argv in rex.calls:
                self.assertNotIn("--apply", argv)
                self.assertNotIn("--i-understand-data-loss-risk", argv)
            self.assertIn("aborted", panes)
            self.assertEqual(len(entries), 15)  # a real refreshed model came back

    def test_matched_ack_reaches_the_preview_with_risk_flag_no_apply(self):
        """Control case: the gate opens ONLY on the exact path, and the next
        step is the dry-run preview (risk flag present, --apply absent)."""
        target = "/sandbox/home/Projects"
        rex = RecordingExecutor(self)
        entry = self._entry(rex)
        preview = {}

        def capture(argv):
            argv = list(argv)
            rex.calls.append(("capture", argv))
            if argv[0] == "--icloud-evict":
                preview["argv"] = argv
                return (1, "", "refused by a later gate (fine for this test)")
            if argv == ["--classify", "--porcelain"]:
                return (0, CLASSIFY_FIXTURE, "")
            return (0, STATUS_FIXTURE, "")

        rex.capture = capture
        with mock.patch.object(xdg_tui, "_show_pane", lambda *a: None), \
             mock.patch.object(xdg_tui, "_prompt_line", lambda *a: target), \
             mock.patch.object(xdg_tui, "_confirm",
                               lambda *a: self.fail("confirm after a refused preview")):
            xdg_tui.run_action(None, rex, entry, "icloud-evict")
        self.assertEqual(
            preview.get("argv"),
            ["--icloud-evict", target, "--i-understand-data-loss-risk"],
        )
        self.assertTrue(all("--apply" not in argv for _, argv in rex.calls))
        self.assertTrue(all(kind != "handover" for kind, _ in rex.calls))


@unittest.skipUnless(sys.platform == "darwin", "iCloud lanes are macOS-gated")
@unittest.skipUnless(os.path.exists("/bin/bash"), "/bin/bash required (bash 3.2 code path)")
class TestICloudSyncStatusThroughExecutor(SandboxCase):
    """TEST-phase addition: drive --icloud-sync-status through the TUI's REAL
    seams (plan_action argv -> Executor.capture -> interpret_result) against
    the real provision script in a sandbox. Smoke I3 already proves the bash
    lane; this proves the python relay: rc 0 summary reaches the capture pane,
    and a resolver refusal is relayed VERBATIM as a 'refused' outcome (rc 1).
    Deterministic: sandbox HOME + explicit ICLOUD_ROOT + stub icloud-uploaded
    helper + brctl PATH shim — no real CloudDocs, no real $HOME, ever.
    """

    HELPER_STUB = (
        "#!/bin/bash\n"
        "# basename -> state, one NUL-terminated '<state>\\t<path>' record per\n"
        "# argv arg (the real helper's \\0 record separator), exit 1 on any\n"
        "# not-plain-uploaded file (like the real helper; the lane must\n"
        "# ignore the rc — chunking breaks whole-set exit semantics).\n"
        "rc=0\n"
        'for p; do\n'
        '  b="${p##*/}"\n'
        '  case "$b" in\n'
        "    *_UP*)   printf 'uploaded\\t%s\\0' \"$p\" ;;\n"
        "    *_WAIT*) printf 'not-uploaded\\t%s\\0' \"$p\"; rc=1 ;;\n"
        "    *)       printf 'error\\t%s\\0' \"$p\"; rc=1 ;;\n"
        "  esac\n"
        "done\n"
        'exit "$rc"\n'
    )

    def setUp(self):
        super(TestICloudSyncStatusThroughExecutor, self).setUp()
        # Sandbox CloudDocs root (real dir; self.tmp is already realpath'd, so
        # lexical == physical for every fixture path except the escape links).
        self.cloud = os.path.join(
            self.home, "Library", "Mobile Documents", "com~apple~CloudDocs"
        )
        docs = os.path.join(self.cloud, "documents")
        os.makedirs(docs)
        with open(os.path.join(docs, "r_UP"), "wb") as fh:
            fh.write(b"aaa\n")          # 4 B, helper says uploaded
        with open(os.path.join(docs, "s_WAIT"), "wb") as fh:
            fh.write(b"bb\n")           # 3 B, helper says not-uploaded
        # Provisioned-machine shape: $HOME/Documents is a symlink INTO the
        # root — the exact target run_action builds ($HOME/<localName>).
        os.symlink(docs, os.path.join(self.home, "Documents"))
        # Escape shape: $HOME/Escape resolves OUTSIDE the root.
        outside = os.path.join(self.tmp, "outside")
        os.makedirs(outside)
        os.symlink(outside, os.path.join(self.home, "Escape"))

        # Stub upload-state helper (ICLOUD_HELPER env seam).
        self.helper = os.path.join(self.tmp, "icloud-helper")
        with open(self.helper, "w") as fh:
            fh.write(self.HELPER_STUB)
        os.chmod(self.helper, 0o755)

        # Recording brctl PATH shim: `status` answers from BRCTL_STATUS_FILE,
        # anything else is recorded to BRCTL_LOG (must stay empty — read-only).
        shim_dir = os.path.join(self.tmp, "shim-icloud")
        os.makedirs(shim_dir)
        with open(os.path.join(shim_dir, "brctl"), "w") as fh:
            fh.write(
                "#!/bin/bash\n"
                'if [ "$1" = "status" ]; then cat "$BRCTL_STATUS_FILE" 2>/dev/null; exit 0; fi\n'
                "printf '%s\\n' \"$*\" >> \"$BRCTL_LOG\"\n"
                "exit 0\n"
            )
        os.chmod(os.path.join(shim_dir, "brctl"), 0o755)
        self.brctl_log = os.path.join(self.tmp, "brctl.log")
        status_file = os.path.join(self.tmp, "brctl-status")
        with open(status_file, "w") as fh:
            fh.write("x <com.apple.CloudDocs[1] observer:itest state:caught-up>\n")
        open(self.brctl_log, "w").close()

        self.env = self.sandbox_env(
            path_prefix=shim_dir,
            ICLOUD_ROOT=self.cloud,
            ICLOUD_HELPER=self.helper,
            BRCTL_LOG=self.brctl_log,
            BRCTL_STATUS_FILE=status_file,
        )
        self.assert_contained(self.env, canonical="Documents")

    def _brctl_mutations(self):
        with open(self.brctl_log, "r") as fh:
            return [l for l in fh.read().splitlines()
                    if l.startswith(("download", "evict"))]

    def test_sync_status_summary_reaches_the_capture_pane(self):
        """Happy path: plan_action argv -> capture -> rc 0, summary text in
        the captured stdout (what _show_pane renders), model 'ok'."""
        target = os.path.join(self.env["HOME"], "Documents")  # run_action's shape
        argv = xdg_tui.plan_action(target, "icloud-sync-status")
        self.assertEqual(argv, ["--icloud-sync-status", target])
        self.assertNotIn("--apply", argv)
        self.assertTrue(xdg_tui.ACTIONS["icloud-sync-status"]["read_only"])

        before = tree_digest(self.cloud)
        rc, out, err = self.executor(self.env).capture(argv)
        self.assertEqual(rc, 0, "sync-status failed:\n%s\n%s" % (out, err))
        outcome = xdg_tui.interpret_result("icloud-sync-status", rc, out, err)
        self.assertEqual(outcome.status, "ok")

        # The pane content (stdout) carries the whole summary, with the
        # RESOLVED CloudDocs path — the symlinked $HOME/Documents was accepted.
        docs_resolved = os.path.realpath(os.path.join(self.home, "Documents"))
        self.assertIn("iCloud sync status under: %s" % docs_resolved, out)
        self.assertIn("scanned: 2 file(s)", out)
        self.assertIn("dataless (to download): 0 file(s), 0 B", out)
        self.assertIn("materialized + uploaded (evictable*): 1 file(s), 4 B", out)
        self.assertIn("materialized, NOT uploaded (waiting on iCloud): 1 file(s)", out)
        self.assertIn("container health (brctl status): caught-up", out)

        # Read-only proof at the TUI seam: no lock, no brctl mutation verbs,
        # fixture tree byte-identical.
        self.assertFalse(os.path.exists(self.lock_dir(self.env)),
                         "read-only sync-status left a lock dir")
        self.assertEqual(self._brctl_mutations(), [],
                         "read-only sync-status invoked brctl download/evict")
        self.assertEqual(tree_digest(self.cloud), before,
                         "sync-status mutated the fixture tree")

    def test_escape_refusal_is_relayed_verbatim_as_refused(self):
        """Refusal relay: an entry whose $HOME/<localName> resolves OUTSIDE
        the root gets the resolver's die (rc 1) relayed VERBATIM through
        interpret_result -> 'refused' (message == stderr, untouched)."""
        target = os.path.join(self.env["HOME"], "Escape")
        argv = xdg_tui.plan_action(target, "icloud-sync-status")
        rc, out, err = self.executor(self.env).capture(argv)

        self.assertEqual(rc, 1, "escape target must be refused:\n%s\n%s" % (out, err))
        outcome = xdg_tui.interpret_result("icloud-sync-status", rc, out, err)
        self.assertEqual(outcome.status, "refused")
        self.assertEqual(outcome.message, err)  # verbatim relay, no rewriting
        self.assertIn("path is not under iCloud Drive", outcome.message)
        # The refusal names the RESOLVED (physical) out-of-root path:
        self.assertIn(os.path.realpath(os.path.join(self.home, "Escape")),
                      outcome.message)
        # Nothing reached brctl; nothing locked.
        self.assertEqual(self._brctl_mutations(), [])
        self.assertFalse(os.path.exists(self.lock_dir(self.env)))


if __name__ == "__main__":
    unittest.main()
