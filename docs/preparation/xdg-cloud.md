# PREPARE Brief — `xdg-cloud` repository

**Phase:** PACT Prepare · **Author:** pact-preparer · **Date:** 2026-06-26
**Status:** COMPLETE — all three open decisions resolved, no TBDs.
**Gate:** This brief is the entry contract for ARCHITECT. No ambiguity carries forward.

---

## 1. Executive Summary

We are initializing a version-controlled git repository for a small, self-contained
**cross-OS XDG ↔ cloud shell toolkit**. Two bash scripts were located (staged at
`/tmp/xdg-scripts-staging/`), read in full, and verified. Both pass `shellcheck 0.11.0`
and `bash -n` (macOS bash 3.2.57) **cleanly with zero findings**, both are bash-3.2-safe,
and both execute correctly in live dry-run on this Mac.

The two scripts implement **two complementary strategies** for the same problem domain
(getting user data to the cloud without breaking XDG/app correctness):

- **`cloud-xdg-provision.sh`** — makes the cloud drive the **live home** for user-data
  folders (symlinks `~/Documents` → cloud). The real data lives in the cloud root.
- **`home-tree.sh`** — keeps the live home **local** and treats the cloud as a **safe
  backup mirror** via `rclone` (one-way `sync` or two-way `bisync`).

**Recommendations (all firm):**

| Decision | Call | One-line rationale |
|----------|------|--------------------|
| home-tree.sh scope | **Include** as a co-equal secondary tool | Complementary strategy, shared design DNA, production-quality, zero maintenance cost |
| Repo name | **`xdg-cloud`** | Already the working name, no collision, broad enough to house both tools |
| License | **MIT** | Generic public-spec plumbing, solo utility, permissive is the right default |

---

## 2. Scripts Located & Verified

Both files were **NOT** on the Mac during initial reconnaissance; the team-lead staged
them after the teachback gate.

| File | Path | Lines | Role |
|------|------|-------|------|
| `cloud-xdg-provision.sh` | `/tmp/xdg-scripts-staging/cloud-xdg-provision.sh` | 336 | Cloud-resident user-data ontology; redirects local dirs into the cloud via symlinks |
| `home-tree.sh` | `/tmp/xdg-scripts-staging/home-tree.sh` | 308 | Local XDG tree + safe rclone backup mirror (cloud is a destination, never live `$HOME`) |

### 2.1 Linter Results (verbatim)

```
############ shellcheck cloud-xdg-provision.sh ############   exit 0  (no output)
############ bash -n   cloud-xdg-provision.sh ############   exit 0
############ shellcheck home-tree.sh           ############   exit 0  (no output)
############ bash -n   home-tree.sh            ############   exit 0
```

- Tool: `ShellCheck 0.11.0` (installed on this Mac, user-confirmed).
- Shell: `GNU bash, version 3.2.57(1)-release (x86_64-apple-darwin24)` — stock macOS `/bin/bash`.
- **Result: both scripts are clean. Zero shellcheck warnings, zero syntax errors.**

### 2.2 Live Dry-Run Execution (bash 3.2)

Both scripts ran end-to-end under `/bin/bash` (3.2.57) in their default dry-run mode:

- `home-tree.sh` — produced the local-tree plan, wrote its rclone filter, and reported
  "cloud untouched" (no `--sync` given). Correct.
- `cloud-xdg-provision.sh` — produced the cloud ontology plan and, on real populated
  dirs, correctly **warned** (`"Desktop has contents and is NOT a symlink. Run with
  --relocate…"`) instead of touching anything. Correct safe-by-default behavior.
- `--style mac` correctly capitalized cloud folder names (Desktop/Documents/Music/…).

> Note: a transient `exit 141` appeared in the harness only because the test piped output
> through `head`, which closes the pipe early (SIGPIPE = 128+13). It is a test artifact,
> **not** a script fault — the unpiped scripts exit 0.

---

## 3. Resolved Decisions

### Decision 1 — `home-tree.sh` scope: **INCLUDE as a co-equal secondary tool**

**Call:** Ship both scripts in the same repo. Do not archive or drop `home-tree.sh`.

**Rationale:**
1. **They are complementary, not redundant.** `cloud-xdg-provision.sh` answers *"make the
   cloud my live home"*; `home-tree.sh` answers *"keep my home local, back it up safely."*
   These are two legitimate risk appetites for the same user. A toolkit that offers both
   strategies is more useful than one that forces a single philosophy.
