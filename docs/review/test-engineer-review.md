# Test-Engineer Review — `xdg-cloud` (feature/cloud-xdg-provision)

**Reviewer:** test-engineer · **Date:** 2026-06-28 · **Task:** #4
**Scope reviewed:** `bin/cloud-xdg-provision.sh`, `bin/home-tree.sh`, `tests/smoke.sh`, `Makefile`, ADR §10
**Risk tier assigned:** **HIGH** — this code physically relocates user data (`mv`/`rsync`/`cp` of `~/Documents`, `~/Music`, …) and generates the cloud-sync allow/deny filter. Data-loss and data-leak are the failure modes.

**Method:** Read all sources + ADR/PREPARE. Then ran the existing smoke suite (passes, exit 0) and executed **11 adversarial probes** in throwaway sandboxes to map real behavior of every branch. Findings below are backed by observed behavior, not inference.

---

## Headline

The scripts behave **correctly** in every path I exercised — data was preserved in all relocate variants. The problem is **coverage, not correctness**: the existing `tests/smoke.sh` exercises only the *empty-home → symlink* slice. The two highest-risk surfaces in the entire repo — the **data-migration path (`relocate_dir`)** and the **cloud-sync safety filter (`write_filter`)** — have **zero automated coverage**, and the data-loss *guard* branches are untested despite needing no external dependencies.

**Critical-path branch coverage measured:**

| Function | Branches | Tested | Coverage |
|---|---|---|---|
| `redirect_one()` | 8 | 2 | **25%** |
| `relocate_dir()` | 1 (+rsync/cp fork) | 0 | **0%** |
| `write_filter()` (home-tree safety core) | 1 | 0 | **0%** |

Against the HIGH-tier target (80–90% on critical paths), this is a large gap. **Signal: 🟡 YELLOW** — no test failures and no data-corruption bug found, but cheap, safety-critical tests are missing.

---

## Branch map — `redirect_one()` (bin/cloud-xdg-provision.sh:194–244)

Every branch mapped to its test status:

| # | Branch | Line | Test status |
|---|---|---|---|
| 1 | `wantredir != 1` → create-only, no symlink | 201 | ❌ untested (no assertion that `downloads` is *not* symlinked) |
| 2 | `downloads` + not `--redirect-downloads` → skip | 202–204 | ❌ untested |
| 3 | already-correct symlink → "ok" | 211–214 | ✅ tested (idempotency, Documents) |
| 4 | other/dangling symlink → warn, **leave untouched** | 221–224 | ❌ untested — **see BLOCKING-1** |
| 5 | truly missing → `ln -s` | 227–229 | ✅ tested (first `--apply`) |
| 6 | populated real dir + no `--relocate` → **warn, don't touch** | 232–235 | ❌ untested — **see BLOCKING-1** (this is the data-loss guard) |
| 7 | populated real dir + `--relocate` → `relocate_dir` | 237 | ❌ untested — **see BLOCKING-2** |
| 8 | empty real dir → `rmdir` + `ln -s` | 242–243 | ❌ untested (I verified it works; probe TEST-9) |

Only branches 3 and 5 are covered. The two branches that stand between a user and **silent data loss** (4 and 6) are untested.

---

## BLOCKING

### BLOCKING-1 — Data-loss guard branches untested (and `smoke.sh` overclaims coverage)
**Files:** `bin/cloud-xdg-provision.sh:221-224, 232-235`; `tests/smoke.sh:58-66`

The two branches that *prevent* destruction are unexercised:
- **Populated-dir-without-`--relocate`** (line 233): the guard that refuses to touch a real, populated `~/Documents` unless the user opts in. If a future edit regressed this into the relocate path, a plain `--apply` would start moving data. This is the single most important safety invariant in the tool and has no regression test.
- **Dangling / foreign symlink** (line 221): the fix in commit `0761877` exists precisely to stop a `set -e` abort on a dangling link. I confirmed it works (probe TEST-8: exit 0, link left in place). **But `smoke.sh` never creates a dangling symlink** — so the fix is unprotected against re-regression.

