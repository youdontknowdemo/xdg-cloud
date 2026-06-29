# Test-Engineer Review — PR #11 (`fix/macos-acl-special-folders`)

**Reviewer:** test-engineer · **Date:** 2026-06-29 · **Task:** #14
**Angle:** TEST-COVERAGE only — does `tests/smoke.sh` actually *prove* the production
changes in `bin/cloud-xdg-provision.sh`? (Not a re-review of the production logic;
the architect owns that.)
**Risk tier:** **HIGH** — code physically relocates user data (`mv`/`rsync`/`cp` of
`~/Documents`, `~/Music`, …) and gates migration on a cloud-liveness check. Data-loss
is the failure mode.

**Method:** Ran `make lint` (exit 0) and `make test` (exit 0) myself. Read the full
test harness and the full production script. Traced each new shim against the exact
production call sites it stands in for, hunting specifically for shims that pass GREEN
while real behavior diverges. Confirmed which platform/tool-gated groups actually
*executed* on this host vs silently skipped.

---

## Headline

**Signal: 🟢 GREEN.** This PR is the remediation of the prior test-engineer review
(Task #4), which measured `relocate_dir()` at **0%** and `redirect_one()` at **25%**
branch coverage. PR #11 adds **338 lines** of smoke tests that close those gaps: the
data-migration path, the data-loss guards, the concurrency lock, the fstype
classification, and the rclone filter are now exercised. All 50+ assertions pass; lint
is clean.

**The shims are sound.** I traced all three (`uname` forced-Linux, `stat` fstype/device,
`date` stamp-pin) against their production call sites. None masks a bug in the logic
under test — each is narrowly scoped and execs the real binary for every call it does
not deliberately stub. Details in §Shim Soundness.

No BLOCKING test-coverage defects. The remaining gaps are either genuinely
non-deterministic to test (signal-interrupt windows) or honestly documented as
TEST-phase targets. They are listed as MINOR/FUTURE so they are not lost.

**What actually executed on this host** (macOS + `chmod +a` + rclone present), so this
was *not* a skip-heavy run:
- Native macOS: B6 deny-delete ACL group, #4 multi-mount disambiguation — **ran for real**.
- Real binary: home-tree `--apply --sync` against a local rclone remote — **ran** (filter
  validated end-to-end: `*.sqlite` and `Cache/` confirmed *not* leaked).
- Shimmed forced-Linux: #5b backup, #6 user-dirs agreement, #8 fstype — **ran via shims**.
- Documented skips: B2 TCC failure path, #5a root guard (both unreachable without real
  TCC / uid 0).

---

## Shim Soundness (the key question)

| Shim | Stands in for | Verdict |
|---|---|---|
| `uname -s`→`Linux` (smoke.sh:595, 662, 734) | `case "$(uname -s)"` at prov:237 (the *only* `uname` call that sets PLATFORM) | **Sound.** Execs real `uname` for any other arg. Faithfully forces `PLATFORM=linux`. |
| `stat -f -c %T` / `-c %d` (smoke.sh:738–749) | `cloud_root_is_live()` Linux branch, prov:330/340–341 | **Sound for the logic it tests** (see caveat below). |
| `date +%Y%m%d-%H%M%S`→pinned (smoke.sh:475–482) | aside-stamp at prov:560 | **Sound.** Only pins the timestamp string; execs real `date` otherwise. Correctly makes the M4 collision deterministic. |

**The `stat` shim is the one to scrutinize, and it holds up.** The `-c %d` branch grabs
the last argument as the path and returns `SHIM_DEV_HOME` for `$HOME`, `SHIM_DEV_ROOT`
otherwise — matching production's two call sites (`stat -c %d "$probe"` and
`stat -c %d "$HOME"`, prov:340–341). The `-f` branch returns the canned fstype. Critically,
the test design **isolates the two production branches**: FUSE-type cases use same-device
ids (0/0) and still pass *because the fstype match returns before the device check is
reached*; UNKNOWN/empty cases use differing ids to drive the `st_dev` fallback. That is
exactly how production short-circuits, so the shim exercises the real branch structure
rather than papering over it. The UNKNOWN-fuse-magic case the task asked about **is**
covered, both directions (smoke.sh:780–792: different-device→live, same-device→refused).

