# PR #11 — Security Verify-Only Re-Review (remediation commit `5ee261a`)

**Reviewer:** security-engineer · **Scope:** commit `5ee261a` only · **Verdict: ✅ RESOLVED — clear to merge (security/data-safety).**

My original BLOCKING B1 (subshell flag isolation) is genuinely fixed, verified by
running the **real production script** against a sandbox on macOS and signaling it
mid-relocate in both critical windows. The author also found and fixed a second
real regression (B2, handler-never-exits) that I did not flag — credited below.

## Checklist results

**1. Loop de-piped so `relocate_dir` runs in the parent shell — RESOLVED.**
`bin/cloud-xdg-provision.sh:773-778`: the relocate-driving loop now reads
`OFFLOAD_SET` via a here-doc redirect (`done <<EOF … EOF`) instead of
`printf | while`. So the loop body — and `relocate_dir`, where `PROBE_ACTIVE`
(:599) / `RELOCATE_ACTIVE` (:634) are raised — runs in the **same (parent) shell**
that owns the traps (installed `main():750`). The other two `printf|while` loops
(`ensure_cloud_tree`, `write_user_dirs`) correctly stay piped — they set no trap
flags. Verified against disk, not just the diff.

**2. On a mid-relocate signal, do probe-revert / recovery actually fire? — RESOLVED (empirical).**
Ran `bin/cloud-xdg-provision.sh --apply --relocate` in a sandbox with an `mv`
PATH-shim widening each window, then `kill -TERM` mid-window:
- **Probe window:** handler **reverted** the rename — no stranded `*.tcc-probe.*`,
  `~/Documents` restored as a real dir with payload intact, `exit 130`, lock
  released. This is the decisive proof: `PROBE_ACTIVE` set in the now-parent-shell
  reached `cleanup_handler` (pre-fix this stranded the dir).
- **mv→ln window:** recovery message **printed** ("INTERRUPTED mid-relocate — your
  data is SAFE …"), data safe in the `*.pre-offload-*` aside (payload intact),
  symlink not yet created (exactly the half-state the message describes), `exit
  130`, lock released. Confirms `RELOCATE_ACTIVE` reaches the parent handler.
- The test's "recovery message printed" assertion **does** genuinely prove the flag
  crossed into parent scope: the message body is gated on `RELOCATE_ACTIVE=1`
  (`cleanup_handler` :152), and that flag is only ever set inside `relocate_dir`.
  If the flag hadn't crossed scope, the branch would be skipped (as it was pre-fix).
  (Note: in the regression test the signal must land *in* the window;
  `RELOCATE_ACTIVE` is armed before the `mv` at :634, so the assertion is sound.)

**3. Remaining path where the original is moved aside but neither reverted nor recoverable? — NONE.**
`RELOCATE_ACTIVE=1` is armed (:634) **before** the destructive `mv "$src" "$aside"`
(:636), mirroring the probe's "armed before the rename" discipline. Any exit in the
mv→ln window fires the recovery message; the aside backup is always retained and
never deleted. The recovery is informational-by-design (same as pre-bb78890), and
the data is always recoverable (aside + cloud copy). No move-aside-and-lose path.

**4. Bonus — `on_signal` exit 130 + idempotent handler vs the EXIT trap — CLEAN.**
Split traps (`trap cleanup_handler EXIT` + `trap on_signal INT TERM`, :181-182).
`on_signal` runs `cleanup_handler` then `exit 130`; the EXIT trap then fires
`cleanup_handler` a second time, but each branch zeroes its own flag after acting
(`PROBE_ACTIVE=0` :150, `RELOCATE_ACTIVE=0` :157, `LOCK_OWNED=0` :161), so the
second pass is a no-op. Verified empirically: recovery message appears **exactly
once** and the lock is `rmdir`'d once (no double-cleanup, no double-revert,
exit code stays 130). This fixes the B2 regression (a bare handler resumed the
script, finished the mv+ln unprotected, and exited 0 on Ctrl-C) — a real issue I
did not catch originally; good find by the author.

**5. Trap-before-lock ordering (`main():750-751`) — CORRECT, no new issue.**
Traps armed before `acquire_lock` closes the acquire→arm strand-the-lock gap. A
signal in that gap finds `LOCK_OWNED=0`, so `cleanup_handler` skips the `rmdir`
(no release of an unowned lock) and exits 130. Safe.

## New issues
None. No new data-safety or security exposure introduced by `5ee261a`.

## Summary
```
VERIFY RE-REVIEW SUMMARY
B1 (subshell scoping):        RESOLVED  (de-piped here-doc; empirically reverts/recovers)
B2 (handler never exits):     RESOLVED  (split EXIT vs INT/TERM, exit 130, idempotent)
Lock / probe double-cleanup:  CLEAN     (idempotent flags; verified once-only)
New issues:                   NONE
Overall: PASS — security/data-safety clear to merge.
```
