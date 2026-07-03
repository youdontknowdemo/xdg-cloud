# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Known issues / tracked for future work
- Filter correctness: rclone filter excludes not yet asserted in tests (F2).
- `redirect_one()` edge-case matrix not yet automated (F3).
- `resolve_cloud_root()` picks the first alphabetically if two Google Drive
  accounts are mounted; no disambiguation logic yet (F4).
- `--version` flag not yet implemented (deferred per ADR §7) (F6).

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
