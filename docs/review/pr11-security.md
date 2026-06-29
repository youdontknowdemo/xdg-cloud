# PR #11 — Security / Data-Safety Review

**Reviewer:** security-engineer (adversarial, data-safety focus)
**Scope:** `bin/cloud-xdg-provision.sh` (+ `tests/smoke.sh`)
**Mandate:** Did the `bb78890` *trap unification* preserve the previously-reviewed
data-safety guarantees on the relocate path? Plus lock TOCTOU, root guard, ACL
mis-classification, `--redirect-downloads`.

**Verdict: FAIL — 1 BLOCKING data-safety regression.** The trap unification did
**not** preserve the prior guarantees. Two of the three responsibilities the new
master handler claims to serve (TCC-probe revert, mid-relocate recovery message)
**do not fire**, because they are armed inside a pipeline subshell while the
handler runs in — and reads its flags from — the parent shell.

---

## FINDING: CRITICAL (BLOCKING) — Trap unification breaks probe-revert and mid-relocate recovery (subshell flag isolation)

**Location:**
- Handler installed in parent: `bin/cloud-xdg-provision.sh:718-719` (`acquire_lock; install_cleanup_trap` in `main()`)
- Flags set in subshell: `bin/cloud-xdg-provision.sh:599` (`PROBE_ACTIVE=1`), `:634` (`RELOCATE_ACTIVE=1`)
- Subshell boundary: `bin/cloud-xdg-provision.sh:731-734` (`printf '%s\n' "$OFFLOAD_SET" | while IFS= read -r line; do … redirect_one "$line"; done`)
- Handler reads parent-scope flags: `bin/cloud-xdg-provision.sh:137-151` (`cleanup_handler`)

**Issue:**
`main()` installs the single master `cleanup_handler` **once, in the parent
shell** (line 719). But `relocate_dir` — the only place `PROBE_ACTIVE` and
`RELOCATE_ACTIVE` are raised — is reached exclusively through
`redirect_one`, which is called from a `while` loop on the **right-hand side of a
pipe** (`printf … | while read`, line 731). A pipeline RHS runs in a **subshell**.

Two independent POSIX facts combine to defeat the design:
1. **Subshell variable changes never propagate to the parent.** When the subshell
   sets `PROBE_ACTIVE=1` / `RELOCATE_ACTIVE=1`, the *parent's* copies stay `0`.
2. **Traps are reset to default in a pipeline subshell.** The inherited
   `cleanup_handler` is not active inside the subshell; on `INT`/`TERM` the
   subshell dies with the default action.

On Ctrl-C / SIGTERM during a relocate, SIGINT reaches the whole foreground
process group: the subshell dies (no trap, mid-operation), and the **parent's**
`cleanup_handler` fires on its own `INT`/`EXIT` trap — but reads
`PROBE_ACTIVE=0` and `RELOCATE_ACTIVE=0` (the subshell's writes never arrived).
Result: **no probe revert, no recovery message.**

The PR body explicitly claims *"Semantics meant to be identical (probe armed
before rename, recovery apply-mode-only, lock released on all exits)."* That claim
is false for the first two; the prior tests pass because none exercises an
interrupt mid-relocate.

**Empirically verified** (reproduced the exact `printf|while` + parent-trap +
flag-in-subshell structure on this machine):
- Post-refactor structure: SIGINT → handler runs with `PROBE_ACTIVE=0` → **probe
  dir stranded** (`src` gone, `src.tcc-probe.$$` remains, no message).
- Pre-refactor structure (trap armed *inside* the loop body): SIGINT → **revert
  succeeds** (`src` restored, probe gone).

**Attack vector / failure scenario** (not adversarial — interrupt/crash is the
realistic trigger; `set -e` abort, SIGINT, SIGTERM, terminal close):
1. **Stranded special folder + silent.** Interrupt in the B2 probe window
   (lines 599-608): `~/Documents` is left renamed to `~/Documents.tcc-probe.<pid>`
   with **no revert and no message**. The guarantee the task names verbatim —
   *"TCC probe still reverts the dir rename on interrupt (no stranded probe
   dir)"* — is broken.
2. **Apparent data loss on re-run (amplifier).** After (1), a re-run sees
   `~/Documents` missing → takes the `[ ! -e ]` branch (line 460) → creates
   `~/Documents` as a symlink to the **empty** cloud folder. The user now sees an
   empty Documents while the real data sits in the stranded
   `~/Documents.tcc-probe.<pid>`, never copied to the cloud. Data is recoverable
   on disk, but the user-visible state is "my Documents are gone."
3. **No recovery guidance mid-`mv`→`ln`.** Interrupt between `mv "$src" "$aside"`
   (line 636) and `ln -s "$dst" "$src"` (line 637): the "INTERRUPTED
   mid-relocate — your data is SAFE …" message (the B3 net from the prior review)
   **never prints**. Data is intact (aside backup + cloud copy retained, nothing
   deleted), but the panic-prevention guidance the prior review required is gone.

**Severity rationale:** No code path *deletes* data, so this is not unrecoverable
destruction. But it is a direct regression of a previously-reviewed data-safety
guarantee that the task flagged as the crux, plus a realistic apparent-data-loss
sequence. That clears the BLOCKING bar: **must not merge as-is.**

