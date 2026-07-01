# Test-Coverage Review — dotfiles adopt (PR #27, `feature/dotfiles-adopt`)

**Reviewer:** test-review (adversarial coverage pass, fresh eyes on D13–D21)
**Scope:** `tests/smoke.sh` adopt cases vs `bin/cloud-xdg-provision.sh` `cmd_dotfiles_adopt`
**Verdict:** No Blocking findings. The implementation is robust across every path I
probed (never-clobber holds even for a non-empty-directory collider). The findings
below are TEST-COVERAGE gaps, not code bugs — 3 Minor (cheap, worth adding before
merge) and several Future (low ROI or need fault injection).

Method note: every claim was verified empirically (build fixture → run adopt →
observe), not reasoned in the abstract. Where I write "implementation is correct",
I ran it.

---

## Blocking
**None.** All adversarial probes showed correct behavior:
- A non-empty **directory** collider is moved aside intact (its contents preserved
  at `<dir>.pre-dotfiles-<stamp>/`) while the tracked file is checked out — the
  never-clobber guarantee holds for dirs, not just files.
- An **empty** repo (tracks nothing) adopts cleanly; the bare repo is ours.
- **adopt → track → status** integration works (track adds a new file; status
  reports alias + rc present).
- **D17 mid-list ordering is real:** `git ls-tree -r` emits `.aaarc` before
  `repos/tracked` (`.`=0x2e < `r`=0x72), so the "valid entry precedes the managed
  offender" label is accurate — the test has teeth.

---

## Minor (recommend adding before merge — cheap, closes a real data-preservation angle)

### M1 — DIR collider never-clobber is UNASSERTED
The never-clobber property is proven for a **file** collider (D13a/D15) and a
**symlink** collider (D16), but NOT for a **non-empty directory** collider. This is
a distinct code path (`mv` of a directory, not a file). I confirmed the
implementation preserves it correctly — but there is no standing guard, so a future
change to the aside loop could regress dir-collider preservation silently.
*Suggested case:* repo tracks `foo` (file); `$HOME/foo` is a dir containing
`precious.txt`. After adopt: `$HOME/foo` is the remote file AND
`$HOME/foo.pre-dotfiles-*/precious.txt` == the original content.

### M2 — D16 symlink aside assertion could be tighter
D16 asserts the aside is a symlink (`[ -L ]`) and the target file is intact, but
does not assert the aside link still points at the ORIGINAL target
(`readlink aside == original target`). A hypothetical bug that re-created a
different link would slip through. Add a `readlink` equality check.

### M3 — D20 managed-fixture dry-run has no zero-mutation snapshot
D20 snapshots `$HOME` for the *collider* dry-run (good), but the second dry-run
(against the managed fixture, asserting `WOULD REFUSE`) only checks the message —
it does not assert `$HOME` was untouched or that no `.dotfiles` was created. Add a
before/after snapshot to that leg too.

---

## Future (valuable but low ROI, or needs fault injection / harness work)

- **F1 — empty repo:** adopt of a repo tracking nothing is untested (works today).
- **F2 — adopt→track→status integration:** untested end-to-end (works today); would
  catch a broken `status.showUntrackedFiles`/work-tree config after adopt.
- **F3 — MANY colliders:** only single/dual colliders are exercised; the aside loop
  is uniform so risk is low, but a 5–10 collider fixture would stress ordering +
  uniquifier interaction.
- **F4 — checkout-fail-after-asides recovery:** the code's defensive path (checkout
  fails *after* colliders are asided → asides retained, die "delete nothing") is
  unexercised. Needs a `git`/`dotfiles_git` fault-injection shim (checkout returns
  non-zero) — the asides-retained recovery is exactly the kind of path that rots.
- **F5 — concurrent-lock during adopt:** adopt takes the shared mutating-mode lock;
  a second concurrent adopt should be refused. Covered generically by the #5c lock
  test but not for the adopt entrypoint.
- **F6 — deep nested tree:** D14 covers one nested file (`.config/app.conf`); a
  deeper multi-level tree is untested (low risk).

---

## Already documented in the CODE→TEST handoff (task #65), restated for completeness
- Date-shim scope on D15 (deterministic stamp pinning; scoped to one run).
- Mid-adopt INTERRUPTED-window recovery message (`DOTFILES_ADOPT_ACTIVE`
  stage-aware warning) not exercised — same signal-injection limitation as
  migrate-projects; the recoverability guarantees it protects ARE covered by
  D17/D19 (partial clone removed / asides retained).

---

## False-pass audit (assertions that could pass without proving their claim)
- D17 "collider NOT asided": globs `*.pre-dotfiles-*`; non-match → pass = correct
  (absence is the property). **Sound.**
- D15 `.1` assertion: if the date-shim failed to take effect the pre-seed wouldn't
  collide and the assertion would FAIL (not false-pass). **Sound.**
- D17/D19 `$HOME` byte-identical: excludes `.cache` (the `acquire_lock` scaffold) —
  correct scoping; any real aside/leak would still surface. **Sound.**
- **M2/M3 above** are the two places an assertion is weaker than its claim.

## Bottom line
Coverage of the clobber-safety surface is strong and the never-clobber dual-assert
(original preserved + tracked checked out) is airtight for the file/symlink cases
tested. Adding **M1–M3** (≈ small, one fixture + two assertions) would close the
last data-preservation angle (dir colliders) and tighten two assertions. Everything
else is Future. Recommend M1–M3 before merge; F1–F6 as follow-ups.
