# ADR — `xdg-cloud` Repository Initialization

**Phase:** PACT Architect · **Author:** pact-architect · **Date:** 2026-06-26
**Status:** Accepted — gate for CODE phase. The coder materializes exactly what this document specifies.
**Upstream:** PREPARE brief (`docs/preparation/xdg-cloud.md`), teachback Task #8.
**Scope:** Repository scaffolding only. **No script-logic changes.** Both scripts pass `shellcheck 0.11.0`
and `bash -n` clean on bash 3.2.57; Boy-Scout edits are deferred to CODE and must be explicitly justified.

---

## 1. Executive Summary

`xdg-cloud` is a version-controlled git repository housing two production-quality, cross-OS bash
scripts that solve the same problem domain (getting user data to the cloud without breaking XDG/app
correctness) via **two opposite strategies**:

| Script | Strategy | Cloud role |
|--------|----------|------------|
| `cloud-xdg-provision.sh` | Cloud-as-live-home | **Live data LIVES in the cloud**; local `~/Documents`, `~/Music`, … become symlinks pointing into the cloud root. |
| `home-tree.sh` | Local-home + backup mirror | **Local data is canonical**; the cloud is a *backup destination* reached via `rclone` (one-way `sync` or two-way `bisync`). |

This ADR records the repository structure, tooling, and conventions the coder will scaffold around
these two finished scripts. It resolves all seven open decisions with no TBDs.

### 1.1 The Opposite-Philosophy Flag (load-bearing — repeated in §4 and §11)

> ⚠️ **The two scripts embody OPPOSITE cloud philosophies. They are an EITHER/OR choice per machine,
> NOT complementary defaults.** A user who runs `cloud-xdg-provision.sh --apply --relocate` *and*
> `home-tree.sh --apply --sync` on the same `$HOME` creates confusing double-management: data living
> in the cloud (symlinked locally) while *also* being rclone-mirrored to a second cloud location.
>
> This is a **UX risk, not a code bug** — the scripts do not corrupt each other (both keep
> config/data/state/cache local). But the README **must** frame them as a strategy fork:
> *"Pick one strategy per machine."* This framing is a hard requirement on the CODE phase, not
> optional polish.

---

## 2. System Context (C4 Level 1)

```
            +-----------------------------+
            |          Operator           |
            |  (solo dev: macOS/Linux/    |
            |   Termux shell user)        |
            +--------------+--------------+
                           | runs scripts (dry-run by default)
                           v
   +-----------------------------------------------------+
   |                   xdg-cloud repo                     |
   |                                                      |
   |   bin/cloud-xdg-provision.sh   bin/home-tree.sh      |
   |        (live cloud home)        (local + backup)     |
   +------+--------------------------------+--------------+
          |                                |
          | symlinks ~/Documents etc.      | rclone sync/bisync
          v                                v
  +----------------+               +----------------------+
  | Cloud Drive    |               | rclone remote        |
  | (Google Drive  |               | (gdrive: Backup/home)|
  |  FUSE mount)   |               +----------------------+
  +----------------+
```

External dependencies (runtime, not build):
- **coreutils** (`mkdir`, `ln`, `mv`, `rmdir`, `readlink`, `cut`, `tr`, `date`, `basename`, `uname`) — both scripts.
- **rsync** — preferred by `cloud-xdg-provision.sh --relocate`; falls back to `cp -a`.
- **rclone** — *required* by `home-tree.sh` for any `--sync`/`--bisync` (`bisync` needs a current build).
- **shellcheck** — build/dev dependency only (lint target + pre-commit hook).

The repo itself ships **no runtime install of these**; the README documents prerequisites per platform.

---

## 3. Decision 1 — Directory Layout

**Decision: Accept the proposed layout with two refinements** — scripts go in `bin/`, and a committed
`hooks/` directory is added (see Decision 2).

### 3.1 Final Directory Tree

```
xdg-cloud/
├── bin/
│   ├── cloud-xdg-provision.sh      # primary tool: cloud-as-live-home (chmod +x)
│   └── home-tree.sh                # secondary tool: local home + rclone backup (chmod +x)
├── hooks/
│   └── pre-commit                  # committed hook; runs `make lint`. Wired by `make install`. (chmod +x)
├── docs/
│   ├── preparation/
│   │   └── xdg-cloud.md            # PREPARE brief (already present)
│   └── architecture/
│       └── xdg-cloud-adr.md        # this document (already present)
├── tests/
│   ├── smoke.sh                    # smoke + idempotency tests; run by `make test` in a sandbox (chmod +x)
│   └── sandbox/                    # gitignored test scratch dir (created at test time; .gitkeep optional)
├── README.md                       # MUST frame the either/or strategy choice (see §11)
├── CHANGELOG.md                    # keep-a-changelog format; first entry = 0.1.0 Unreleased→initial
├── LICENSE                         # MIT, author "Pipulate" (matches git config)
├── VERSION                         # single source of truth for version string (see Decision 5)
├── .gitignore                      # see Decision 7
├── .shellcheckrc                   # see Decision 6
└── Makefile                        # lint / test / install / version targets (see Decision 3)
```

