# Research: `repo-park` / `repo-restore` — sourceable function file

> PACT Prepare-phase research for the repo-park feature (Task #30) — a **sourceable
> bash function file** shipping `repo-park` (reduce a git working clone to a
> remotes-only marker dir: delete working tree + `.git` objects, keep the dir +
> remotes so it rehydrates later) and `repo-restore` (fetch + checkout back).
> **Analysis only — no implementation.** Destructive, ships to run on arbitrary user
> repos, so the design must carry the full `reclaim_rm`-grade guard bar. All
> mechanics below were **empirically verified** on this machine's stock
> `/bin/bash` 3.2.57 and zsh 5.9 in a throwaway `mktemp` lab (never a real repo,
> never `$HOME`) — see §7.

## Executive Summary

The repo already contains the exact precedent for every open question. A
**sourceable, no-shebang, `# shellcheck shell=bash`, declarations-only** file exists
at `bin/lib/xdg-common.sh:1-9` and lints clean under `enable=all` via the
`bin/lib/*.sh` glob (`Makefile:20`). The smoke suite already **sources a file in a
`/bin/bash -c` subshell and calls its functions** (`tests/smoke.sh:1143`), already
fabricates hermetic git repos (`git_seed`, `tests/smoke.sh:2021-2025`), and already
places git-predicate fixtures **outside the repo work tree** via
`mktemp -d "${host_tmp}/…"` with EXIT-trap cleanup (`tests/smoke.sh:37-51,
3242-3247`). The dry-run/`--apply` and guarded-rm idioms port from `run()`
(`bin/cloud-xdg-provision.sh:214-225`) and `reclaim_rm`
(`bin/cloud-xdg-provision.sh:2598-2607`) with one **critical inversion**: a sourced
function must **never `exit`, never `trap`, never toggle `set -e`, never write a
global** — it runs inside the user's interactive shell, so `die()`
(`bin/lib/xdg-common.sh:23`) and `begin_mutating_mode`
(`bin/cloud-xdg-provision.sh:1231`) are *forbidden* dependencies, replaced by
`return 1` + locals.

For the git plumbing, the **keep-`.git/config`, surgical-delete, `git init -q`
re-scaffold** approach (option b) won the empirical bake-off: remotes —
**including multi-value fetch refspecs — survive byte-for-byte with zero parsing**,
and `git fetch` + `git checkout -B <branch> <remote>/<branch>` restores from the
resulting unborn-HEAD state and even re-establishes upstream tracking automatically
(verified round-trip, §4/§7). Capture-and-replay (option a) re-implements config
serialization for no benefit and breaks on multi-value keys.

One scope question needs an architect ruling before CODE: **zsh**. The dotfiles lane
treats zsh users as first-class (`~/.zshrc` is a resolved rc target,
`bin/cloud-xdg-provision.sh:1543`), and sourcing the prototype in zsh 5.9 works —
but zsh does **not** word-split unquoted variables (demonstrated: a
`for x in $list` loop runs 1 iteration in zsh vs 3 in bash, §7), so function bodies
must be written to the *intersection* of bash 3.2 and zsh, or the file must be
documented bash-only.

## Reasoning Chain

1. The feature is a **new artifact type** (shipped sourceable file) → find the
   closest in-repo precedent → `bin/lib/xdg-common.sh` is exactly that (sourced,
   never executed, linted, bash 3.2) → mirror its header contract rather than
   invent one.
2. It is **destructive on arbitrary user repos** → the deletion-side safety model
   is `--reclaim`'s (fail-closed predicates, degenerate-path refusal, dry-run
   default) → port the guard bar, not just the `rm` wrapper.
3. It runs **inside the user's interactive shell** → every script-lane mechanism
   that touches shell-global state (exit-on-error `die`, traps, locks, global
   `DRY_RUN`) must be replaced with function-local equivalents → self-contained
   file, no dependency on `xdg-common.sh`.
4. "Remotes-only marker that `git pull`/`repo-restore` rehydrates" → the marker
   must remain a **valid git repo** → keep `.git/config` + `HEAD`, delete
   objects/refs/index/logs + working tree, `git init -q` to re-scaffold → verified
   this round-trips, so no config capture/replay layer is needed.