Worse, `smoke.sh:62-65` *claims* this coverage:
> "A clean, empty sandbox HOME has no dangling symlinks, so a correct run exits 0; … which is exactly the regression guard we want."

A clean empty HOME is the one state that **cannot** produce a dangling link. The comment describes a guard the test does not implement — a misleading coverage claim that gives false confidence.

**Both branches are trivially testable with zero external deps** (no rsync, no rclone — just pre-seed the sandbox HOME). They should land in `smoke.sh` before merge. Suggested additions:
1. Pre-create a populated `$HOME/Documents`, run `--apply` *without* `--relocate`, assert it is **still a real dir** (not a symlink) and output contains the warn line.
2. Pre-create a dangling symlink at `$HOME/Desktop`, run `--apply`, assert exit 0 **and** the link is unchanged (regression guard for `0761877`).

### BLOCKING-2 — `relocate_dir()` (the user-data migration core) has 0% coverage
**Files:** `bin/cloud-xdg-provision.sh:246-259`; `tests/smoke.sh` (absent)

`relocate_dir` is the reason this tool exists in its "live cloud home" mode: it `rsync`/`cp`s real user data into the cloud root, `mv`s the original aside, and replaces it with a symlink. It is the highest-consequence code in the PR and has **no automated test at all**.

I verified manually that it works in four variants (probes TEST-5/6/7/10): rsync path, `cp -a` fallback, `--style mac`, content+nesting integrity — all preserved data correctly. That these *currently* work is exactly why they need a permanent guard: there is nothing to catch a regression that, say, swaps the `mv`/`ln` order (which would leave the user with neither original nor symlink mid-failure).

This is partially excused by ADR §10 listing `relocate_dir` as a "TEST-phase target" (see FUTURE-1 for the full integration suite). But at minimum a **single happy-path relocate assertion** belongs in the merge gate: populate a dir, `--apply --relocate`, assert (a) symlink now points into cloud, (b) file content is intact in cloud, (c) an aside dir exists. No rclone needed; rsync is present on macOS/CI.

### BLOCKING-3 — `home-tree.sh` cloud-safety filter (`write_filter`) untested
**Files:** `bin/home-tree.sh:153-187`; `tests/smoke.sh:53-56`

The rclone filter is described in the script and PREPARE as **"the single source of truth for what may reach the cloud."** It denies SQLite (`*.sqlite*`, `*.db*`), `.git`, `node_modules`, cache, state, `Downloads`, etc., then allows only the six SAFE dirs. A regression that drops a deny line (e.g. the `*.sqlite` rule) would **leak lock-sensitive / secret-bearing files into a cloud backup** — the exact footgun the whole tool exists to prevent.

`write_filter()` runs unconditionally in dry-run (line 292), writes a deterministic file, and needs **no rclone**. Yet `smoke.sh` only asserts the dry-run banner prints. The generated filter content is never inspected. This is a security-relevant invariant that is cheap to lock down:
- Run `home-tree.sh --root <sandbox>` (dry-run), then assert the produced `$TMPDIR/home-tree.rclone-filter` contains each critical deny line (`- **/*.sqlite`, `- **/.git/**`, `- /Cache/**`, …) and the trailing catch-all `- *`, **and** the six `+ /Documents/**`-style allows. A golden-file comparison would be even stronger.

---

## MINOR

### MINOR-1 — `relocate_dir` aside-collision nests instead of renaming
**File:** `bin/cloud-xdg-provision.sh:256, 258`