### 3.2 Rationale & Deviations

- **`bin/` for scripts (deviation from "scripts at root").** The proposed layout listed `bin/` and the
  scripts ship there. Keeping executables in `bin/` keeps the repo root readable (docs + metadata only)
  and matches the convention a user expects when adding the repo to `PATH` (`export PATH="$PWD/bin:$PATH"`).
  The README usage examples and the pre-commit hook path references must use `bin/`.
- **`hooks/` added.** Required by Decision 2 (committed hook). Small, single file.
- **`docs/` already split** into `preparation/` and `architecture/` — preserve it; do not flatten.
- **`tests/sandbox/`** is the only generated output location, and it is gitignored. Tests must never
  write outside it (no touching the real `$HOME`). This keeps `make test` safe to run anywhere.
- **Single responsibility:** each top-level entry has one job — `bin/` executes, `docs/` explains,
  `tests/` verifies, root files are repo metadata. No mixing.

---

## 4. Decision 2 — Pre-Commit Hook Delivery

**Decision: Option B — committed `hooks/pre-commit` + `make install` wires it.** Recommended and adopted.

### 4.1 What this means

- `hooks/pre-commit` is a **committed, version-controlled** file (so it survives clone and is reviewable).
- Git does not execute files in `hooks/` automatically — only `.git/hooks/`. So `make install` creates the
  link: `ln -sf ../../hooks/pre-commit .git/hooks/pre-commit` (relative symlink, repo-portable), and
  `chmod +x hooks/pre-commit`.
- The hook body runs `make lint` and blocks the commit on shellcheck failure.

### 4.2 Why B over A (raw `.git/hooks/pre-commit`)

| | Option A (raw `.git/hooks`) | Option B (committed `hooks/` + `make install`) ✅ |
|---|---|---|
| Survives clone | ❌ No — `.git/` is not cloned content | ✅ Yes — committed |
| Reviewable in PRs | ❌ No | ✅ Yes |
| Re-install after fresh clone | Manual, undocumented | `make install`, documented |
| Portability across machines | ❌ Per-machine setup | ✅ One command everywhere |

**Trade-off / honest risk:** Option B does **not** auto-activate. A fresh clone has the hook file but
no `.git/hooks/pre-commit` symlink until the user runs `make install`. This is acceptable and standard —
the alternative (auto-running clone-time hooks) is a known security anti-pattern. The README "Setup"
section must list `make install` as the one-time activation step, and CI/local lint via `make lint`
provides a backstop if a contributor forgets.

### 4.3 `hooks/pre-commit` reference content

```sh
#!/usr/bin/env bash
# xdg-cloud pre-commit hook — blocks commits that fail shellcheck.
# Installed via `make install` (symlinked into .git/hooks/pre-commit).
set -euo pipefail
if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'pre-commit: shellcheck not found — install it or run `make lint` manually.\n' >&2
  exit 1
fi
exec make --no-print-directory lint
```

---

## 5. Decision 3 — Makefile vs Justfile

**Decision: Makefile.** `make` is preinstalled on macOS (Xcode CLT), every Linux distro, and available
in Termux (`pkg install make`). `just` is a separate Rust binary the user must install first — friction
that contradicts the project's "works out of the box on macOS+Linux+Termux bash" goal. For a solo bash
toolkit with three trivial targets, a Makefile is the universal, zero-extra-dependency choice.

**Trade-off:** Makefiles have tab-vs-space sensitivity and arcane syntax for complex logic. Mitigation:
keep targets thin — each is a one-or-two-line shell-out. No recursive make, no pattern rules, no
`.PHONY` gymnastics beyond declaring the phony targets. If logic grows, push it into a script in `bin/`
or `tests/`, not into the Makefile.

### 5.1 Makefile Target Signatures (the coder implements these)

