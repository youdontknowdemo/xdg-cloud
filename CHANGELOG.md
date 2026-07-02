# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- `redirect_one()` (`cloud-xdg-provision.sh`): dangling-symlink detection now
  checks `[ -L ]` before `[ ! -e ]`. A dead symlink previously returned false
  for `-e` (target gone), was misclassified as "missing", and caused `ln -s` to
  fail on the still-present inode — aborting the entire `--apply` run under
  `set -e`.

### Added
- `--reclaim [PATH]` (`cloud-xdg-provision.sh`): the delete-side counterpart to
  `--offload`. Sweeps `PATH` (default: cwd) for known-regenerable build artifacts
  (Rust `target/`, `node_modules`, Gradle/Maven/CMake `build/`, `__pycache__` and
  Python tool caches, `*.egg-info`, framework caches) and deletes them to free
  disk; `--global` also sweeps a fixed user-cache allow-list (Homebrew, npm, pip,
  Xcode DerivedData, `~/.gradle/caches`). Because it deletes with no cloud copy as
  a net, admission is false-positive-safe: a candidate must be **anchored by a
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
- `CLAUDE.md`: working guide for editing the codebase (invariants, modes, testing).
- `tests/smoke.sh`: apply-mode idempotency section — `cloud-xdg-provision.sh
  --apply` is now exercised in a sandboxed `HOME` and re-run to assert
  idempotency (ADR §10 #3). Regression guard for the dangling-symlink abort
  fixed above.

### Known issues / tracked for future work
- Filter correctness: rclone filter excludes not yet asserted in tests (F2).
- `redirect_one()` edge-case matrix not yet automated (F3).
- `resolve_cloud_root()` picks the first alphabetically if two Google Drive
  accounts are mounted; no disambiguation logic yet (F4).
- `--version` flag not yet implemented (deferred per ADR §7) (F6).
- ADR §8.1 sample `.shellcheckrc` differs from the as-built file (F7).

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

[Unreleased]: https://github.com/miklevin/xdg-cloud/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/miklevin/xdg-cloud/releases/tag/v0.1.0
