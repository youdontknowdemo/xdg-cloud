"""tests/tui/test_executor.py — Executor seams + entrypoint smokes.

Covers: capture against fake scripts (fixture goldens, large-output full
drain), call-time env resolution (never cached), handover installs a real
HANDLER (callable, not SIG_IGN) and restores prev even on exception, and
subprocess smokes for --dump / --version / lazy-curses import — all with an
injected sandbox env; nothing touches the real $HOME or the real script.
"""
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(
    0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "bin")
)
import xdg_tui  # noqa: E402

from fixtures import CLASSIFY_FIXTURE, STATUS_FIXTURE  # noqa: E402

XDG_TUI_PY = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "bin", "xdg_tui.py"
)
REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
)


class FakeScriptCase(unittest.TestCase):
    """Base: temp sandbox dir + fake-script writer + injected env."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="xdg-tui-test.")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.sandbox_home = os.path.join(self.tmp, "home")
        os.makedirs(self.sandbox_home)

    def write_script(self, body, name="fake-provision.sh"):
        path = os.path.join(self.tmp, name)
        with open(path, "w") as fh:
            fh.write("#!/bin/bash\n" + body)
        os.chmod(path, 0o755)
        return path

    def env(self, **extra):
        base = {
            "HOME": self.sandbox_home,
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        }
        base.update(extra)
        return base

    def write_porcelain_script(self):
        """Fake provision script serving the fixture goldens on the two reads."""
        classify_file = os.path.join(self.tmp, "classify.txt")
        status_file = os.path.join(self.tmp, "status.txt")
        with open(classify_file, "w") as fh:
            fh.write(CLASSIFY_FIXTURE)
        with open(status_file, "w") as fh:
            fh.write(STATUS_FIXTURE)
        return self.write_script(
            'case "$1 $2" in\n'
            '  "--classify --porcelain") cat "%s" ;;\n'
            '  "--offload-status --porcelain") cat "%s" ;;\n'
            '  *) echo "unexpected argv: $*" >&2; exit 64 ;;\n'
            "esac\n" % (classify_file, status_file)
        )


class TestCapture(FakeScriptCase):
    def test_capture_returns_rc_stdout_stderr(self):
        script = self.write_script('printf "hello\\n"; printf "oops\\n" >&2; exit 3\n')
        rc, out, err = xdg_tui.Executor(script, env=self.env()).capture(["--classify"])
        self.assertEqual(rc, 3)
        self.assertEqual(out, "hello\n")
        self.assertEqual(err, "oops\n")

    def test_capture_full_drain_large_output(self):
        # 512 KiB on stdout AND stderr — an early-closed pipe would truncate
        # or SIGPIPE(141) the child; full drain must return every byte.
        script = self.write_script(
            "head -c 524288 /dev/zero | tr '\\0' 'x'\n"
            "head -c 524288 /dev/zero | tr '\\0' 'e' >&2\n"
            "exit 0\n"
        )
        rc, out, err = xdg_tui.Executor(script, env=self.env()).capture([])
        self.assertEqual(rc, 0)
        self.assertEqual(len(out), 524288)
        self.assertEqual(len(err), 524288)

    def test_capture_uses_injected_env(self):
        script = self.write_script('printf "%s" "$HOME"\n')
        rc, out, _ = xdg_tui.Executor(script, env=self.env()).capture([])
        self.assertEqual(rc, 0)
        self.assertEqual(out, self.sandbox_home)

    def test_env_none_resolves_os_environ_at_call_time(self):
        script = self.write_script('printf "%s" "$XDG_TUI_TEST_PROBE"\n')
        executor = xdg_tui.Executor(script)  # env=None -> os.environ per call
        saved = os.environ.get("XDG_TUI_TEST_PROBE")
        try:
            os.environ["XDG_TUI_TEST_PROBE"] = "first"
            self.assertEqual(executor.capture([])[1], "first")
            os.environ["XDG_TUI_TEST_PROBE"] = "second"
            self.assertEqual(executor.capture([])[1], "second")  # not cached
        finally:
            if saved is None:
                os.environ.pop("XDG_TUI_TEST_PROBE", None)
            else:
                os.environ["XDG_TUI_TEST_PROBE"] = saved

    def test_undecodable_bytes_do_not_raise(self):
        script = self.write_script("printf '\\xff\\xfe raw bytes\\n'\n")
        rc, out, _ = xdg_tui.Executor(script, env=self.env()).capture([])
        self.assertEqual(rc, 0)
        self.assertIn("raw bytes", out)  # errors='replace', never UnicodeDecodeError

    def test_refresh_model_joins_the_two_porcelain_reads(self):
        executor = xdg_tui.Executor(self.write_porcelain_script(), env=self.env())
        entries = xdg_tui.refresh_model(executor)
        self.assertEqual(len(entries), 15)
        repos = [e for e in entries if e.canonical == "repos"][0]
        self.assertEqual(repos.state, "inconsistent")

    def test_refresh_model_surfaces_capture_failure(self):
        script = self.write_script('echo "unknown flag: --porcelain" >&2; exit 1\n')
        executor = xdg_tui.Executor(script, env=self.env())
        with self.assertRaises(xdg_tui.PorcelainError):
            xdg_tui.refresh_model(executor)


class TestHandover(FakeScriptCase):
    def _quiet_script(self, body):
        # Handover inherits the test runner's fds; keep its output out of them.
        return self.write_script("exec >/dev/null 2>&1\n" + body)

    def test_handover_returns_child_rc(self):
        script = self._quiet_script("exit 7\n")
        self.assertEqual(xdg_tui.Executor(script, env=self.env()).handover([]), 7)

    def test_handover_passes_through_rc_130(self):
        script = self._quiet_script("exit 130\n")
        rc = xdg_tui.Executor(script, env=self.env()).handover([])
        self.assertEqual(rc, 130)
        self.assertEqual(xdg_tui.interpret_result("offload", rc, "", "").status,
                         "interrupted")

    def test_handover_installs_a_handler_never_sig_ign(self):
        # Observe the SIGINT disposition WHILE the child runs (getsignal is
        # safe from a non-main thread; signal() itself is main-thread-only).
        script = self._quiet_script("sleep 0.3\nexit 0\n")
        observed = []

        def observer():
            time.sleep(0.1)
            observed.append(signal.getsignal(signal.SIGINT))

        prev = signal.getsignal(signal.SIGINT)
        thread = threading.Thread(target=observer)
        thread.start()
        rc = xdg_tui.Executor(script, env=self.env()).handover([])
        thread.join()
        self.assertEqual(rc, 0)
        self.assertEqual(len(observed), 1)
        during = observed[0]
        self.assertIs(during, xdg_tui._sigint_noop)   # the no-op HANDLER...
        self.assertTrue(callable(during))
        self.assertIsNot(during, signal.SIG_IGN)      # ...NEVER SIG_IGN (§7)
        self.assertIs(signal.getsignal(signal.SIGINT), prev)  # restored after

    def test_handover_restores_prev_handler_on_exception(self):
        def sentinel(signum, frame):
            pass

        prev = signal.signal(signal.SIGINT, sentinel)
        try:
            executor = xdg_tui.Executor(os.path.join(self.tmp, "does-not-exist"),
                                        env=self.env())
            with self.assertRaises(OSError):
                executor.handover(["--offload", "repos", "--apply"])
            self.assertIs(signal.getsignal(signal.SIGINT), sentinel)  # finally ran
        finally:
            signal.signal(signal.SIGINT, prev)


class TestEntrypointSmokes(FakeScriptCase):
    """--dump/--version via subprocess: no tty, injected env, fixture script."""

    def _run(self, args, **env_extra):
        return subprocess.run(
            [sys.executable, XDG_TUI_PY] + args,
            capture_output=True,
            text=True,
            env=self.env(**env_extra),
            stdin=subprocess.DEVNULL,  # prove no tty is needed
        )

    def test_dump_renders_one_frame_rc0(self):
        proc = self._run(["--dump"], XDG_TUI_SCRIPT=self.write_porcelain_script())
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("repos", proc.stdout)
        self.assertIn("inconsistent", proc.stdout)
        # note content is asserted un-clipped in test_model; the 80-col dump
        # frame clips long detail columns by design
        self.assertIn("-> /sandbox/cloud/documents", proc.stdout)
        self.assertTrue(all(len(line) <= 80 for line in proc.stdout.splitlines()))

    def test_dump_porcelain_error_is_rc1_with_message(self):
        script = self.write_script('printf "porcelain=99\\n"\n')
        proc = self._run(["--dump"], XDG_TUI_SCRIPT=script)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("porcelain", proc.stderr)

    def test_version_matches_version_file(self):
        with open(os.path.join(REPO_ROOT, "VERSION")) as fh:
            expected = fh.read().split()[0]
        proc = self._run(["--version"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "xdg-tui %s\n" % expected)

    def test_unknown_arg_is_usage_rc1(self):
        proc = self._run(["--frobnicate"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("usage:", proc.stderr)

    def test_extra_args_after_dump_refused(self):
        proc = self._run(["--dump", "extra"])
        self.assertEqual(proc.returncode, 1)

    def test_module_imports_without_curses(self):
        # CORE/EXECUTOR (and --dump/--version) must never import curses:
        # poison the import and prove `import xdg_tui` + --dump still work.
        code = (
            "import sys; sys.modules['curses'] = None; "
            "sys.path.insert(0, %r); import xdg_tui; "
            "sys.exit(xdg_tui.main(['--version']))"
            % os.path.join(REPO_ROOT, "bin")
        )
        proc = subprocess.run(
            [sys.executable, "-c", code],
            capture_output=True,
            text=True,
            env=self.env(),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(proc.stdout.startswith("xdg-tui "))


if __name__ == "__main__":
    unittest.main()