When `${src}.pre-offload-${stamp}` already exists as a directory, `mv "$src" "$aside"` does not fail — `mv` moves the source **inside** the existing dir (probe TEST-6/6b). Result:
```
Music.pre-offload-DATE/old.txt        # pre-existing
Music.pre-offload-DATE/Music/a.mp3    # the "renamed" original, now nested
```
Then line 258 prints `"Original preserved at: $aside"` — but the original is actually at `$aside/Music`, so the documented recovery path misdirects the user. Data is preserved (not a loss), but the recovery story is wrong. Collision is realistic across same-second re-runs or a stale aside. **Fix suggestion:** guard with a uniqueness check (`[ -e "$aside" ] && aside="${aside}.$$"` or fail loudly) — and test it.

### MINOR-2 — Trailing slash on `--cloud-root` breaks idempotency
**File:** `bin/cloud-xdg-provision.sh:208, 212`

`CLOUD_ROOT` is never normalized. Running once with `--cloud-root /path/` and again with `/path` (probe TEST-2) produces a readlink target of `/path//documents` on the first run; the second run's `target` is `/path/documents`, so the equality check at line 212 fails and the script falls into branch 4 ("is a symlink … leaving it") with a spurious warning instead of "ok". Not data-loss, but it violates the idempotency guarantee the ADR §10 #3 makes a hard requirement. **Fix:** strip trailing slash from `CLOUD_ROOT` after resolution; add a slash-variant idempotency test.

### MINOR-3 — No error-path / negative-input assertions
**File:** `tests/smoke.sh` (entirely happy-path)

`set -euo pipefail` failure modes and input validation are never asserted. None of these are tested:
- `--style bogus` → should `die` non-zero (line 124)
- `--cloud-root` / `--style` with no following arg → `${1:?…}` should exit 1 (verified TEST-4)
- unknown option → `die` (line 119)
- `CLOUD_ROOT` unset on non-macOS → `die` (line 146)
- macOS with no Drive mount and no `--cloud-root` → `die` (line 144)

These are one-line `assert` additions (run, capture `$?`, assert non-zero). For a tool guarded by strict mode, the failure contract deserves explicit tests.

### MINOR-4 — Platform branches never exercised (tests are macOS-only)
**Files:** `bin/cloud-xdg-provision.sh:129-135, 162-165, 261-278`; `tests/smoke.sh`

CI/macOS only ever runs the `Darwin` path. The Linux/Termux branches — `write_user_dirs` (line 261), `local_name` Linux naming (`Videos` vs `Movies`, line 164), and the mandatory-`CLOUD_ROOT` `die` on Linux (line 146) — are dead to the test suite. I demonstrated (probe TEST-11) that a **`uname` shim on `PATH`** exercises the Linux `user-dirs.dirs` generation cleanly on macOS, with correct output. Recommend adding a shimmed-Linux test rather than leaving these branches uncovered. Note also a latent inconsistency this would surface: on Linux, `write_user_dirs` writes `XDG_DOWNLOAD_DIR=<cloud>/downloads` even though `~/Downloads` is *not* symlinked (downloads is create-only) — the user-dirs file and the symlink layer disagree about downloads.

### MINOR-5 — Briefing/repo mismatch: no `bats`; harness is hand-rolled bash
The review brief referenced `tests/test_provision.bats`. The actual suite is `tests/smoke.sh` using a hand-rolled `assert_contains`. The plain-bash choice is *correct* given the macOS-3.2/Termux dependency-light constraint (bats would add a dep) — flagging only so the team knows there is no bats framework and the "bats test quality" review item resolves to "no bats in use."

---

## FUTURE (legitimate TEST-phase targets, documented in ADR §10)

- **FUTURE-1 — Full `relocate_dir` integration suite.** Beyond the BLOCKING-2 happy path: rsync vs `cp -a` fallback equivalence (force-absent rsync via `PATH` shim — verified workable in TEST-10), content/permission/symlink integrity, empty-dir vs populated-dir routing, and a mid-failure simulation (make `mv` fail and assert the original is recoverable). 
- **FUTURE-2 — `home-tree.sh` sync/bisync against a local rclone backend.** `rclone` supports a local remote (`:local:` or a configured local remote) — this exercises `do_backup`/`do_bisync`, the `--max-delete` guard, `--backup-dir` archiving, and the bisync `--resync` first-run marker logic **without Google Drive**. Currently 100% skipped (`smoke.sh:99-100`).
- **FUTURE-3 — Unit tier for pure functions.** `cloud_name()`, `local_name()`, `field()` are pure and side-effect-free; they deserve fast isolated table-driven tests (xdg vs mac styling, field parsing of the `|`-delimited `OFFLOAD_SET`). None exist today.