2. **Shared design DNA.** Identical plumbing (`log/info/warn/die/run`), identical
   dry-run-by-default discipline, identical platform detection (`uname -s` + Termux probe),
   and the same non-negotiable principle — *XDG config/data/state/cache stay LOCAL.* They
   read like siblings, which keeps the repo coherent.
3. **Production quality, zero maintenance cost.** Both already pass shellcheck clean and run
   on bash 3.2. Including a finished, working 308-line tool costs nothing; dropping it
   discards real value.

**One philosophical tension to document (for ARCHITECT → README):** the two tools take
*opposing* stances on whether the cloud should hold live data. They do **not** actually
contradict each other on the dangerous case — `cloud-xdg-provision.sh` only offloads
*user-data* dirs (Documents, Music, …) and explicitly keeps SQLite-backed
config/data/state/cache **local**, which is exactly the footgun `home-tree.sh` warns about.
The README must make the "pick one strategy per machine" choice explicit so a user does not
run both and confuse themselves.

### Decision 2 — Repo name: **`xdg-cloud`**

**Call:** Name the repository **`xdg-cloud`**. Final.

**Rationale:**
- It is **already the working name** (team `pact-xdg-init`, feature task "xdg-cloud").
- **No collision:** `~/repos/xdg-cloud` and `~/repos/cloud-xdg-provision` do not exist
  (confirmed via `ls`).
- **Correct breadth:** `cloud-xdg-provision` is the name of *one of the two scripts* —
  using it as the repo name would wrongly subordinate `home-tree.sh`. `xdg-cloud` is the
  umbrella concept (XDG ↔ cloud) that cleanly houses both tools and any future additions.

### Decision 3 — License: **MIT**

**Call:** Apply the **MIT License**. Recommend against UNLICENSED/private.

**Rationale:**
- The scripts are **generic plumbing built on public specifications** (XDG Base Directory
  Spec, xdg-user-dirs, FHS 3.0, Apple File System Programming Guide). There is no
  proprietary logic, no secrets, no business IP to protect.
- MIT is the conventional, low-friction choice for a small solo developer utility; it
  permits the author to publish, share, and reuse freely with attribution.
- UNLICENSED only makes sense for private/proprietary code that must never be redistributed.
  Nothing here warrants that restriction, and choosing it would needlessly block sharing.

---

## 4. Environment & Runtime Constraints (confirmed)

| Fact | Status | Evidence |
|------|--------|----------|
| macOS `/bin/bash` is 3.2 | ✅ Confirmed | `GNU bash, version 3.2.57(1)-release` |
| Scripts are bash-3.2-safe | ✅ Confirmed | No `declare -A`, no `mapfile`/`readarray`, no `${var^^}`/`${var,,}`, no process substitution `<(…)`, no negative array indices |
| Indexed arrays used | ✅ Safe | `home-tree.sh` uses `SAFE_DIRS=(…)`, `NEVER_DIRS=(…)`, `cmd=(…)` — **indexed** arrays, fully supported in 3.2 (only *associative* arrays are 3.2-unsafe) |
| Strict mode | ✅ Both | `set -euo pipefail` in both scripts |
| `~/repos` exists | ✅ Confirmed | `ls -la ~/repos` |
| `~/repos` is NOT a git repo at root | ✅ Confirmed | no `~/repos/.git` |
| `~/repos/xdg-cloud` collision | ✅ None | does not exist |

### 4.1 Supported Platforms & Platform-Specific Code Paths

Both scripts detect platform via `case "$(uname -s)"` → `Darwin`=macos / `Linux` (+ Termux
probe `$TERMUX_VERSION` or `/data/data/com.termux`) = linux|termux / `*`=unknown.

| Platform | `cloud-xdg-provision.sh` | `home-tree.sh` |
|----------|--------------------------|----------------|
| **macOS** | Auto-detects `~/Library/CloudStorage/GoogleDrive-*/My Drive` as `CLOUD_ROOT`; uses Apple dir names (`~/Movies`); skips `user-dirs.dirs` (symlinks handle it) | Informational Drive-mount detection only; backups always routed through rclone for lock-safety |
| **Linux** | **`CLOUD_ROOT` is mandatory** (no auto-detect) — must point at an rclone/ocamlfuse/insync mount; uses XDG dir names (`~/Videos`); writes `$XDG_CONFIG_HOME/user-dirs.dirs` | rclone-only; XDG default naming |
| **Termux/Android (A15)** | Same as Linux — `CLOUD_ROOT` mandatory | Prints Termux hint (`pkg install rclone`, `$PREFIX`) |

