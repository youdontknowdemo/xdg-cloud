# PR #11 — Architecture Review (design coherence)

**Reviewer:** architect · **Angle:** trap unification, `is_redirected` abstraction, ACL placement, cross-commit coherence
**Target:** `bin/cloud-xdg-provision.sh` (PR #11: commits 495043d ACL, bb78890 hardening, 9b02d14 reconcile)
**Verdict:** No BLOCKING issues. The three commits cohere and are well-sequenced. Findings below are MINOR/FUTURE — mostly robustness and maintainability hardening, not correctness defects.

---

## What's architecturally right (called out, not filler)

1. **Trap unification is the correct response to a real constraint, and it's a prerequisite — not just a tidy-up.** bash 3.2 allows one handler per signal with no trap-stacking (`cleanup_handler`, lines 124-151). The #5c lock could *not* have been bolted on as a 4th `trap`/`trap -` pair — it would clobber the probe/recovery traps. So bb78890's unification **enables** the hardening that follows. Good sequencing: the refactor and the feature it unblocks are in the right order.
2. **Lock ownership guard is exactly right.** `LOCK_OWNED` gates release (lines 147-150) so a run that *failed to acquire* the lock (another run holds it, die at 180) never `rmdir`s a lock it didn't create. This is the one property that matters most for a mkdir-lock, and it holds.
3. **`is_redirected` eliminates a genuine latent divergence bug.** Before 9b02d14 the symlink layer (`redirect_one`) and the `user-dirs.dirs` layer (`write_user_dirs`) computed "is this redirected?" independently and could disagree — `user-dirs.dirs` could point an XDG var at the cloud while `~/<dir>` stayed a local dir. One predicate (390-394) used by both call sites (434, 676) makes disagreement structurally impossible. Strong DRY / SoC win.
4. **ACL detection by constraint, not by proxy.** Detection keys on the actual `deny delete` ACE (`ls -lde` + case-match, 540-542), not a hardcoded folder-name list — so it covers the standard special folders *and* any other ACL-protected dir, while letting unprotected custom dirs (Projects/Templates) relocate. The *advice* sub-switch is by name (545-555) with a generic `*` fallback — correct split: robust detection, specific guidance.
5. **ACL caught before B5 and B2 (539, ahead of 577 and 597).** Fail-fast with the accurate message before any copy/probe/move side effect. The comment's rationale (536-537) matches the code.
6. **Probe flag raised before the rename (599, before 600)** closes the sub-millisecond strand window; revert is a harmless no-op if the rename never happened (verified: `$probe` absent → `mv … || true`).

---

## MINOR

### M1 — `cleanup_handler` is not idempotent for PROBE/RELOCATE (asymmetric with LOCK)
`bin/cloud-xdg-provision.sh:137-151`
The lock branch resets its flag after acting (`LOCK_OWNED=0`, line 149). The PROBE branch (138-140) and RELOCATE branch (141-146) do **not** reset their flags. On a signal, bash runs the INT/TERM trap *and then* the EXIT trap fires on exit — so `cleanup_handler` can run twice. Result: the "INTERRUPTED mid-relocate" block prints **twice**, and the probe-revert `mv` is attempted twice (second is a no-op, so harmless). Cosmetic for the lock (guarded) and probe (no-op), but the duplicated recovery message is user-facing noise at exactly the moment you want a single clear message.
**Fix:** mirror line 149 — set `PROBE_ACTIVE=0` after the revert and `RELOCATE_ACTIVE=0` after the warns. Makes the handler fully idempotent against double-fire.

### M2 — Trap installed *after* the lock is acquired (ordering window)
`bin/cloud-xdg-provision.sh:718-719`
`acquire_lock` (718) sets `LOCK_OWNED=1`, then `install_cleanup_trap` (719) installs the handler. A signal landing in the gap between these two statements (after the lock dir exists, before the trap is armed) strands the lock dir with no cleanup. Narrow and recoverable (the die message tells the user how to `rmdir` a stale lock), but free to shrink.
**Fix:** install the trap *before* `acquire_lock`. The handler is flag-gated and a complete no-op while all flags are 0, so arming it early costs nothing and reduces the unprotected window to the unavoidable `mkdir`→`LOCK_OWNED=1` gap *inside* `acquire_lock` (177-178), which bash can't make atomic regardless.

### M3 — ACL match assumes `delete` is the first/sole right in the deny ACE
`bin/cloud-xdg-provision.sh:542`
`case "$acl_listing" in *"deny delete"*)` matches the literal substring. The standard macOS special-folder ACL always renders `group:everyone deny delete`, so this is correct for the actual target. But a dir carrying a *compound* deny ACE rendered with different right ordering (e.g. `deny write,delete`) would not match the substring and would slip through to the B2 probe (which then emits the less-accurate TCC message). Low likelihood given the target set; fail-through is safe (probe is the backstop), so this is robustness, not a bug.
**Consider:** if compound ACEs are a concern, match per-line on both tokens (`*deny*` and `*delete*` on the same ACE line) via a small helper rather than a single substring.

### M4 — Doc nit: "no-op installer in dry-run" is imprecise
`bin/cloud-xdg-provision.sh:717`
The comment says `install_cleanup_trap` is "a no-op installer in dry-run." It always installs the trap (153 has no `DRY_RUN` guard); it's the **handler** that's a no-op in dry-run because all flags stay 0. Tighten the wording so a future reader doesn't expect a conditional install.

### M5 — `is_redirected` names intent, not on-disk state
`bin/cloud-xdg-provision.sh:390`
The predicate answers "should this entry be redirected *per config*?" — not "is `~/<dir>` *currently* a symlink into the cloud?" `redirect_one` checks the actual symlink state separately (445-457). The name `is_redirected` could mislead a reader into thinking it inspects the filesystem. `should_redirect` (or `redirect_enabled`) would be more precise. Naming only.

---

## FUTURE

### F1 — Manual flag lifetimes in `relocate_dir` are a maintenance hazard
`bin/cloud-xdg-provision.sh:634-640`
`RELOCATE_ACTIVE` is raised at 634 and lowered at 640; the window in between (the `mv`→`ln`) is correct *today* because there is no early return inside it. But the flag lifetime is managed by hand. A future edit that adds an early `return`/`die` between 634 and 640 without resetting the flag would leave `RELOCATE_ACTIVE=1`, and a later interrupt (or the next loop iteration's interrupt) would print a stale recovery message pointing at the wrong dir. Mitigate M1 (handler self-reset) and/or add a comment marking 634-640 as a flag-critical window that every exit path must clear.

### F2 — `is_redirected` hardcodes the `downloads` exception
`bin/cloud-xdg-provision.sh:392`
The "eligible (redirect=1) but default-off" rule is encoded as `if [ "$1" = "downloads" ]`. `downloads` is the only such entry today, so this is fine (YAGNI). If a second default-off-but-eligible dir ever appears, promote the exception to a data column in `OFFLOAD_SET` (a 6th `defaultOn` field) and keep the predicate data-driven, rather than chaining another `if [ "$1" = "x" ]`. Note: the predicate also reads the global `REDIRECT_DOWNLOADS` (392) in addition to its two positional args — an acceptable hidden dependency that's idiomatic here (`cloud_name`/`local_name` likewise read `STYLE`/`PLATFORM` globals), but it means the function is not a pure function of its arguments.

### F3 — `cleanup_handler` does not self-terminate on INT/TERM
`bin/cloud-xdg-provision.sh:153`
A single handler string on `EXIT INT TERM` that returns without `exit` means INT/TERM run the handler and then resume — the deterministic teardown relies on the foreground copier dying and `set -e`/`pipefail` aborting. This is a **pre-existing** pattern (the old `relocate_recovery_msg` trap had the same shape), not introduced by this PR. The bash-3.2 "one handler" constraint is *per signal* — different handler strings on different signals don't clobber — so a future hardening could do `trap cleanup_handler EXIT; trap 'cleanup_handler; exit 130' INT; trap 'cleanup_handler; exit 143' TERM` (which makes M1's idempotency mandatory). Flagging for awareness; verify the intended Ctrl-C behavior is "stop now," not "run handler then continue."

---

## Cross-commit coherence

The three commits share one spine — make the relocate/redirect path safe and keep the two redirect layers consistent — and they reinforce rather than overlap:

- **bb78890 (trap unification)** is the structural enabler: it's what lets **#5c's lock** exist at all (a 4th trap pair was impossible under bash 3.2).
- **9b02d14 (`is_redirected`)** is the direct consequence of flipping `downloads` to `redirect=1` in `OFFLOAD_SET` (95): the shared predicate preserves the old "downloads stays local by default" behavior *while* unifying the two layers, so the OFFLOAD_SET change doesn't silently start redirecting Downloads.
- **495043d (ACL)** slots cleanly into the front of `relocate_dir`'s macOS pre-flight without disturbing the B2 probe it sits in front of — the probe was correctly *narrowed* (585-589) to "a genuine permission block that is NOT the deny-delete ACL," so the two macOS guards now have non-overlapping responsibilities and distinct, accurate messages.

Interface consistency holds across the file: the OFFLOAD_SET helpers (`cloud_name`, `local_name`, `is_redirected`) share one idiom (positional fields + global config). `local_name`'s signature change (#7, dropped the unused canonical param) is fully propagated — the single caller at 440 passes 2 args. No dangling 3-arg call.

**Bottom line:** ship-worthy from a design standpoint. M1 and M2 are the two I'd most want addressed (both are small, both harden the signal/lock teardown that the whole PR leans on); the rest are polish.