5. Deleting objects destroys anything not on a remote → the refusal set is exactly
   "evidence of unpushed state": dirty tree, unpushed commits, stashes, detached
   HEAD, no remotes, linked worktrees, submodules — each has a cheap, verified git
   probe (§5).

---

## 1. Artifact placement + type (Q1)

### Prior art

| Precedent | Evidence |
|---|---|
| Sourceable file, no shebang, `# shellcheck shell=bash` first line | `bin/lib/xdg-common.sh:1` |
| "SOURCED, never executed … DECLARATIONS-ONLY … sourcing under `set -euo pipefail` can never abort" header contract | `bin/lib/xdg-common.sh:5-9` |
| Lint coverage: `shellcheck bin/*.sh bin/lib/*.sh bin/xdg-tui hooks/pre-commit tests/*.sh` | `Makefile:20` |
| `.shellcheckrc`: `shell=bash`, `enable=all`, repo-wide disables `SC2250,SC2292,SC2312,SC2310,SC2249` | `.shellcheckrc:5,8,29` |
| `make install` marks `bin/*.sh` executable | `Makefile:47` (`chmod +x bin/*.sh hooks/pre-commit`) |
| User-facing *sourced* content already exists, but **generated**, at `$XDG_CONFIG_HOME/xdg-cloud/aliases.sh` | `bin/cloud-xdg-provision.sh:95,1571,1580` |

### Options

- **A — `bin/xdg-repo-park.sh`** (recommended). Top-level `bin/`, user-facing, next
  to the two production scripts. Automatically covered by the `bin/*.sh` lint glob
  (`Makefile:20`) — no Makefile change. Downside: `make install`'s
  `chmod +x bin/*.sh` (`Makefile:47`) will mark it executable; mitigated by an
  exec-guard (below) that turns accidental execution into a self-explaining usage
  message.
- **B — `bin/lib/xdg-repo-park.sh`**. Also lint-covered, escapes the `chmod`. Rejected:
  `bin/lib/` is documented as *internal* shared plumbing for the two scripts
  (`bin/lib/xdg-common.sh:3`); telling users to source something out of `lib/`
  muddies that contract.
- **C — new `shell/` dir**. Rejected: not covered by the lint glob without a
  Makefile edit, no precedent, one more top-level concept.
- **Name note**: avoid `xdg-repo-aliases.sh` — "aliases.sh" already means the
  *generated* dotfiles alias file (`bin/cloud-xdg-provision.sh:95`); a shipped file
  with the same noun invites confusion.

### File header (verified linting clean, §7)

```bash
# shellcheck shell=bash
#
# xdg-repo-park.sh — repo-park / repo-restore shell functions.
# SOURCED from your shell rc, never executed:   . /path/to/bin/xdg-repo-park.sh
# Self-contained: does NOT source bin/lib/xdg-common.sh (its die() exits, which
# would kill your interactive shell). bash 3.2-safe; also sources under zsh.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  printf 'xdg-repo-park.sh defines shell functions - source it, do not run it:\n  . %s\n' "$0" >&2
  exit 64
fi
```

Empirically verified (§7): under bash 3.2.57 the guard exits 64 with the message on
direct execution and is a 0-returning no-op when sourced (an `if` whose condition is
false returns 0, so the declarations-only source-safety rule of
`bin/lib/xdg-common.sh:5-9` still holds); under zsh 5.9 `${BASH_SOURCE[0]:-}` is
empty, the guard passes, and sourcing works. **No shebang** — the guard makes one
unnecessary and its absence is the repo's "source me" signal (`bin/lib/xdg-common.sh:5`).
The alternative `(return 0 2>/dev/null)` sourced-detection idiom also works on
bash 3.2 (verified) but the `BASH_SOURCE` form is used because it verifiably behaves
in both shells.

Function names: `repo-park` and `repo-restore` (hyphenated) are **valid function
names in bash 3.2.57 and zsh 5.9, and shellcheck `enable=all` accepts them**
(verified, §7). Helpers must be namespaced `_repo_park_*` so sourcing does not
pollute the interactive namespace.

## 2. Smoke-testing a sourced function (Q2)

**Composes with the existing harness — a new group at the end of `tests/smoke.sh`;
no sibling runner needed.** The harness already has every piece:

- **Source-in-subshell call pattern** — exactly how group L3 tests the lib
  (`tests/smoke.sh:1143`):
  ```bash
  actual="$(/bin/bash -c '. "$1"; xdg_offload_set' _ "${lib}")"
  ```
  For repo-park, with arguments forwarded and CAPTURE-then-INSPECT
  (`tests/smoke.sh:23-25` — never pipe into `grep -q`, SIGPIPE/141 hazard):
  ```bash
  PARKLIB="${repo}/bin/xdg-repo-park.sh"
  out="$(/bin/bash -c '. "$1"; shift; repo-park "$@"' _ "${PARKLIB}" "${fixture}" 2>&1)"
  ```
  A `return 1` from the function becomes `bash -c`'s exit code, so refusal tests
  use the R3 `set +e; …; rc=$?; set -e` + `assert_nonzero` pattern
  (`tests/smoke.sh:3310-3317`, helper at `:71-78`).
- **Fixture root OUTSIDE the repo work tree** — mandatory here for the same reason
  as the reclaim group (`tests/smoke.sh:3242-3247`): the xdg-cloud checkout is
  itself a git repo, so a "plain non-repo dir" fixture under `tests/sandbox/`
  would resolve `git rev-parse --show-toplevel` to the xdg-cloud repo and never
  exercise the not-a-repo refusal. Reuse the `host_tmp` capture
  (`tests/smoke.sh:37-40`) + a second `park_root=""` cleanup variable wired into
  the EXIT trap exactly like `rec_root` (`tests/smoke.sh:42-51`).
- **Hermetic git identity** — already exported before the reclaim group
  (`tests/smoke.sh:3240-3241`); place the park group after it (or re-export).
- **Local bare repo as the "remote"** — `git_seed` precedent
  (`tests/smoke.sh:2021-2025`); park needs the two-step form:
  ```bash
  git init -q --bare "${park_root}/origin.git"
  git clone -q "${park_root}/origin.git" "${park_root}/work"
  # commit + push, then park/restore against it — verified round-trip in §7
  ```
- **Assertion set** (mirrors reclaim R1/R2/R3, `tests/smoke.sh:3272-3317`):
  - P1: bare `repo-park <dir>` prints a plan, exits 0, **deletes nothing** (loop
    `[ -e … ]` over every fixture path, R1 style `:3285-3288`).
  - P2: `--apply` parks — working tree gone, `.git/config` remotes intact
    (`git -C … remote -v`), dir much smaller.
  - P3: `repo-restore` round-trips content (file bytes + `git log` reachable +
    `git status --porcelain` empty).
  - P4: each refusal (non-repo dir, subdir, dirty, unpushed, no-remote, bare,
    linked worktree) exits non-zero *and names the cause* (R3/C9 style).
  - Optional zsh group gated on `command -v zsh` (TEST-phase decision).

## 3. Dry-run/`--apply` idiom for a function (Q3)

The script idiom is global `DRY_RUN=1` (`bin/cloud-xdg-provision.sh:71`) + `run()`
(`:214-225`, `%q`-quotes every arg, executes only under `--apply`). A sourced
function **must not** use a global — it would leak into / collide with the user's
interactive shell. Recommended form (bash-3.2- and zsh-safe):

```bash
repo-park() {
  local apply=0 force=0 target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply|-y) apply=1 ;;
      -f|--force) force=1 ;;
      -*) printf 'repo-park: unknown option %s\n' "$1" >&2; return 2 ;;
      *)  target="$1" ;;
    esac
    shift
  done
  ...
}
```

- **All state in locals.** No `DRY_RUN`, no exported vars, no
  `begin_mutating_mode` (`bin/cloud-xdg-provision.sh:1231`) — traps and locks
  belong to the script lane; installing a trap from a sourced function would
  clobber the user's own traps (the single-trap discipline of CLAUDE.md invariant
  4 applied to a shell we do not own means: touch **nothing** shell-global).