**External runtime dependencies:**
- `cloud-xdg-provision.sh`: coreutils (`mkdir`, `ln`, `mv`, `rmdir`, `readlink`, `cut`,
  `tr`, `date`, `basename`, `uname`); prefers `rsync` for `--relocate`, falls back to `cp -a`.
- `home-tree.sh`: **`rclone` required** for any `--sync`/`--bisync` (guarded by
  `require_rclone`, which also verifies the named remote exists). `bisync` requires a
  reasonably current rclone build.

---

## 5. Honest Critique (real observations, not nitpicks for their own sake)

**Strengths worth preserving (do not "refactor away"):**
- **Safe-by-default is genuinely well executed.** Dry-run is the default in both; nothing
  destructive runs without explicit `--apply` *plus* an action flag. `--relocate` renames
  the original aside (`*.pre-offload-DATE`) and never deletes. `home-tree.sh` archives
  overwritten/deleted files to a timestamped `--backup-dir` and guards with `--max-delete`.
- **The rclone filter in `home-tree.sh` is the single source of truth** for what may reach
  the cloud, ordered exclude → allow → final catch-all deny. Solid, auditable.

**Minor notes (informational, not blockers — flag to ARCHITECT/README):**
1. **Strategy collision is a UX risk, not a code bug.** The two scripts embody opposite
   cloud philosophies; without a README that says "choose one per machine," a user could
   run `cloud-xdg-provision.sh --apply --relocate` and `home-tree.sh --apply --sync` on the
   same home and create confusing double-management. **Action: README must frame them as
   an either/or strategy choice.**
2. `home-tree.sh` filter denylist includes capitalized `/Config/** /Cache/** /State/**
   /Downloads/**` (HOME_TREE_ROOT-relative) in addition to `.cache/**` and
   `.local/state/**`. This is intentional belt-and-suspenders, not a duplication bug.
3. `cloud-xdg-provision.sh print_mapping` re-invokes `cloud_name` several times inside a
   heredoc — purely cosmetic, no correctness impact.

**No flaws found that block initialization.** Both scripts are above-average quality.

---

## 6. Scope Lock (hand-off contract for ARCHITECT)

**Repo:** `xdg-cloud` · created at `/Users/administrator/repos/xdg-cloud` (not yet a git repo).

**In scope (files to version-control):**
- `cloud-xdg-provision.sh` (primary tool — cloud-as-live-home)
- `home-tree.sh` (secondary tool — local-home + rclone backup mirror)
- `LICENSE` (MIT)
- `README.md` (must explain the **either/or strategy choice** between the two tools;
  document platform `CLOUD_ROOT`/rclone prerequisites; bash-3.2 note)
- `.gitignore` (shell-toolkit appropriate: editor/OS cruft, `*.pre-offload-*`, generated
  filter files)

**Out of scope:** any change to the scripts' logic (they pass clean — Boy-Scout-only edits
if any, deferred to CODE phase and explicitly justified).

**Constraints carried forward:**
- bash 3.2 safety is a **hard constraint** — no associative arrays, `mapfile`, `${var^^}`,
  or unsafe process substitution may be introduced.
- Preserve safe-by-default (dry-run default, explicit `--apply`, never-delete) semantics.

---

## 7. Open Questions

**None blocking.** One item for the user/architect to confirm at README-authoring time:

- Should the README recommend a **default tool** for a first-time user (e.g., lead with
  `home-tree.sh` backup as the lower-risk on-ramp, present `cloud-xdg-provision.sh` as the
  advanced "live cloud home" option)? This is an editorial framing choice, not a technical
  blocker — ARCHITECT can proceed without it.

---

## References

- XDG Base Directory Specification — config/data/state/cache layer (cited in script headers)
- xdg-user-dirs — desktop/documents/music/… user-dir layer
- FHS 3.0 + `systemd file-hierarchy(7)` — Linux root model
- Apple File System Programming Guide — `~/Library`, `~/Movies` naming
- `rclone` docs — `sync`, `bisync`, `--filter-from`, `--backup-dir`, `--max-delete`
- Verified locally: `shellcheck 0.11.0`, `bash 3.2.57`, live dry-run on macOS (2026-06-26)
