# Implementation Plan: TUI iCloud Sync (`icloud-sync-status` + usable bulk download)

> Generated from targeted PREPARE research on 2026-07-04
> Status: IN_PROGRESS
> Research: `docs/preparation/research-tui-icloud-sync.md` (uncommitted alongside this plan)

## Summary

Make the TUI's iCloud lane actually usable in bulk. Research overturned the framing: the
existing `--icloud-status/-download/-evict` commands **already recurse** (`find -type f`),
so the PR is not "add bulk" — it is (1) fix the path-resolution bug that makes every TUI
iCloud action fail on a provisioned machine, (2) add a read-only **`--icloud-sync-status`**
summary lane, and (3) give `--icloud-download` a dataless-only filter with a byte +
free-space preview gate. TUI side is thin wiring (ACTIONS row + `ops_for_entry`).

**User decisions (2026-07-04):**
- Scope = iCloud **Drive file sync** (not git mirrors, not rclone mirrors).
- **Bulk evict deferred** to a follow-up PR: skip-and-report evict changes the lane's
  fail-closed semantics (all-or-nothing → proven-subset) and gets its own diff-spec +
  adversarial review. Noted counter-pressure: the verified `.DS_Store` wedge means directory
  evict stays unusable until that follow-up lands.
- Rejected permanently: any `icloud-sync-up` action — macOS offers no force-upload
  primitive; upload is observable (helper) or waitable (`brctl monitor --wait-uploaded`,
  verified present on 15.7.8), never triggerable.

## What ships

| # | Piece | Where | Notes |
|---|-------|-------|-------|
| 1 | **Symlink-resolution fix** in `icloud_resolve_under_root` (~L1867-1874) | provision script | Today a lexical prefix match: symlinked entries (every provisioned machine) die `path is not under iCloud Drive` (verified, rc 1). Fix = **resolve-then-confine** (`cd … && pwd -P` on the target, then prefix-check against the resolved CloudDocs root). Ordering is safety-critical — never confine the unresolved string. |
| 2 | **`--icloud-sync-status <path>`** (new read-only lane) | provision script | Recursive summary: N dataless / M not-uploaded / K in-sync, bytes-to-download, bytes-evictable, plus a `brctl status` caught-up health line (surfaces the one-stuck-item-wedges-everything condition). Batched helper invocation (one spawn over a file list, ARG_MAX-chunked — measured ~3.8 ms/file batched vs ~20 ms/spawn). |
| 3 | **`--icloud-download` enhancement** (in place) | provision script | Dataless-only filter; dry-run preview reports file count + total bytes (`stat -f %z` sum — dataless files keep full logical size, verified) and **refuses when free space is insufficient** (ENOSPC jams fileproviderd — prior incident; safety gate, not cosmetics). |
| 4 | **TUI wiring** | `bin/xdg_tui.py` | One ACTIONS row (`icloud-sync-status`, read-only capture pane) + download stays handover; `ops_for_entry` gains the sync-status op on code/xdg rows. No porcelain change (verbatim panes ruled fine last cycle). |
| 5 | **Tests** | `tests/smoke.sh`, `tests/tui/` | Symlink-escape fixtures for the resolve-then-confine guard (HIGH-priority focus); brctl shim + stub helper + sandbox `ICLOUD_ROOT`; TUI ACTIONS-row unit coverage. |

## Key design constraints (carried from research)

- **Wrap-don't-bypass**: all logic (resolution, summary math, batching, free-space gate,
  health probe) lives in provision-script lanes; the TUI adds menu entries and panes only.
- Three distinct flags, not `--icloud-sync --status` (a modifier-on-mode conflicts with
  `set_mode`'s one-lane rule; distinct flags is the established pattern).
- Smoke-testability likely requires `ICLOUD_ROOT` (L111, currently hardcoded) to become
  env-overridable like `ICLOUD_HELPER` — architect must ratify (MEDIUM: it participates in
  a confinement check; override must not weaken production behavior).
- bash 3.2 + shellcheck enable=all throughout; evict lane untouched this PR (consent gate
  and all-or-nothing semantics unchanged).

## Risks

| Risk | L | I | Mitigation |
|------|---|---|------------|
| Resolve-then-confine ordering wrong → confinement weakened | Low | Critical | Exact body in diff-spec; symlink-escape sandbox fixtures; adversarial eyes in review |
| `ICLOUD_ROOT` override weakens production confinement | Med | High | Architect ruling; override documented test-only; guard still resolves before compare |
| Free-space gate math wrong → ENOSPC mid-download | Low | High | Gate uses conservative margin; refusal is verbatim-relayed by TUI |
| brctl/helper behavior drift across macOS versions | Med | Low | Health line is advisory; knowledge-based claims flagged in research §2, none load-bearing for this scope |

## Phase Requirements

| Phase | Required? | Rationale |
|-------|-----------|-----------|
| PREPARE | No — `plan_section_complete` | This research doc resolves it; remaining unknowns are architect ratifications, not research |
| ARCHITECT | Yes | Diff-spec is the repo hard gate; touches a shared confinement guard (risk 3-adjacent); exact bodies for lane + gate + batching |
| CODE | Yes | devops-coder (bash lanes + fix) ∥ backend-coder (TUI wiring) — same S2 partition as PR #43 |
| TEST | Yes | Symlink-escape fixtures, brctl-shim integration, free-space-gate refusal |

Variety estimate: **8 (Medium)** — novelty 2, scope 2, uncertainty 2, risk 2 → standard
`/PACT:orchestrate` (no plan-mode ceremony needed; this doc serves as the approved plan).

## Deferred / follow-up backlog

- **Bulk skip-and-report evict** (own diff-spec + adversarial review; unlocks usable
  directory evict past the `.DS_Store` wedge).
- TUI hardening slice from PR #43 review (`docs/review/tui-offload-manager-review.md`).
- P2 Termux manual pass.

## Next Steps

```
/PACT:orchestrate Implement the TUI iCloud sync PR per docs/plans/tui-icloud-sync-plan.md
```