**Caveat — the one real divergence risk (documented, not a bug): FUTURE-1.** The Linux
`stat -f -c %T` *contract* is never tested against the real GNU coreutils binary on any
platform. #8 shims `stat` entirely; #5b/#6 pass `--allow-local-root`, which makes
`check_cloud_liveness` return at prov:353 *before* the real fstype probe. So if a real
rclone mount reported an fstype string the `case` at prov:331–334 does not anticipate, no
test would catch it. The production design mitigates this (unknown strings *fall through*
to the device heuristic rather than over-refusing — prov:334), and the comment at
smoke.sh:729–731 is honest that the classification is "verified against the production
logic," not against a real mount. This is a true real-mount integration target, not a
shim defect. See FUTURE-1.

---

## Coverage of the PR's claims

| Change | Tested? | Where |
|---|---|---|
| #4 multi-mount disambiguation (refuse + list candidates + single-mount clean) | ✅ ran natively (macOS) | smoke.sh:522–548 |
| #5b user-dirs.dirs backup-before-overwrite + content preserved + rewritten | ✅ shimmed-Linux | smoke.sh:592–638 |
| #5c lock: refuse-while-locked (lock left intact) + acquire/**release on EXIT** | ✅ | smoke.sh:554–584 |
| #6 `--redirect-downloads`: **both** default-skip AND flag-redirect, symlink + user-dirs agree | ✅ | smoke.sh:660–725 |
| #8 fstype classification: fuse/fuseblk/fuse.\* live, known-local refused, UNKNOWN/empty fallback | ✅ shimmed | smoke.sh:732–792 |
| #9 macOS deny-delete ACL detected, skipped, accurate (non-TCC) guidance, no FDA-leak | ✅ ran natively (macOS) | smoke.sh:291–347 |
| relocate happy path: copy→verify→aside→symlink, dotfile/nested carried | ✅ | smoke.sh:177–207 |
| B5 clobber guard (non-empty cloud dst refused, both sides untouched) | ✅ | smoke.sh:233–262 |
| B4 liveness gate (apply refuses, dry-run warns) | ✅ | smoke.sh:264–281 |
| M4 aside-collision counter (.2, no nesting, "Original kept at" correct) | ✅ deterministic via `date` shim | smoke.sh:470–504 |
| populated-no-relocate guard / dangling-symlink guard | ✅ | smoke.sh:142–175 |
| rclone filter denies SQLite/.git/Cache/Downloads, allows safe set | ✅ static + real-binary E2E | smoke.sh:349–427 |

**Trap unification (the master `cleanup_handler`, prov:137–151):** the three flag-gated
responsibilities do *not* clobber each other, and the lock-release path is the one with
real coverage — both the **LOCK_OWNED=1 → release on normal EXIT** path (smoke.sh:580–583)
and the **LOCK_OWNED=0 → do-not-release-a-lock-we-don't-own** die path (smoke.sh:566–570)
are proven. That is the most important exit-path assertion and it is solid. The remaining
two handler responsibilities (probe-revert, recovery message) and the INT/TERM signal
paths are untested — see MINOR-1 / FUTURE-2.

---

## Findings

### BLOCKING
None. All tests pass, lint clean, no shim masks a bug, and every safety-critical branch
that can be tested deterministically *is* tested.

### MINOR

**MINOR-1 — INT/TERM lock-release proven only by transitivity.** smoke.sh:580–584 proves
the lock releases on the normal **EXIT** path. No test sends `SIGINT`/`SIGTERM` to a
running apply and asserts the lock dir is gone. Because `trap cleanup_handler EXIT INT TERM`
(prov:153) runs the *same* handler with the *same* `LOCK_OWNED` gate, the EXIT test gives
reasonable confidence — but "releases on Ctrl-C" is the scenario users will actually hit
and it is not directly asserted. The script is too fast to pause mid-run, so a faithful
test would need a `sleep`-injecting shim. Recommend as a targeted add, not a merge blocker.