| Target | Behavior | Notes |
|--------|----------|-------|
| `make lint` | Run `shellcheck` on `bin/*.sh`, `hooks/pre-commit`, `tests/*.sh`. Honors `.shellcheckrc`. Exit non-zero on any finding. | Default target. Also invoked by the pre-commit hook. |
| `make test` | Run `tests/smoke.sh` in a sandbox (`tests/sandbox/`). Must not touch real `$HOME`. | Smoke + idempotency only; full TEST phase is separate. |
| `make install` | `chmod +x bin/*.sh hooks/pre-commit`; symlink `hooks/pre-commit` → `.git/hooks/pre-commit` (relative). | Idempotent: re-running is safe (`ln -sf`). |
| `make version` | Print the contents of `VERSION`. | Single source for release tagging (`git tag v$(make version)`). |

Required Makefile conventions:
- `.PHONY: lint test install version`
- `.DEFAULT_GOAL := lint`
- `VERSION := $(shell cat VERSION)` — Makefile reads the VERSION file; it does not hardcode the string.
- No dependency beyond `bash`, `shellcheck` (for lint), coreutils. Do **not** call `just`, `npm`, `python`, etc.

---

## 6. Decision 4 — Branching & Commit Convention

**Decision: Trunk-based on `main`, Conventional Commits.**

- **Default branch:** `main`.
- **Trunk-based:** Solo project — commit directly to `main`. No feature branches, no PR ceremony required
  for routine work. (PACT peer-review may still open a PR for this initialization; that is a process
  artifact, not an ongoing branching policy.)
- **Conventional Commits:** `type(scope): subject` where type ∈ {`feat`, `fix`, `chore`, `docs`, `test`,
  `refactor`}. Scope optional. Imperative mood, ≤72-char subject.
- **Tags:** Release tags are `v<VERSION>` (e.g. `v0.1.0`), created when `VERSION` is bumped.
- **Co-author trailer:** Per repo policy, end commit messages with the Claude co-author trailer.

### 6.1 Initial Commit Sequence (the coder follows this exactly)

The repo is initialized from scratch at `/Users/administrator/repos/xdg-cloud` (does not yet exist as a
git repo — confirmed in PREPARE). Materialize files, then commit in this order so history is legible:

```
1. chore: initialize xdg-cloud repository
   - .gitignore, .shellcheckrc, LICENSE (MIT), VERSION (0.1.0)

2. feat: add cloud-xdg-provision.sh (cloud-as-live-home strategy)
   - bin/cloud-xdg-provision.sh (verbatim from staging, chmod +x)

3. feat: add home-tree.sh (local home + rclone backup strategy)
   - bin/home-tree.sh (verbatim from staging, chmod +x)

4. build: add Makefile and committed pre-commit hook
   - Makefile (lint/test/install/version), hooks/pre-commit

5. test: add smoke + idempotency tests
   - tests/smoke.sh, tests/sandbox/.gitkeep (sandbox dir kept but contents ignored)

6. docs: add README, CHANGELOG, and PACT design docs
   - README.md (either/or strategy framing), CHANGELOG.md,
     docs/preparation/xdg-cloud.md, docs/architecture/xdg-cloud-adr.md
```

Commits 2–5 are independent and could be reordered, but this sequence (metadata → primary script →
secondary script → tooling → tests → docs) tells the cleanest story. Each commit should leave the repo
in a `make lint`-clean state. Note: `make install` cannot run until after commit 1 creates `.git/`, so
the pre-commit hook is not active during the initial sequence — that is expected and fine.

---

## 7. Decision 5 — Version String Location

**Decision: A single `VERSION` file at repo root is the canonical source of truth.** (Confirmed by team-lead.)

- `VERSION` contains a bare semver string, no `v` prefix, single line, e.g. `0.1.0`.
- The Makefile reads it: `VERSION := $(shell cat VERSION)`; `make version` echoes it; release tags are
  `v$(cat VERSION)`.
- The two scripts do **not** carry their own version constants. Their header comments stay descriptive
  (no version line to drift). If a `--version` flag is ever desired later, the script can `cat` the
  repo-root VERSION relative to its own location — but that is a future feature, out of scope here.

**Why not per-script headers or a Makefile variable:**
- Per-script headers → two strings to keep in sync; guaranteed to drift. Rejected.
- Makefile-only variable → version lives in build tooling, invisible to anything that isn't `make`;
  no single file to `cat` from a script or CI. Rejected.
- A dedicated `VERSION` file is language-agnostic, greppable, `cat`-able from any tool, and the
  conventional home for a release string. Adopted.

**Initial value:** `0.1.0` (pre-1.0: scaffolding of two existing tools, API/flags considered unstable
until 1.0).

---

## 8. Decision 6 — `.shellcheckrc` Content

