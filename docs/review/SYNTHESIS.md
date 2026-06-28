# Peer Review Synthesis — PR #1 `feat: cloud-resident XDG user-data ontology toolkit`

**PR:** https://github.com/youdontknowdemo/xdg-cloud/pull/1
**Date:** 2026-06-28
**Reviewers:** architect · test-engineer · devops-engineer · security-engineer
**Individual reports:** `docs/review/{architect,test-engineer,devops-engineer,security-engineer}-review.md`

---

## Verdict

Above-average shell engineering. The **dry-run and create-only paths are safe to ship.** The risk is concentrated entirely in the **`--relocate` data-migration path**, where multiple reviewers independently converged on the same data-loss failure modes.

| Reviewer | Blocking | Minor | Future | Angle verdict |
|----------|:-------:|:-----:|:------:|---------------|
| security | 3 | 5 | 3 | Injection/traversal CLEAN; data-loss in relocate |
| architect | 1 | 6 | 3 | Sound design; one verified interface bug |
| test | 3 | 5 | 1 | Correctness verified; safety-critical paths 0% covered |
| devops | 0 | 5 | 7 | Approve from shell angle; bash 3.2 claim holds |

**Cross-validation is the headline.** Three findings were flagged independently by 2–3 reviewers — those are the highest-confidence issues.

---

## Live-run evidence (this machine)

Your actual `--apply --relocate` run failed at:
```
mv: rename /Users/administrator/Desktop to .../Desktop.pre-offload-...: Permission denied
```
This is **macOS TCC protection** — the OS refuses to let any process without Full Disk Access rename `~/Desktop`, `~/Documents`, `~/Downloads`, `~/Pictures`, `~/Movies`. None of the reviewers' sandboxes hit this (they used non-TCC paths). It is a real, additional finding:

- The sequence got as far as `rsync` (Desktop **was** copied to iCloud) before `mv` aborted the run under `set -e`.
- Your original `~/Desktop` is **intact** (the `mv` failed, didn't half-move). No data lost.
- But you now have a half-state: a copy in iCloud, the original in place, no symlink, and an aborted run. Re-running will re-rsync.
- **The script has no pre-flight TCC check** and no handling for the protected-dir case — on stock macOS, `--relocate` of the Apple-protected dirs cannot succeed without Full Disk Access granted to the terminal. This belongs in the blocking set for the macOS relocate path.

---

## BLOCKING (must resolve before `--relocate` is safe to use/merge-enable)

| # | Finding | Reviewers | Status |
|---|---------|-----------|--------|
| **B1** | **Relative / trailing-slash `--cloud-root` silently creates DANGLING symlinks.** `CLOUD_ROOT` is never absolutized: `mkdir` resolves against CWD, `ln -s` target resolves against `$HOME` → they diverge. The primary documented interface produces broken links. | architect (B1, **verified**), test (MINOR-2), security (M3) | Verified |
| **B2** | **macOS TCC blocks `mv` of protected dirs** (Desktop/Documents/Downloads/Pictures/Movies). No pre-flight check; run aborts mid-sequence after rsync already copied data. | live run (this machine) | Verified |
| **B3** | **`mv` original happens unconditionally on rsync exit 0, with no post-copy verification.** FUSE mounts (rclone, gdrive-ocamlfuse) return success on async-buffered writes that can fail to upload later. Combined with the "delete your backup once verified" guidance → silent total data loss. | security (B1) | Reasoned |
| **B4** | **No mount-liveness check.** An unmounted FUSE mountpoint is just an empty local dir → script rsyncs GBs to **local** disk, moves originals aside, symlinks — user believes it's cloud-backed; nothing is synced. | security (B2), architect (M6) | Reasoned |
| **B5** | **`rsync -a` merges into a pre-existing cloud folder and clobbers NEWER cloud-side files** from another machine (the multi-OS use case), with no backup of the clobbered cloud file (aside only saves the local original). | security (B3) | Reasoned |
| **B6** | **Safety-critical branches have zero test coverage:** the data-loss guard branches (populated-dir-without-`--relocate`; dangling-symlink guard from commit `0761877`), `relocate_dir()` (0%), and `home-tree.sh`'s `write_filter()` cloud-safety filter (0%). All testable with no external deps. `smoke.sh` also *overclaims* dangling-symlink coverage in a comment. | test (BLOCKING-1/2/3) | Verified |

> **Reviewer gate (security + test agree):** ship dry-run / create-only now; do **not** enable `--relocate` by default until B1–B5 are fixed and B6 adds regression tests.

---

## MINOR (optional this PR)

| # | Finding | Reviewer |
|---|---------|----------|
| M1 | `--style mac` produces cloud folder `Videos`, not the documented `Movies` (code/docs disagree). | architect (M1, verified) |
| M2 | `OFFLOAD_SET` vs `SAFE_DIRS`: the "portable user-data set" is defined twice and divergently — no single source of truth. | architect (M3) |
| M3 | ~40 lines of plumbing + platform logic duplicated verbatim across both scripts; no shared lib. | architect (M4) |
| M4 | `aside`-collision *nests* instead of failing: `mv` moves the original *inside* the existing `.pre-offload-DATE` dir, and the "Original preserved at: …" message then misdirects recovery. | test (MINOR-1), security (M4) |
| M5 | `make install` broken in git worktrees — `test -d .git` fails because `.git` is a *file* there, and this project's own PACT workflow uses worktrees. | devops (M1) |
| M6 | Dry-run output not copy-paste-safe for paths with spaces (`run()` prints `$*` unquoted; the default macOS cloud path contains a space). | devops (M2) |
| M7 | `make install`'s `ln -sf` silently clobbers an existing `.git/hooks/pre-commit`. | devops (M3) |
| M8 | Multiple `GoogleDrive-*` mounts → silent first-match selection. | devops (M4) |
| M9 | No root-refusal guard; `user-dirs.dirs` truncated without backup; no concurrency lock. | security (M1/M2/M5) |
| M10 | No error-path / negative-input test assertions (`--style bogus`, missing args, unknown option, unset `CLOUD_ROOT`). | test (MINOR-3) |
| M11 | Platform branches (Linux/Termux) never exercised; latent `downloads` inconsistency (user-dirs writes it, symlink layer doesn't). | test (MINOR-4) |
| M12 | `local_name()` first parameter is dead. | architect (M5) |

## FUTURE (track as issues, out of scope)

TOCTOU windows in the check-then-act sequence (low risk under `0700` home) · `$dst`-as-symlink handling · `ls -A` misread · `OFFLOAD_SET` arity validation · `field()` subshell fan-out (parsed 3× per line) · pre-commit hook lints working-tree not staged index · hook gates lint but not smoke tests · `mkdir -p` over dangling symlink is platform-divergent · dry-run `die`s on macOS without a Drive mount · `--max-delete` unvalidated · `VERSION := $(shell …)` eager evaluation · naming logic → shared module.

---

## Notes

- **bash 3.2 claim HOLDS** (devops construct-audit: no assoc arrays, `mapfile`, `<()`, `[[ ]]`, case-modification, `$''`, or namerefs). Could not execute on real 3.2 (host bash 5.3).
- **shellcheck clean** with repo config; the `.shellcheckrc` disables are honest (229 `--enable=all` findings all reduce to the 5 documented info/style codes, zero error/warning).
- **No `bats`** — the suite is hand-rolled `tests/smoke.sh`. Correct call given the dependency-light macOS-3.2/Termux constraint. (My dispatch brief mislabeled it `test_provision.bats`.)
- Injection / path-traversal / privilege-escalation surface is **clean** — all expansions quoted, no `eval`, Makefile and hook benign.