**Remediation (pick one; I report, coders fix):**
- **Preferred — keep relocate in the parent shell.** Drop the pipe so the loop
  body shares scope with the handler and its flags. e.g. feed `OFFLOAD_SET` via a
  here-doc redirect:
  ```sh
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    redirect_one "$line"
  done <<EOF
  $OFFLOAD_SET
  EOF
  ```
  (Apply the same change to `ensure_cloud_tree` and `write_user_dirs` if any
  future flag-state must survive — not strictly required there today, but it keeps
  the pattern consistent.) After this, the parent-installed `cleanup_handler` sees
  the real flag values.
- **Alternative — re-arm inside the subshell.** Call `install_cleanup_trap`
  at the top of the subshell loop body so the trap is active in the subshell where
  the flags live. Heavier and easy to get wrong (lock release would then also run
  on subshell exit against a parent-owned `LOCK_OWNED` that reads 0 — so this
  needs care).
- **Regression test (TEST phase):** add a smoke case that backgrounds an
  `--apply --relocate`, sends SIGINT during the copy/rename window, and asserts
  (a) no `*.tcc-probe.*` left behind and (b) the recovery message printed. The
  current suite has no interrupt test, which is why this shipped green.

---

## FINDING: PASS — Concurrency lock (#5c): no TOCTOU / steal / symlink hole

**Location:** `acquire_lock` (`:171-183`), release in `cleanup_handler` (`:147-150`).

- The lock is acquired in `main()` in the **parent** shell (line 718), so
  `LOCK_OWNED`/`LOCK_DIR` are parent-scope and the handler releases correctly on
  all parent exit paths — **not** affected by the subshell bug above. Confirmed.
- `mkdir "$LOCK_DIR"` is the atomic primitive; exactly one racer wins. ✓
- **Releasing someone else's lock:** guarded by `LOCK_OWNED` (set to 1 only on our
  own successful `mkdir`). The `die` path when another run holds the lock never
  sets `LOCK_OWNED=1`, so we never `rmdir` a lock we didn't create. ✓
- **Symlink attack on the predictable path:** if `$XDG_CACHE_HOME/cloud-xdg-provision.lock`
  pre-exists as a symlink (dangling or not), `mkdir` fails with `EEXIST` →
  `die`, `LOCK_OWNED` stays 0, no `rmdir` through the link. No write/delete
  redirection. ✓
- **Stale-lock wedge / DoS by pre-creating the dir:** possible, but `$XDG_CACHE_HOME`
  is the user's own `~/.cache` (same trust boundary); the `die` message tells the
  user how to clear it. Not a security boundary crossing. **MINOR/FUTURE** at most.

## FINDING: PASS — Root guard (#5a): no sudo -E / env bypass

**Location:** `guard_not_root` (`:159-163`), called first in `main()` (`:711`).

- `[ "$(id -u)" = "0" ]` → `die`, before any filesystem work. Under `sudo` /
  `sudo -E` the euid is still 0, so the guard fires regardless of preserved env.
  `sudo -E` preserving `$HOME` doesn't matter — refusal happens first. No bypass
  found. ✓

## FINDING: PASS — ACL detection (495043d): mis-classification fails safe

**Location:** `relocate_dir` ACL block (`:539-558`).

- The dangerous direction would be a deny-delete dir **not** matched by
  `*"deny delete"*` and therefore relocated. But if the ACL is truly present, the
  subsequent B2 probe `mv "$src" "$probe"` (line 600) fails → "nothing copied",
  skip. So a missed ACL match falls through to a safe failure backstop — no copy,
  no move. ✓
- False **positive** (e.g. a path literally containing "deny delete") only causes
  a refusal-to-relocate — the safe direction. ✓
- TOCTOU between `ls -lde` and the op is within the single-user home trust model
  and is backstopped by the probe. Negligible.

## FINDING: PASS (with dependency) — `--redirect-downloads` now active

**Location:** `is_redirected` (`:390-394`), `redirect_one` gate (`:434-437`).

- When enabled, Downloads relocates through the **same** machinery as every other
  dir (probe, verify-before-mv, retained aside). No new *class* of data-safety
  exposure beyond the BLOCKING trap regression, which affects it identically. Off
  by default; default runs unchanged. ✓
- Note: it inherits the BLOCKING finding — fixing the trap scope covers Downloads
  too.

---

## Items that remain correctly handled (regression check — no change needed)

- `verify_copy` proves integrity-not-durability, aside backup never gated on it
  (`:479-521`). ✓
- B5 refuse-migrate-into-non-empty-cloud-dst (`:577-583`) prevents clobber. ✓
- Unique `aside` name via collision counter (`:566-570`) prevents `mv`-into-dir
  nesting. ✓
- Verify-before-`mv` → die-without-moving on mismatch (`:620-626`): original left
  untouched on failed copy. ✓ (This specific chain is intact; it is the
  *interrupt* path, not the verify-fail path, that the BLOCKING finding breaks.)

---

## Summary

```
SECURITY REVIEW SUMMARY
Critical: 1   (trap-unification subshell flag isolation — probe revert + recovery dead)
High:     0
Medium:   0   (lock predictable-path DoS is same-trust; noted as FUTURE only)
Low:      0
Overall assessment: FAIL — BLOCKING. The trap unification regressed the
verify-before-mv → probe-revert / retained-backup recovery guarantees on the
relocate path. Probe-revert and mid-relocate recovery do not fire because their
flags are set in a pipeline subshell isolated from the parent-installed handler.
The lock release survives (parent scope) and the non-interrupt data-safety chain
(verify-before-mv, retained aside, B5) is intact. Fix the subshell scoping
(preferred: here-doc redirect to keep the loop in the parent shell) and add an
interrupt regression test before merge.
```