**Decision: `shell=bash`, `enable=all`, with a small set of justified suppressions.** Both scripts
already pass clean, so this config formalizes the bar rather than papering over findings.

### 8.1 Final `.shellcheckrc`

```
# xdg-cloud shellcheck configuration
# Both scripts target stock macOS bash 3.2.57 and must stay 3.2-safe.

# Treat all scripts as bash (they use #!/usr/bin/env bash).
shell=bash

# Opt into all optional checks — these scripts are clean today; keep them clean.
enable=all

# --- Justified, repo-wide disables ---
# SC2310/SC2311: 'enable=all' turns on function-in-condition invalidates-set-e warnings.
#   These scripts intentionally use functions in conditionals (e.g. `if mount="$(find_macos_drive_mount)"`)
#   where the non-zero path is handled. Enable per-case review in CODE, but do not let the
#   blanket warning block an already-correct, safe-by-default codebase.
# Leave SC2310/SC2311 commented unless `make lint` actually surfaces them — add only if needed:
# disable=SC2310,SC2311
```

**Guidance to coder:** Start with `shell=bash` + `enable=all` and **no** disables. Run `make lint`.
If `enable=all` surfaces *new* findings on the already-clean scripts (most likely the optional
SC2310/SC2311 "invalidate set -e" family from the macOS-mount `if mount="$(...)"` idiom in
`home-tree.sh`), then add a **narrowly-scoped, commented** `disable=` line for exactly those codes —
do not broaden it. The `bash -n` + `shellcheck 0.11.0` PREPARE baseline used default checks; `enable=all`
is stricter, so a small disable list is acceptable *if and only if* each entry is justified inline.
Never disable a check to hide a real bug.

---

## 9. Decision 7 — `.gitignore` Content

**Decision:** OS cruft, editor swap/IDE files, the test sandbox, and the scripts' own generated artifacts.

### 9.1 Final `.gitignore`

```
# === OS cruft ===
.DS_Store
.DS_Store?
._*
.Spotlight-V100
.Trashes
Thumbs.db

# === Editor / IDE ===
*.swp
*.swo
*~
.idea/
.vscode/
*.sublime-*

# === Test sandbox (created by `make test`) ===
tests/sandbox/*
!tests/sandbox/.gitkeep

# === Script-generated artifacts ===
# cloud-xdg-provision.sh --relocate renames originals aside before symlinking:
*.pre-offload-*
# home-tree.sh writes its rclone filter to $TMPDIR by default, but if a user
# redirects it into the repo, ignore generated filters:
*.rclone-filter
home-tree.rclone-filter
```

**Notes for coder:**
- `tests/sandbox/.gitkeep` is committed so the directory exists; everything else under `sandbox/` is ignored.
- `*.pre-offload-*` matches the timestamped aside dirs `cloud-xdg-provision.sh` creates during `--relocate`
  (`${src}.pre-offload-YYYYMMDD-HHMMSS`). These should never be committed if a user runs the tool inside a clone.
- The rclone filter normally lands in `$TMPDIR` (outside the repo), but the ignore is cheap insurance.

---

## 10. Tests Scaffold (CODE phase target)

`tests/smoke.sh` is **smoke + idempotency only** — not the full TEST phase. It must:

1. Run each script in **default dry-run mode** under `/bin/bash` (3.2 path) and assert exit 0.
   - Guard against the SIGPIPE artifact noted in PREPARE §2.2: do **not** pipe script output through
     `head`/`grep -q` in a way that closes the pipe early (that produced a spurious exit 141). Capture to
     a variable or file, then inspect.
2. Point `CLOUD_ROOT` / `HOME_TREE_ROOT` / `--root` at `tests/sandbox/` so nothing touches the real `$HOME`.
3. Assert idempotency: running `--apply` twice in the sandbox produces the same end state with no error
   (symlink already correct → "ok"; dir already exists → no-op).
4. Never invoke `rclone` for real (no remote configured in CI) — exercise only the local-tree + filter-write
   paths of `home-tree.sh` (i.e. without `--sync`/`--bisync`), and the folder/symlink paths of
   `cloud-xdg-provision.sh`.

`make test` invokes this in the sandbox. Keep it dependency-light (bash + coreutils).

---

## 11. README Framing Guidance (HARD REQUIREMENT for CODE phase)

The README is not just docs — it carries the safety-critical framing the PREPARE brief flagged. The coder
**must** include, at minimum:

