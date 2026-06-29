# PR #11 — DevOps Verify-Only Re-Review of the Trap Fix (commit 5ee261a)

**Reviewer:** devops-reviewer (independent)
**Scope:** narrow — only remediation commit `5ee261a` against my first-round BLOCKING finding.
**Method:** `git show 5ee261a`, full-file re-read, `shellcheck -s bash` (exit 0), `make test` (PASS), plus **two independent empirical interrupt tests** I ran myself (the suite's SIGTERM path, and a real-SIGINT-under-job-control path the suite cannot use).

## Verdict: ✅ RESOLVED — clear to merge on this axis

My BLOCKING B1 is genuinely fixed, **and** the coder caught a second, deeper BLOCKING bug in the same area that I had missed (subshell-scoped flags). Both are fixed and now covered by a real interrupt regression test. shellcheck clean, full suite green including the new interrupt group.

---

## Checklist results

### ✅ Separate `trap on_signal INT TERM` that cleans up then `exit 130`
**RESOLVED** — `bin/cloud-xdg-provision.sh:171-183`
```sh
on_signal() { cleanup_handler; exit 130; }
install_cleanup_trap() {
  trap cleanup_handler EXIT
  trap on_signal INT TERM
}
```
The EXIT path and the signal path now have distinct handlers. A signal runs cleanup then terminates the script non-zero instead of resuming. The EXIT trap fires once more on the way out, but the handler is idempotent (below), so it's a no-op.

### ✅ Script no longer continues mutating after a signal
**RESOLVED — empirically proven twice.**
- `make test` interrupt group: both windows assert `exit 130` and data-safe — all 8 assertions pass.
- My own independent SIGINT test (real `kill -INT`, run under `set -m` so SIGINT is **not** SIG_IGN'd — the foreground-Ctrl-C disposition):
  ```
  exit code on SIGINT: 130   (expect 130)
  recovery line present? YES
  payload safe in aside? YES (…/Documents.pre-offload-20260629-154035)
  stale lock left? released
  did script resume past interrupt? terminated cleanly
  ```
  No post-interrupt `mv`/`ln`/`Wrote`/mapping output — the script terminated at the signal instead of completing the relocate. This is the exact defect from round 1, now closed.

### ✅ `cleanup_handler` idempotent (my M4)
**RESOLVED** — `:147-161`. `PROBE_ACTIVE=0` and `RELOCATE_ACTIVE=0` are now set after each branch acts (`LOCK_OWNED=0` already was). So the second pass (EXIT trap after `on_signal`'s `exit 130`) prints nothing and re-reverts nothing. No double-print observed in either empirical run.

### ✅ Trap installed BEFORE `acquire_lock` (my M1)
**RESOLVED** — `main()` `:750-751` now orders `install_cleanup_trap` then `acquire_lock`. The handlers are flag/`LOCK_OWNED`-gated, so arming before any work is a safe no-op, and a signal during lock acquisition can no longer strand the lock dir (proven: "stale lock left? released").

### ✅ SIGTERM is a sound substitute for SIGINT in the test
**CONFIRMED sound — and I closed the residual doubt empirically.**

The coder's reasoning is correct: a `&`-backgrounded job in a **non-interactive** shell (the test harness) has SIGINT/SIGQUIT set to `SIG_IGN` on entry, and POSIX forbids a non-interactive shell from trapping a signal that was ignored on entry — so `kill -INT` to the child would be silently dropped and test nothing. SIGTERM is not ignored for background jobs. Since production traps **both** with the **same** handler (`trap on_signal INT TERM`), SIGTERM exercises the identical code path.

**Could the test pass while real Ctrl-C differs?** I checked directly rather than trust the argument: I re-ran the real script with an actual `kill -INT` under `set -m` (job control on → the child does **not** inherit `SIG_IGN` for INT, matching a foreground terminal). SIGINT produced the identical outcome as the suite's SIGTERM — `exit 130`, recovery printed, data in aside, lock released, no resume. So the two signals are behaviorally identical here, and the SIGTERM-based test faithfully represents real foreground Ctrl-C. No divergence found.

### ✅ Any lock-leak / resume path that survives the fix?
- **Resume path:** none — `on_signal` exits. Proven.
- **Lock leak:** the only residual is the irreducible one-instruction window in `acquire_lock` between `mkdir "$LOCK_DIR"` succeeding (`:208`) and `LOCK_OWNED=1` (`:209`); a signal landing exactly there leaves `LOCK_OWNED=0` so the handler won't `rmdir`. It is recoverable (next run prints the exact `rmdir`), vanishingly improbable, and cannot be closed without a more contorted set-flag-before-mkdir-and-unset-on-failure dance that adds its own risk. **Not worth fixing — note only.**

---

## Bonus: a deeper bug the coder caught that round 1 missed

The commit fixes a **second** BLOCKING regression I did not find: `relocate_dir` ran inside the `printf '%s\n' "$OFFLOAD_SET" | while …` **pipe subshell**, so the `PROBE_ACTIVE`/`RELOCATE_ACTIVE` flags it raised never reached the parent shell that owns the cleanup trap (and the subshell's traps are reset to default). On a mid-relocate signal that silently disabled probe-revert + recovery, stranding `~/Documents` as `~/Documents.tcc-probe.PID`. Fix: de-pipe the relocate-driving loop into a here-doc (`done <<EOF … EOF`) so the loop and `relocate_dir` run in the parent shell (`main()` `:762-778`); the two other `printf|while` loops (`ensure_cloud_tree`, `write_user_dirs`) stay piped since they set no flags. The new test's `recovery message printed` assertion specifically proves the `RELOCATE_ACTIVE` flag now reaches the parent handler. Good catch and a correct, minimal fix.

---

## Out of scope (not regressions — carried over from round 1)

These were MINOR findings in `pr11-devops.md`, not part of this trap remediation, and remain open:
- **M2** — unwritable `$XDG_CACHE_HOME` still misreported as "another run is in progress" (`acquire_lock`).
- **M3** — `write_user_dirs` backup-name check uses `[ -e ]` only vs `relocate_dir`'s `[ -e ] || [ -L ]`.

Neither blocks; flagging so they aren't lost.

---

## Tooling

| Check | Result |
|-------|--------|
| `shellcheck -s bash bin/cloud-xdg-provision.sh` | **exit 0** |
| `make test` (incl. new PR#11 interrupt group) | **PASS**, exit 0 |
| Independent SIGTERM interrupt (suite) | exit 130, data-safe, lock released |
| Independent real-SIGINT interrupt (`set -m`) | exit 130, data-safe, lock released, no resume |
