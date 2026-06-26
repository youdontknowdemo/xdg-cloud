# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/Pipulate/xdg-cloud/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Pipulate/xdg-cloud/releases/tag/v0.1.0