1. **Strategy fork up top.** Before usage, a clear "Choose ONE strategy per machine" section:

   | Use `cloud-xdg-provision.sh` if… | Use `home-tree.sh` if… |
   |---|---|
   | You want your data to *live in the cloud* and your local folders to be pointers (symlinks) into it. | You want your data to *stay local* and have a safe, scheduled backup mirror in the cloud. |
   | You trust the cloud drive as primary storage. | You treat the cloud as a backup, not primary. |

   With an explicit warning: **"Do not run both on the same machine/home — they take opposite stances on
   where live data lives and will double-manage your files."**

2. **Optional editorial on-ramp (architect recommendation, coder may adopt):** lead first-time users toward
   `home-tree.sh` (local stays canonical; backup is lower-risk) as the gentle default, and present
   `cloud-xdg-provision.sh` as the advanced "live cloud home" option. PREPARE §7 left this as an editorial
   choice; recommending it reduces footgun risk. Not mandatory, but encouraged.

3. **Per-platform prerequisites:**
   - macOS: bash 3.2 note ("run with `/bin/bash`"); Google Drive mount auto-detected by
     `cloud-xdg-provision.sh`; `rclone` needed for `home-tree.sh` sync.
   - Linux: `CLOUD_ROOT` is **mandatory** for `cloud-xdg-provision.sh` (no auto-detect); `rclone` for backups.
   - Termux/Android: `CLOUD_ROOT` mandatory; `pkg install rclone make`.

4. **Safe-by-default reminder:** both scripts are dry-run by default; nothing destructive runs without
   `--apply` plus an action flag. Document this prominently so users trust running them to preview.

5. **Setup step:** `make install` to activate the pre-commit hook (and `chmod +x`).

---

## 12. Conventions the Coder Must Follow (summary checklist)

- [ ] Scripts copied **verbatim** from staging into `bin/` (no logic changes; Boy-Scout edits only if
      justified and noted in HANDOFF). Preserve `set -euo pipefail` and bash-3.2 safety.
- [ ] **No bash-3.2-unsafe constructs** introduced anywhere (no `declare -A`, `mapfile`/`readarray`,
      `${var^^}`/`${var,,}`, process substitution `<(…)`, negative array indices).
- [ ] `bin/*.sh`, `hooks/pre-commit`, `tests/smoke.sh` are `chmod +x`.
- [ ] `make lint` passes clean before every commit; repo is lint-clean at each commit in the sequence.
- [ ] README contains the either/or strategy fork and the "don't run both" warning (§11) — non-negotiable.
- [ ] `VERSION` = `0.1.0`; CHANGELOG first entry documents the 0.1.0 initialization (keep-a-changelog).
- [ ] LICENSE is MIT, attributed to "Pipulate" (matches `git config user.name`).
- [ ] Conventional Commits, trunk-based on `main`, commit sequence per §6.1, Claude co-author trailer.

---

## 13. Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| **User runs both strategies on one home** (double-management). | Medium (UX, not data-loss — both keep config/state/cache local). | README either/or framing + explicit warning (§1.1, §11). Hard requirement on CODE. |
| **`enable=all` surfaces new shellcheck findings** on previously-clean scripts. | Low | Narrowly-scoped, commented `disable=` for justified codes only (§8). Never to hide real bugs. |
| **Pre-commit hook not active after fresh clone.** | Low | Documented `make install` step; `make lint` backstop. Accepted trade-off of committed-hook approach (§4.2). |
| **Test accidentally touches real `$HOME`.** | Medium | All tests scoped to `tests/sandbox/` via `CLOUD_ROOT`/`--root`; gitignored; `make test` runs there only (§10). |
| **SIGPIPE artifact (exit 141)** misread as script failure in tests/CI. | Low | Test harness must not close script output pipe early; capture to var/file (§10.1, PREPARE §2.2). |
| **bash-3.2 regression introduced during scaffolding.** | Low-Medium | Hard constraint in checklist; smoke test runs under `/bin/bash`. |

---

## 14. Open Questions

**None blocking.** One editorial item deferred to README authoring (already framed as a recommendation,
not a blocker): whether to explicitly recommend `home-tree.sh` as the first-time-user default on-ramp
(§11.2). Architect recommends yes; coder may adopt without further sign-off.

---

## 15. Handoff to CODE

This ADR is the CODE gate. The coder (likely `pact-devops-engineer` for shell/build scaffolding, or
`pact-backend-coder`) materializes the tree in §3.1 at `/Users/administrator/repos/xdg-cloud`, follows the
commit sequence in §6.1, and satisfies the §12 checklist. No design decisions remain open — every file's
content or signature is specified here (§3 tree, §4.3 hook, §5.1 Makefile targets, §7 VERSION, §8.1
.shellcheckrc, §9.1 .gitignore, §10 tests, §11 README requirements).