- **Gate inline, keep the `%q` ledger discipline.** The function has only two
  mutation phases (working-tree delete, `.git` internals delete), so inline
  `if [ "$apply" -eq 1 ]` at each point, always printing the `printf ' %q'`-quoted
  command first (mirrors `run()`'s copy-paste-safe contract,
  `bin/cloud-xdg-provision.sh:215-218`), is clearer than replicating `run()`.
  (bash's dynamic scoping *would* let a `_repo_park_run` helper read the caller's
  `local apply`, but that is implicit action-at-a-distance; if a helper is used,
  pass the flag as `$1`.)
- **Never `exit`, never `die()`.** `die()` (`bin/lib/xdg-common.sh:23`) calls
  `exit 1` — sourced, that terminates the user's terminal session. Every refusal
  is `printf 'repo-park: …\n' >&2; return 1`. This is also why the file must be
  **self-contained** and not source `xdg-common.sh`.
- **No reliance on `set -e`** — the user's shell won't have it; every command that
  matters gets an explicit `|| { …; return 1; }`.

## 4. Reduce-to-remotes git plumbing (Q4)

### Decision: option (b) — keep `.git/config`, surgical delete, `git init -q` re-scaffold

**Verified round-trip** (bash 3.2, throwaway lab, §7):

```bash
# PARK (inside canonicalized toplevel $top):
find "$top" -mindepth 1 -maxdepth 1 -not -name .git ...   # working tree entries -> guarded rm
rm -rf .git/objects .git/refs .git/logs .git/index .git/packed-refs \
       .git/FETCH_HEAD .git/ORIG_HEAD
git init -q          # re-creates empty objects/ + refs/ scaffolding; config UNTOUCHED

# RESTORE (from the resulting valid, empty, unborn-HEAD repo):
git fetch -q "$remote"
git checkout -q -B "$branch" "$remote/$branch"
```

Empirical results: remotes survive verbatim (`git remote -v` intact), a **multi-value
`remote.origin.fetch`** (second refspec added via `git config --add`) survives
byte-for-byte, the restore succeeds **from unborn HEAD**, restores files (including
a `dir with spaces/` path), leaves `git status --porcelain` empty, and
`checkout -B` **automatically re-establishes upstream tracking**
(`git rev-parse --abbrev-ref '@{upstream}'` → `origin/master`).

Why not option (a) (capture `git config --get-regexp '^remote\.'`, `rm -rf` all,
`git init`, replay): replay must reconstruct multi-value keys with `--add`, handle
values containing spaces/globs (refspecs routinely contain `*` and `+`), and
loses every non-remote config the user set (e.g. `credential.*`, `core.*`,
partial-clone `remote.<r>.promisor/partialclonefilter`). Option (b) preserves all
of it for free — strictly more robust, less code.

### Delete set and keep set

| Path | Action | Why |
|---|---|---|
| every `$top/<entry>` except `.git` | delete | the working tree |
| `.git/objects`, `.git/packed-refs`, `.git/refs`, `.git/logs`, `.git/index`, `.git/FETCH_HEAD`, `.git/ORIG_HEAD` | delete | the space; refs are meaningless once objects go |
| `.git/config` | **keep** | remotes + everything else, verbatim |
| `.git/HEAD` | **keep** | leaves the repo valid; points at the (now unborn) branch |
| `.git/hooks`, `.git/info` | **keep** | custom hooks / `info/exclude` are **user data not recoverable from the remote** (~50 KB of samples is the cost; lab: 128K → 84K residual `.git`) |
| `.git/modules`, `.git/worktrees` | never reached | parking refuses submodules / linked worktrees (§5) |

### Park-time bookkeeping in the kept config (recommended)

```bash
git config xdgcloud.parked 1
git config xdgcloud.parkedBranch "$(git rev-parse --abbrev-ref HEAD)"   # BEFORE deleting refs
git config xdgcloud.parkedAt "$(date +%Y-%m-%dT%H:%M:%S)"
```

