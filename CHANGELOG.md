# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-07-05

Interactive iCloud sync: a read-only sync-status lane, a fail-closed download
free-space gate, and the symlink-confinement fix that makes the iCloud lanes
usable from `xdg-tui` on a provisioned home.

### Added
- `--icloud-sync-status <path>`: read-only recursive iCloud sync summary —
  dataless / not-uploaded / in-sync counts, bytes-to-download, bytes-evictable,
  free-space line, and a `brctl` health check that surfaces stuck sync. Batched
  helper invocation (one spawn per ARG_MAX-safe chunk, fail-closed accounting).
  Wired into `xdg-tui` as a read-only pane on code and xdg rows.

### Changed
- `--icloud-download` materializes **dataless files only** and its plan header
  reports count + total bytes; it refuses (fail-closed, dry-run and apply alike)
  when the download would leave less than `ICLOUD_DL_MARGIN_BYTES` free
  (default 1 GiB) — ENOSPC mid-materialization can jam fileproviderd.

### Fixed
- iCloud path confinement now **resolves symlinks on both sides** before the
  CloudDocs prefix check (`icloud_resolve_under_root`): on a provisioned home
  (symlinked entries) every TUI iCloud action previously failed with "path is
  not under iCloud Drive"; conversely a path that lexically looked inside but
  resolved outside was accepted. Both directions are now smoke-pinned by a
  symlink-escape matrix, and `ICLOUD_ROOT` is env-overridable for sandboxed
  tests without weakening production confinement (the root itself is resolved
  before every compare).

### Security
- `ICLOUD_DL_MARGIN_BYTES` is now validated digits-only at load. It flows into a
  bash arithmetic context, where an array-subscript-with-command-substitution
  value would execute at eval time; the fail-closed guard rejects any
  non-numeric value before it reaches the gate. Found and re-verified in
  adversarial review before this release. The chunk-flush helper exec and the
  download-loop `brctl` exec also get `< /dev/null` so an inherited file-list
  stdin can never reach them.

### Tests
- Smoke Group I3 (escape matrix, sync-status semantics incl. helper-failure
  degradation, free-space gate both directions incl. a controlled-`df` boundary
  pinning the `bytes_need` term, injection-refusal with sentinel-absence, and
  blank-line deficit accounting) plus TUI-level integration through the real
  script in a sandbox. Resolver, gate, and accounting were mutation-verified.
  Gate: ~562 smoke assertions + 87 python tests.

## [0.3.0] - 2026-07-03

Adds `xdg-tui`, an optional interactive dashboard over the provision script,
and the machine-readable `--porcelain` contract that backs it. The core
toolkit remains bash-3.2-pure and fully usable without python.

### Added
- `xdg-tui`: an optional curses dashboard (`bin/xdg-tui` launcher +
  `bin/xdg_tui.py`, python 3 stdlib only) that browses every registry entry with
  live state and drives offload / hydrate / reclaim / iCloud interactively. A
  strict wrapper: every action is a normal `cloud-xdg-provision.sh` run
  (dry-run preview → explicit confirm → `--apply`); the script's guards remain
  the sole enforcement layer, applies get full terminal handover, interrupts
  surface as interrupts (rc 130), and iCloud evict keeps its typed-consent gate.
- `--porcelain` modifier for `--classify` / `--offload-status`: versioned
  (`porcelain=1`) pipe-delimited machine-readable output
  (`class|canonical|localName|state|remote|git`), format-frozen by golden smoke
  tests. Human output is byte-unchanged; misuse on any other lane is refused.
- ADR §5.2 amendment: python permitted **narrowly** for the optional TUI; the
  core toolkit stays bash-3.2-pure and `make lint`/`make test` python steps
  skip gracefully where python3 is absent.

### Tests
- Smoke Group P freezes the porcelain contract (goldens for every state enum,
  read-only checks, misuse refusal); Group Q1 pins the launcher/module/test
  pairing so gate steps can never silently skip.
- `tests/tui/`: 78 stdlib-unittest cases — P0 gates at 100% branch coverage
  (apply iff literally confirmed, consent-before-argv evict, no-op SIGINT
  handler never `SIG_IGN`) plus integration: offload→hydrate round-trip
  (byte-identical), SIGINT mid-apply (lock released, container intact,
  recovery-trap tripwire), read-back-failure relay.

## [0.2.2] - 2026-07-02

