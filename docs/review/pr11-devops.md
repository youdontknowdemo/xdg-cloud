# PR #11 — Independent DevOps / Shell-Quality Review

**Reviewer:** devops-reviewer (independent — did NOT author this PR)
**Scope:** `bin/cloud-xdg-provision.sh`, `tests/smoke.sh` (commits bb78890 trap unification + #4/#5/#6/#7/#9 hardening)
**Method:** `gh pr diff 11`, full-file read for context, `shellcheck -s bash` (0.11.0), `make test`, and two targeted empirical experiments (signal handling, unwritable cache).

## Verdict

One **BLOCKING** defect in the trap unification: the `INT`/`TERM` handler does **not exit**, so a signal releases the concurrency lock and the script then **keeps running and exits 0**. Empirically reproduced. Everything else is solid — shellcheck clean, bash 3.2 clean, 70+ smoke assertions pass.

---

## Tooling results

| Check | Result |
|-------|--------|
| `shellcheck -s bash bin/cloud-xdg-provision.sh` | **exit 0** (no findings) |
| `make test` | **PASS** (smoke: PASS, exit 0) |
| bash 3.2 scan (`[[`, arrays, `mapfile`, `<()`, namerefs, `${v^}`) | **clean** (only the comment at line 27) |
| `trap` install sites | exactly **one** (`install_cleanup_trap`, line 153) — no clobbering |
| `local_name` call sites | one, matches new 2-arg signature (line 440) |

---

## BLOCKING

### B1 — `INT`/`TERM` trap handler does not exit; script resumes after a signal with the lock already released
**File:** `bin/cloud-xdg-provision.sh:137` (`cleanup_handler`), `:153` (`install_cleanup_trap`)

`install_cleanup_trap` installs **one** handler on `EXIT INT TERM`:

```sh
install_cleanup_trap() { trap cleanup_handler EXIT INT TERM; }
```

`cleanup_handler` releases the lock and prints recovery, but **never calls `exit`**. In bash, a trapped `INT`/`TERM` runs the handler and then **resumes execution at the point of interruption** — it does not terminate the script. So on Ctrl-C / SIGTERM:

1. `cleanup_handler` runs → **lock dir is removed, `LOCK_OWNED=0`**.
2. The handler returns → **the script continues executing**, still mutating the filesystem, now with **no lock** — exactly the window `#5c` exists to protect. A second invocation started at this moment would race the relocate `mv`→`ln` window.
3. The process eventually **exits 0**, so any caller/automation believes the run succeeded.
4. If interrupted in the `RELOCATE_ACTIVE` window, the handler prints *"INTERRUPTED mid-relocate — your data is SAFE…"* and then the script **completes the `mv` + `ln s` anyway** — the recovery message is a false alarm.

This directly falsifies the code's own documented invariant (lines 133–134): *"release the concurrency lock … on EVERY exit path (success, die/error, INT/TERM) so a crash never strands a stale lock"* — it releases too early and on a non-exit path.

**Empirical proof** (minimal reproduction of the same trap shape):

```
lock acquired, sleeping (simulating long rsync)...
>>> sending SIGINT to script
  HANDLER: releasing lock
!!! SCRIPT CONTINUED PAST THE SLEEP AFTER SIGNAL !!! (lock dir exists now? no)
doing more filesystem mutation here, UNPROTECTED by lock
script final exit: 0
```

The script ran its post-sleep body **after** SIGINT and exited 0, with the lock already gone.

**Why it matters here:** data loss is bounded (the retained `aside` backup is the real safety net), so this is not an algedonic HALT — but the concurrency guarantee and the exit-code/recovery-message contracts are all broken on the single most common interruption (Ctrl-C on a long rsync).

**Fix (sketch):** split the signal path from the EXIT path so signals terminate:

```sh
on_signal() { cleanup_handler; exit 130; }   # 130 INT / 143 TERM if you want to distinguish
install_cleanup_trap() {
  trap cleanup_handler EXIT
  trap on_signal INT TERM
}
```

When `on_signal` calls `exit`, the `EXIT` trap fires `cleanup_handler` again — so also make the handler idempotent (see M4): zero `PROBE_ACTIVE`/`RELOCATE_ACTIVE` after acting, not just `LOCK_OWNED`, or the recovery message double-prints.

---

## MINOR

### M1 — Lock-leak window: trap is installed *after* the lock is acquired
**File:** `bin/cloud-xdg-provision.sh:718-719` (`main`)

```sh
acquire_lock          # mkdir lock, LOCK_OWNED=1  (line 177-178)
install_cleanup_trap  # trap installed AFTER
```

A signal arriving between the successful `mkdir "$LOCK_DIR"` and the `trap` install runs the **default** disposition (no handler yet) → the lock dir is stranded. Small window, recoverable (next run prints the exact `rmdir`), but it is a genuine leak path and contradicts the "every exit path" claim.

**Fix:** install the trap **before** `acquire_lock` (the handler is fully flag-gated — `LOCK_OWNED=0`, `PROBE_ACTIVE=0`, `RELOCATE_ACTIVE=0` until armed — so an early install is a safe no-op). This also pairs naturally with B1's `on_signal` split. Closes the window down to the single `LOCK_OWNED=1` assignment.

### M2 — Unwritable `$XDG_CACHE_HOME` is misreported as "another run is in progress"
**File:** `bin/cloud-xdg-provision.sh:177-182` (`acquire_lock`)

`mkdir "$LOCK_DIR" 2>/dev/null` swallows **all** failures, so an `EACCES` on a non-writable cache dir falls into the `else` branch and dies with the *lock-collision* message and stale-lock `rmdir` advice — which cannot fix a permissions problem.

**Empirical proof** (cache dir `chmod 500`):
```
error: another run is in progress (lock: .../rocache/cloud-xdg-provision.lock).
  If no other run is active, the lock is stale — remove it and retry: rmdir '...'
```

**Fix:** after a failed `mkdir`, distinguish the cases, e.g. `if [ ! -d "$LOCK_DIR" ]; then die "cannot create lock under $XDG_CACHE_HOME (permission?)"; fi` before the "another run" message. (`mkdir -p "$XDG_CACHE_HOME"` at line 176 would itself abort under `set -e` if the *parent* is unwritable, which is the cleaner fail — but the existing-but-unwritable case reaches the misleading branch.)

### M3 — Backup-name collision check is weaker than the relocate aside check
**File:** `bin/cloud-xdg-provision.sh:661` (`write_user_dirs`)

```sh
while [ -e "$bak" ]; do bak="${f}.bak-${stamp}.${n}"; n=$((n + 1)); done
```

`relocate_dir` (line 568) correctly guards with `[ -e "$aside" ] || [ -L "$aside" ]`, but the backup loop checks `-e` only. A **dangling symlink** sitting at the `.bak-<stamp>` path passes `-e` as false, so `cp "$f" "$bak"` then follows the dead link and writes to its (missing) target rather than creating the backup. Vanishingly rare, but trivially fixable and worth matching the relocate convention for consistency.

### M4 — `cleanup_handler` is not fully idempotent
**File:** `bin/cloud-xdg-provision.sh:137-151`

Only `LOCK_OWNED` is reset after acting; `PROBE_ACTIVE` and `RELOCATE_ACTIVE` are not. Today this is benign (handler fires once on EXIT). But the moment B1 is fixed (signal handler → `exit` → EXIT trap re-runs the handler), the recovery message will print twice and the probe-revert `mv` will run twice (harmless via `|| true`, but noisy). Reset all three flags after handling so a second invocation is a clean no-op.

---

## FUTURE / test-gap

### F1 — The signal-release path of the lock is untested
**File:** `tests/smoke.sh` (#5c group, ~line 519-531)

The `#5c` test asserts *"lock released on exit — no stale lock remains (master cleanup trap fired)"* — but only for a **normal** exit. The `INT`/`TERM` release path (the one broken in B1) has **no test**, which is why the suite is green despite B1. Add a regression test: background an `--apply --relocate` run, `kill -INT` it mid-relocate, then assert (a) the lock dir is gone, (b) the exit code is **non-zero**, and (c) the script did **not** continue past the interruption. This would have caught B1 and will guard the fix.

---

## Confirmed-correct (adversarial checks that passed)

- **#4 multi-mount, array-free** (`resolve_cloud_root:254-271`): zero-match → literal glob skipped by `[ -d "$d/My Drive" ]` → `count=0` die; spaces in paths quoted throughout; counting/`first` survive because the loop is a real `for` (not a pipe subshell). Correct.
- **#7 `local_name`** (`:380`, call `:440`): signature reduced to `(mac, lin)`, sole call site updated, no stale 3-arg callers. Correct.
- **`is_redirected`** (`:390`): single source of truth; `redirect_one` and `write_user_dirs` call it identically so the symlink layer and `user-dirs.dirs` can't disagree; downloads exception correct. Correct.
- **#5a root guard** (`:159`): `[ "$(id -u)" = "0" ]`, called first in `main`. Correct.
- **#5b backup uniqueness** (`:657-664`): counter loop guarantees a free name (modulo M3's dangling-symlink edge). Correct.
- **PROBE revert** (`:138-140`): reverts `src`→ from probe; no-op via `|| true` if the rename never happened. Correct (but see B1/M4 for the resume-after-signal interaction).
- **`set -euo pipefail` interactions**: `ls -lde … || true`, `verify_copy … || die`, `is_redirected … || continue/return` all neutralize `set -e` correctly; `printf | while` trailing-empty-line ends pipelines at status 0.
- **bash 3.2**: no `[[`, arrays, `mapfile`, `<()`, namerefs, or `${v^}`; `printf %q` and `ls -lde`/`stat` are correctly platform-gated.
- **shellcheck**: clean. **make test**: all groups pass.

---

## Recommendation

Address **B1** before merge (signal handler must `exit`); fold in **M1** (reorder trap-before-lock) and **M4** (idempotent handler) as part of the same change since they interlock. **M2/M3** are cheap polish. **F1** should land with the B1 fix to lock in the regression. The non-trap hardening (#4/#5a/#5b/#6/#7/#9) is correct and well-tested.