This makes restore branch detection **offline and exact** (restores the branch the
user was on, not the remote's default), and gives `repo-restore` a positive
"this dir was parked by us" predicate. Fallback when absent (e.g. user wants the
remote default): `git ls-remote --symref "$remote" HEAD | sed -n
's|^ref: refs/heads/\(.*\)	HEAD$|\1|p'` (verified; note the literal TAB in the
sed pattern — build it with `printf '\t'` to keep the source backtick/`$'…'`-free
and 3.2-safe). `repo-restore` should clear the `xdgcloud.parked*` keys on success.

Note on `git pull` in the task statement: a parked dir is `git fetch`-able
immediately, but bare `git pull` on an unborn HEAD is less deterministic than
`fetch` + `checkout -B`; `repo-restore` should own the incantation above rather
than documenting `git pull`.

## 5. Guard bar (Q5)

### Path guards — the `reclaim_rm` mirror

Model: `reclaim_rm` (`bin/cloud-xdg-provision.sh:2598-2607`) + the root refusal in
`cmd_reclaim` (`:2671-2673`) + fail-closed git predicates (`:2558-2570`).

1. **Canonicalize first**: `top="$(cd "$target" 2>/dev/null && pwd -P)" || refuse`
   (repo invariant: no `readlink -f`; also collapses macOS `/tmp` →
   `/private/tmp`, which the lab showed *does* differ — string-compare only
   canonical forms, including a canonicalized `$HOME`).
2. **Degenerate `case` refusal** before any `rm`, on the canonical path *and* on
   every child path fed to `rm`:
   `""|"/"|"$HOME"|"$home_real"|*..*` → refuse (mirror `:2600-2603`; `$home_real`
   is `pwd -P` of `$HOME` — parking `$HOME` is a live scenario because the
   dotfiles lane makes `$HOME` a git work-tree, `bin/cloud-xdg-provision.sh:95`).
3. **Toplevel identity**: `git -C "$top" rev-parse --show-toplevel` must succeed
   AND its `pwd -P` canonical form must equal `$top`. One check kills three
   attacks: plain non-repo dirs (rev-parse fails → refuse — fail-closed like
   `reclaim_in_repo`, `:2559`), running from/on a **subdir** (toplevel differs →
   would otherwise nuke the parent repo), and dirs nested inside an outer repo.
4. **Not bare**: `git -C "$top" rev-parse --is-bare-repository` = `false`
   (verified probe) — a bare repo *is* its objects; parking it is pure deletion.
5. **Not a linked worktree**: refuse if `[ -f "$top/.git" ]` (gitdir-pointer
   file — verified that's exactly what a linked worktree has).
6. **No linked worktrees attached**: refuse if
   `git -C "$top" worktree list --porcelain | grep -c '^worktree '` > 1
   (verified = 2 with one linked worktree). Deleting objects strands every
   sibling. (This repo's own PACT flow uses worktrees — this refusal will fire in
   real life.)
7. **No submodules**: refuse if `[ -e "$top/.gitmodules" ]` (v1 scope cut:
   submodule git dirs live in `.git/modules`; restore would need
   `submodule update --init` plumbing — defer, refuse loudly).
8. **Every `rm` routed through one `_repo_park_rm`** carrying guard 2 and a
   "strictly under `$top`" prefix check (the `accepted[]`/strictly-under
   discipline of `cmd_reclaim:2691-2697`), deleting only the `find "$top"
   -mindepth 1 -maxdepth 1 -not -name .git` children — never the root, never
   with `-L`/symlink-follow.

### State refusals (what makes the repo unsafe to destroy)

| Refusal | Probe (verified §7) | `-f` overridable? |
|---|---|---|
| **No remotes** — nothing to rehydrate from | `git remote` output empty | **No** (park would be plain deletion) |
| **Uncommitted** (dirty tree, incl. staged + **untracked** — parking deletes them irrecoverably) | `git status --porcelain` non-empty (probe: 1 line after edit) | Yes, `-f` |
| **Unpushed commits** (reachable from local branches, on no remote) | `git rev-list --branches --not --remotes --count` ≠ 0 (probe: 0 clean → 1 after a local commit). Fail-closed bonus: with no remote-tracking refs at all, *every* commit counts → refuses | Yes, `-f` |
| **Stashes** (stash commits are objects → destroyed) | `git stash list` non-empty | Yes, `-f` (architect may prefer hard) |
| **Detached HEAD** (`parkedBranch` would record literal `HEAD`) | `git rev-parse --abbrev-ref HEAD` = `HEAD` | Yes, `-f` (restore then falls back to remote default branch) |

"Unpushed" vs "uncommitted" is exactly the two probes above: porcelain sees the
*working tree/index*; `rev-list --branches --not --remotes` sees *commit-graph*
divergence. Known blind spots of the rev-list form (document, don't solve in v1):
local **tags** not on any remote (`--tags` could be added to the rev-list) and
commits reachable only from the reflog — both are destroyed silently; local branch
*names* pointing at pushed commits are also lost (only `parkedBranch` is recorded)
— acceptable by design, the commits remain fetchable.

`repo-restore` refusals: dir fails the same canonicalization/toplevel checks; not
marked `xdgcloud.parked` (refuse to "restore" an arbitrary repo — it would
`checkout -B`-reset it); no remotes; working tree already non-empty.

## 6. Recommendations (resolved decisions for ARCHITECT)

1. **`bin/xdg-repo-park.sh`**: no shebang, `# shellcheck shell=bash` line 1,
   xdg-common-style SOURCED-never-executed header, `BASH_SOURCE` exec-guard
   (exit 64 + usage on execution). Lint-covered by `Makefile:20` unchanged.
2. **Self-contained** — does not source `bin/lib/xdg-common.sh` (its `die()`
   exits). Functions `repo-park`/`repo-restore`; helpers `_repo_park_*`; all
   state `local`; refusals `return 1/2` + stderr; no traps/locks/`set` changes.
3. **Dry-run default, `--apply`/`-y` to act, `-f` for dirty/unpushed/stash/detached
   overrides** — parsed per-call into locals; `%q`-quoted ledger lines printed for
   every would-be mutation (run()'s contract, function-local form).
4. **Park = keep config+HEAD+hooks+info; delete worktree entries +
   objects/refs/logs/index/packed-refs/FETCH_HEAD/ORIG_HEAD; `git init -q`;
   record `xdgcloud.parked{,Branch,At}`.** Restore = `git fetch` +
   `git checkout -B "$branch" "$remote/$branch"`, branch from `parkedBranch`,
   fallback `ls-remote --symref`.
5. **Smoke**: new group at the end of `tests/smoke.sh`; fixture root
   `mktemp -d "${host_tmp}/xdg-park-smoke.XXXXXX"` outside the work tree with a
   `rec_root`-style cleanup var; bare-repo "remote" + clone; invoke via
   `/bin/bash -c '. "$1"; shift; repo-park "$@"' _ "$PARKLIB" …` with
   CAPTURE-then-INSPECT; assert P1 dry-run-deletes-nothing, P2 apply-parks,
   P3 restore-round-trips, P4 refusals non-zero.

## 7. Empirical verification log

Environment: macOS, `/bin/bash` = GNU bash 3.2.57(1)-release, zsh 5.9,
shellcheck per `.shellcheckrc` (`enable=all` minus `SC2250,SC2292,SC2312,SC2310,SC2249`).
Lab: `mktemp -d /tmp/repopark-lab.XXXXXX`, deleted afterwards; no real repo or
`$HOME` touched.

| # | Claim | Result |
|---|---|---|
| 1 | Hyphenated `repo-park()` defined in a sourced file, called — bash 3.2 | works (`park apply=1`) |
| 2 | Same file under zsh 5.9 (`. file; repo-park --apply`) | works |
| 3 | shellcheck `enable=all` (+repo disables) on no-shebang, `# shellcheck shell=bash`, functions-only file with hyphenated names | clean |
| 4 | `[ "${BASH_SOURCE[0]:-}" = "$0" ]` guard: executed → message + exit 64; sourced (bash + zsh) → no-op, functions defined | verified both |
| 5 | `(return 0 2>/dev/null)` sourced-detection under bash 3.2 | works (kept as noted alternative) |
| 6 | Park (delete worktree + objects/refs/index/logs/packed-refs, keep config/HEAD, `git init -q`): `git remote -v` intact; `.git` 128K → 84K | verified |
| 7 | Multi-value `remote.origin.fetch` (2 refspecs) survives the kept config | verified |
| 8 | Restore from unborn HEAD: `git fetch` + `git checkout -q -B master origin/master` → files back (incl. `dir with spaces/`), clean porcelain, log reachable | verified |
| 9 | `checkout -B` sets upstream: `@{upstream}` → `origin/master` | verified |
| 10 | Default-branch detect: `git ls-remote --symref origin HEAD` + sed | `master` |
| 11 | `git rev-list --branches --not --remotes --count`: 0 when pushed, 1 after local-only commit | verified |
| 12 | `git status --porcelain` line-count as dirty probe | verified |
| 13 | `--show-toplevel` from a subdir returns the repo root; output is `/private/tmp/...` (macOS symlink) → canonical-form comparison required | verified |
| 14 | Bare repo: `rev-parse --is-bare-repository` → `true` | verified |
| 15 | Linked worktree: `.git` is a **file** (`gitdir: …/worktrees/linked`); `worktree list --porcelain | grep -c '^worktree '` → 2 | verified |
| 16 | Fresh `git init` repo: `git remote` output empty | verified |
| 17 | zsh word-splitting divergence: `for x in $list` → 1 iteration (zsh) vs 3 (bash) | verified — bodies must not rely on word splitting if zsh is in scope |

## 8. Risk assessment

| Risk | P | Impact | Mitigation |
|---|---|---|---|
| False-positive park (deletes a repo with unrecoverable state) | Low | Critical | §5 guard bar; fail-closed probes; dry-run default; P4 smoke refusal tests |
| Sourced function kills/pollutes the user's shell (`exit`, globals, traps) | Med if ported naively | High | §3 inversion rules; self-contained file; smoke asserts refusals return (not exit) |
| zsh silently misbehaves (word splitting) | Med | Med | architect scope ruling; write to bash∩zsh subset; optional zsh smoke group |
| Reflog/tag/stash-only objects lost despite probes | Low | Med | stash+`-f` refusals; documented blind spots (tags, reflog) |
| `git init -q` re-scaffold differs on exotic repos (sha256 `extensions.objectformat`, promisor/partial clones) | Low | Med | config is kept so extensions persist; flag for TEST with a partial-clone fixture if desired |

## 9. Open questions (for ARCHITECT)

1. **zsh in scope?** Dotfiles lane says zsh users are first-class
   (`bin/cloud-xdg-provision.sh:1543`). If yes: bash∩zsh coding rules + a
   zsh-gated smoke group. If no: document "bash only" in the header.
2. **Stash refusal**: hard refuse, or `-f`-overridable (recommended `-f`)?
3. **Tag coverage** in the unpushed probe: add `--tags` to the rev-list (stricter,
   may annoy) or document as a blind spot (recommended v1)?
4. **`--apply` vs `-y` vs both**: mission names `--apply`/`-y`; recommend both as
   synonyms (`--apply` matches the repo idiom; `-y` is the interactive-muscle-memory
   spelling).
5. Should the provision script later gain a `--repo-park` mode delegating to the
   same logic (one engine, two entry points), or stay function-file-only? Out of
   scope for this slice; noted because `dispatch_mode`
   (`bin/cloud-xdg-provision.sh:2781-2799`) would absorb it cheaply.

## 10. References

- `bin/lib/xdg-common.sh:1-23` — sourceable-file precedent; `die()` exit hazard
- `bin/cloud-xdg-provision.sh:71,214-225` — `DRY_RUN` + `run()` ledger idiom
- `bin/cloud-xdg-provision.sh:2556-2607` — fail-closed git predicates + `reclaim_rm`
- `bin/cloud-xdg-provision.sh:2665-2779` — `cmd_reclaim` (root refusal, stop-descend, plan/apply split)
- `bin/cloud-xdg-provision.sh:95,1535-1577` — dotfiles aliases.sh + zsh rc targeting
- `Makefile:19-30,45-60` — lint glob, install chmod
- `.shellcheckrc:1-29` — shell=bash, enable=all, repo disables
- `tests/smoke.sh:16-53` — sandbox/CAPTURE-then-INSPECT/EXIT-trap harness contract
- `tests/smoke.sh:1123-1166` — L3 source-the-lib-in-subshell pattern
- `tests/smoke.sh:2021-2025` — `git_seed` fixture helper
- `tests/smoke.sh:3235-3330` — reclaim smoke groups (outside-tree fixture, hermetic git identity, R1-R4 assertion patterns)
- git docs: `git-init(1)` ("running git init in an existing repository is safe"), `git-ls-remote(1)` `--symref`, `git-rev-list(1)` set operations