Adds a `--version` flag and closes out the tracked test-coverage backlog
(F2/F3/F4/F6 all resolved). No behavior changes to existing modes.

### Added
- `cloud-xdg-provision.sh --version`: print the version — read from the repo-root
  `VERSION` file resolved relative to the script (works from any CWD and via a
  symlink to the script), degrading to `(version unknown)` if `VERSION` is absent.
  An early-exit flag like `--help`; engages no mode or lock (F6, per ADR §7).

### Tests
- `tests/smoke.sh`: assert **every** `home-tree.sh` rclone-filter exclude line as
  an exact whole line (`grep -qxF`), plus deny→allow→catch-all ordering — a
  dropped deny line is a data-leak regression the suite now catches (F2).
- `tests/smoke.sh`: automate the `redirect_one()` edge-case matrix — empty real
  dir replaced by a cloud symlink, `downloads` create-only-by-default vs.
  `--redirect-downloads`, and a live foreign symlink (existing wrong target) left
  untouched (F3).
- `tests/smoke.sh`: `--version` prints the `VERSION`-file contents and exits 0,
  including when invoked through a symlink from a different CWD (F6).

### Fixed
- CHANGELOG: retire the stale F4 known-issue. `resolve_cloud_root()` no longer
  picks a Google Drive mount silently — it already refuses multiple mounts with a
  disambiguation message (Issue #4, shipped in 0.2.0) and is covered by smoke
  group #4. The known-issue entry described a bug that no longer exists.

## [0.2.1] - 2026-07-02

Documentation-only patch release. No code changes.

### Documentation
- `README.md`: document the `cloud-xdg-provision.sh` subcommand modes. Adds a
  "Subcommand modes" subsection covering `--classify`, `--offload-status`,
  `--offload`/`--hydrate`, `--migrate-projects`, the dotfiles lane
  (`--dotfiles-init`/`-track`/`-status`) + adopt (`--dotfiles-remote`), macOS
  iCloud true-offload (`--icloud-status`/`-download`/`-evict`), and `--reclaim`
  (with a dedicated block on its false-positive-safe deletion model) — noting the
  one-lane-per-invocation rule and dry-run-by-default posture (#35, #36).

## [0.2.0] - 2026-07-02

Adds a suite of on-demand data-management modes to `cloud-xdg-provision.sh`
(classification, code offload/hydrate, dotfiles, iCloud true-offload, and
regenerable-artifact reclaim), all dry-run by default and `--apply`-gated.

### Added
- **Home-dir classification** (`--classify`): report the class (xdg / code /
  local) of every known `~/` entry, driven by a unified dir registry in the
  shared lib. Read-only. Reclassifies `Projects` as a CODE area (slice 1).
- **Code offload-on-demand** (`--offload <dir>` / `--hydrate <dir>` /
  `--offload-status`): push a CODE dir to an rclone **remote** (the only lane
  that frees local space), gated on per-repo clean/pushed/no-stash guards and an
  **independent read-back verify** (`rclone check --download`) before any local
  drop; `--hydrate` restores it; a sentinel makes an interrupted hydrate
  self-detecting. `--aside` moves the local copy aside and re-verifies before
  `rm`. `--migrate-projects` un-symlinks a cloud-mounted `~/Projects` back to a
  real local dir (non-destructive).
- **Dotfiles bare-repo lane** (`--dotfiles-init` / `--dotfiles-track` /
  `--dotfiles-status`): a bare `~/.dotfiles` repo with `$HOME` as the work tree,
  a sourced alias file, and a guarded rc-source block. `--dotfiles-track` accepts
  **multiple paths in one fail-closed atomic commit** and refuses cloud-xdg-managed
  paths.
- **Dotfiles adopt** (`--dotfiles-remote <url>`): adopt an existing dotfiles repo
  on a fresh machine — clone `--bare`, move colliding files aside
  (`*.pre-dotfiles`), then check out (never `--force`); lexically rejects and
  realpath-confines tracked paths to `$HOME`.
- **iCloud true-offload** (macOS; `--icloud-status` / `--icloud-download` /
  `--icloud-evict`): report in-iCloud/dataless/uploaded state, materialize
  dataless files, or evict fully-uploaded files to dataless placeholders. Evict
  is heavily gated (compiled `bin/icloud-uploaded` upload-state helper via
  `make helper`, plus `--i-understand-data-loss-risk`).
- **macOS iCloud Drive auto-detect**: `cloud-xdg-provision.sh` falls back to the
  iCloud Drive root when no Google Drive mount is present.
- **`--reclaim [PATH]`**: the delete-side counterpart to `--offload`. Sweeps
  `PATH` (default: cwd) for known-regenerable build artifacts (Rust `target/`,
  `node_modules`, Gradle/Maven/CMake `build/`, `__pycache__` and Python tool
  caches, `*.egg-info`, framework caches) and deletes them to free disk;
  `--global` also sweeps a fixed user-cache allow-list (Homebrew, npm, pip, Xcode
  DerivedData, `~/.gradle/caches`). Because it deletes with no cloud copy as a
  net, admission is false-positive-safe: a candidate must be **anchored by a
  sibling toolchain manifest** and (for generic names `build`/`dist`/`out`)
  **git-ignored/untracked**; anything git-tracked is never touched; outside a git
  repo only tool-native-authoritative anchors or pure-bytecode names qualify. Git
  predicates are fail-closed (any error → the non-deleting answer), symlinked
  manifests never anchor, symlinks are never followed, candidates are confined
  under the resolved root, and every `rm` passes a degenerate-path guard.
  Tool-native clean (`cargo`/`mvn`/`gradle clean`) is preferred over `rm`. Dry-run
  by default; `--apply` gates deletion. See `docs/preparation/research-reclaim.md`
  and `docs/architecture/reclaim-diff.md`.
- `tests/smoke.sh`: reclaim coverage (R1–R4) — dry-run classification, apply
  deletes reclaimable while decoys survive, degenerate-root refusal, and
  symlinked-manifest refusal. All sandboxed (`HOME` + roots), never the real `$HOME`.
- `tests/smoke.sh`: apply-mode idempotency section — `cloud-xdg-provision.sh
  --apply` is exercised in a sandboxed `HOME` and re-run to assert idempotency
  (ADR §10 #3). Regression guard for the dangling-symlink abort fixed below.
- `CLAUDE.md`: working guide for editing the codebase (invariants, modes, testing).

### Changed
- Refactored `cloud-xdg-provision.sh` and `home-tree.sh` onto a shared
  `bin/lib/xdg-common.sh` library, deduplicating plumbing and platform-detection
  logic while keeping each script's `run()` deliberately per-script.

### Fixed
- `redirect_one()` (`cloud-xdg-provision.sh`): dangling-symlink detection now
  checks `[ -L ]` before `[ ! -e ]`. A dead symlink previously returned false for
  `-e` (target gone), was misclassified as "missing", and caused `ln -s` to fail
  on the still-present inode — aborting the entire `--apply` run under `set -e`.
- Offload repo-discovery now confined with `GIT_CEILING_DIRECTORIES` so a nested
  parent repo can't be mistaken for the container's own repo.
- macOS ACL handling + robustness/consistency hardening: correct `deny delete`
  ACL detection on special home folders, lock-error accuracy, backup checks, and
  rename safety.

## [0.1.0] - 2026-06-26

### Added
- Initial version-controlled repository for the `xdg-cloud` toolkit.
- `bin/cloud-xdg-provision.sh` — cloud-as-live-home strategy: provisions a
  canonical, cross-OS user-data ontology that lives in the cloud drive and
  redirects local user dirs (`~/Documents`, `~/Music`, …) into it via symlinks.
- `bin/home-tree.sh` — local-home + backup-mirror strategy: provisions a clean
  local XDG tree and a safe one-way (`--sync`) or two-way (`--bisync`) `rclone`
  backup mirror, with config/data/state/cache kept strictly local.
- `Makefile` with `lint`, `test`, `install`, and `version` targets.
- Committed `hooks/pre-commit` (shellcheck gate), activated via `make install`.
- `.shellcheckrc` (`shell=bash`, `enable=all`) and `.gitignore`.
- `tests/smoke.sh` — smoke checks running both scripts in sandboxed dry-run.
- `README.md` documenting the either/or strategy fork, per-platform
  prerequisites, the FHS/XDG/macOS mapping, hard rules, and known traps.
- `VERSION` file (`0.1.0`) as the single source of truth for the release string.
- MIT `LICENSE`.

[Unreleased]: https://github.com/youdontknowdemo/xdg-cloud/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/youdontknowdemo/xdg-cloud/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/youdontknowdemo/xdg-cloud/releases/tag/v0.1.0