**MINOR-2 — `verify_copy` mismatch→`die` path is untested (highest-value gap).** prov:620–626
is the branch that stands between "copy succeeded" and "move the original aside." If
`verify_copy` ever returned 0 on an incomplete copy, the original would be relocated on a
bad copy (data-safety net is the retained aside, which *is* tested). This branch is
**deterministically testable**: shim `rsync`/`cp` to copy nothing (or partially), then
assert the run dies, prints "post-copy verification FAILED", and leaves the original a real
dir with no aside created. Same harness as the B5 clobber group. Recommend adding.

**MINOR-3 — `--fast-verify` and the `cp -a` fallback branch are untested.** `verify_copy`
has four code paths (rsync vs cp × checksum vs size+mtime, prov:495–518). Only the default
`rsync -ac` path runs (relocate groups, on this host where rsync exists). The
`FAST_VERIFY=1` flag (prov:499) and the cp-fallback count/bytes comparison (prov:514–518)
have zero coverage. Low data-loss risk (the aside backup covers it), but the flag is a
documented feature with an untested code path.

**MINOR-4 — forced-Linux groups soft-skip on `rc!=0` instead of failing.** #5b (smoke.sh:636–638)
and #6 (smoke.sh:723–725) wrap their assertions in `if rc -eq 0 … else echo SKIP`. If a
future regression made the shimmed apply exit non-zero, these groups would degrade to a
**SKIP, not a FAIL** — silently dropping coverage while the suite still reports PASS. They
ran green here, but the pattern hides exactly the regression the test exists to catch.
Consider failing loudly (or asserting the run reached a known good state) rather than
skipping on unexpected non-zero.

### FUTURE (documented limitations — acceptable to defer, tracked so they're not lost)

**FUTURE-1 — Real GNU `stat -f -c %T` fstype contract is never exercised** against a real
mount on any platform (see §Shim Soundness caveat). True integration target: run #8 on a
real Linux host against an actual rclone/`fuse` mount with no shim, and against a real
`ext4`/`tmpfs` mount, to confirm the strings GNU coreutils emits match the prod `case`.

**FUTURE-2 — Probe-revert-on-interrupt and the mid-relocate recovery message are untested.**
The B2 `PROBE_ACTIVE` revert (prov:138–140) and the `RELOCATE_ACTIVE` recovery banner
(prov:141–146) fire only when the process is killed inside a sub-millisecond / mv→ln window.
The probe *success* path is implicitly exercised by the macOS relocate groups; the probe
*failure* (B2/TCC) and *interrupt* paths need real TCC or signal-injection and stay
real-environment targets (honestly noted at smoke.sh:283–289).

**FUTURE-3 — #5a root-refusal guard SKIPPED** (smoke.sh:644–648). Needs uid 0; `id -u`
can't be safely stubbed under `set -euo pipefail` without masking real failures. The guard
is a 2-line check (prov:159–163), verified by inspection. Acceptable.

---

## Verdict

```
Risk Tier: HIGH
Signal: GREEN
Coverage: relocate_dir + redirect_one guards + lock + fstype + filter now exercised
          (prior review measured these at 0%/25%; PR closes those gaps). All 50+
          assertions pass; lint clean. Shims verified sound — none masks a bug.
Uncertainty Coverage: N/A (no HIGH areas flagged in a coder handoff; this is PR review)
Findings: 0 BLOCKING, 4 MINOR (none block merge), 3 FUTURE (documented limitations).
          Highest-value follow-up: MINOR-2 (verify_copy mismatch→die path is
          deterministically testable and guards the core data-move decision).
```

The PR is mergeable from the testing angle. The MINOR items are improvements, not
defects in the work as submitted; MINOR-2 is the one I'd most encourage adding before
this code is trusted with real libraries, but the retained-aside backup (which *is*
tested) is the actual data-safety net regardless.