---

## Test-tier assessment (pyramid)

| Tier | Status |
|---|---|
| **Unit** | ❌ Absent. Pure functions (`cloud_name`/`local_name`/`field`) untested in isolation. |
| **Integration** | ⚠️ Only the symlink-creation slice. Migration (`relocate_dir`) and rclone (`do_backup`/`do_bisync`) absent. |
| **Smoke** | ✅ Present and competently built (see below). |

For a small shell toolkit an "inverted" emphasis (heavy integration, light unit) is reasonable — but currently the integration tier is the *thinnest*, which is backwards for data-mutating code.

## What `smoke.sh` does well (credit where due)

Genuinely solid harness engineering — these are correct and worth preserving:
- **Isolation:** PID-suffixed sandbox (`smoke.$$`), `trap cleanup EXIT`, `HOME` override (correct — the script resolves local paths as `$HOME/<name>`, so `--cloud-root` alone is insufficient; the harness comment at lines 13-17 gets this exactly right).
- **No shared state / reliable cleanup:** fresh subdirs per scenario; idempotency test deliberately reuses `apply_home` across two runs (the correct setup for an idempotency assertion).
- **SIGPIPE-safe:** capture-then-inspect instead of piping through `grep -q`/`head` — avoids the spurious exit-141 documented in PREPARE §2.2.
- **3.2 path:** runs under `/bin/bash` to hit the macOS bash-3.2 code path.
- **Precise assertions:** asserts the specific banner line, not a loose match an error could satisfy.

---

## Signal Output

```
Risk Tier: HIGH (user-data migration; filter generation is data-leak-sensitive)
Signal: YELLOW
Coverage: ~25% critical paths (redirect_one 2/8 branches; relocate_dir 0%; write_filter 0%)
Uncertainty Coverage: N/A (peer review — no coder HIGH-uncertainty flags in handoff; reviewer self-elevated relocate_dir + write_filter to HIGH)
Findings:
  BLOCKING-1: data-loss guard branches (populated-no-relocate; dangling symlink) untested AND smoke.sh overclaims the dangling-guard coverage — both trivially testable, no external deps
  BLOCKING-2: relocate_dir (data-migration core) has 0% coverage; min. one happy-path assertion needed at merge gate
  BLOCKING-3: home-tree write_filter (cloud allow/deny safety source-of-truth) untested; deny-line regression would leak SQLite/secrets — no rclone needed to test
  MINOR-1: relocate_dir aside-collision nests via mv; "Original preserved at" message then misdirects recovery
  MINOR-2: trailing-slash on --cloud-root breaks idempotency (no CLOUD_ROOT normalization)
  MINOR-3: no error-path/negative-input assertions (set -euo pipefail contract untested)
  MINOR-4: platform branches (Linux user-dirs, mandatory-CLOUD_ROOT die) never exercised; uname-shim makes them testable on macOS
  MINOR-5: brief referenced bats; actual harness is hand-rolled bash (correct choice — no bats present)
  FUTURE-1/2/3: full relocate integration, rclone-via-local-backend, pure-function unit tier
```

**Recommendation:** Not RED — the scripts are correct in every probed path and the gaps are partly documented deferrals (ADR §10). But the three BLOCKING items are *cheap* (no rsync/rclone needed) and protect against data-loss/data-leak, so they should be closed before this merges rather than deferred wholesale to a later TEST phase. The domain to route fixes to is **devops-engineer** (shell/test authoring).
