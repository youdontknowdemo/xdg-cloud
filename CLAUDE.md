# CLAUDE.md

Guidance for Claude Code when working in this repository. For end-user usage, see `README.md`;
this file is about **how to change the code safely**.

## What this is

`xdg-cloud` is a cross-OS (macOS / Linux / Termux) **bash toolkit** for getting user data to the
cloud without breaking XDG/app correctness. Two production scripts solve the same problem with
**opposite strategies** — pick one per machine, never both:

- **`bin/cloud-xdg-provision.sh`** — cloud-as-live-home: local user dirs become symlinks *into*
  the cloud root (the real data lives in the cloud). This is the larger script and hosts all the
  subcommand modes below.
- **`bin/home-tree.sh`** — local-home + backup mirror: home stays local, `rclone` mirrors it to the
  cloud as a backup. Treated as **frozen** relative to provision-script work (don't refactor one to
  match the other; they intentionally diverge — see `docs/architecture/shared-lib-dedup.md`).

Shared helpers live in **`bin/lib/xdg-common.sh`** (`log`/`info`/`warn`/`die`, `field`,
`detect_platform`, the registry rows, `home_class`/`is_code_dir`/`is_machine_local`,
`rclone_remote_exists`). `run()` is deliberately **per-script** (provision quotes args with
`printf %q`; home-tree uses `%s`) — do not hoist it into the lib.

## Repo layout

```
bin/cloud-xdg-provision.sh   the cloud-as-live-home script + all subcommand modes
bin/home-tree.sh             the local-home + rclone-backup script (frozen)
bin/lib/xdg-common.sh        shared helpers (log/info/warn/die, registry, classifiers)
bin/icloud-uploaded[.swift]  compiled macOS helper: reports iCloud upload state (make helper)
tests/smoke.sh               sandboxed smoke suite (never touches real $HOME)
docs/preparation/            PACT PREPARE research (per feature)
docs/architecture/           PACT ARCHITECT diff-specs (one per slice/feature) + xdg-cloud-adr.md
docs/review/                 PACT peer-review synthesis
```

## `cloud-xdg-provision.sh` modes

Exactly **one lane per invocation** (`set_mode` refuses two). Empty mode = the default
provision/symlink lane (`main`). Subcommand modes are handled by `dispatch_mode` at the bottom of
the file:

| Mode | Handler | What it does |
|------|---------|--------------|
| *(default)* | `main` | Provision the cloud ontology + symlink local user dirs (`--relocate` migrates populated dirs). |
| `--classify` | `cmd_classify` | Report the class (xdg/code/local) of every known `~/` entry. Read-only. |
| `--offload-status` | `cmd_offload_status` | Report which CODE dirs are offloaded vs local. Read-only. |
| `--offload <dir>` | `cmd_offload` | Push a CODE dir to the rclone **remote**, read-back-verify, then free local. |
| `--hydrate <dir>` | `cmd_hydrate` | Restore a previously offloaded CODE dir from the remote. |
| `--migrate-projects` | `cmd_migrate_projects` | Un-symlink a cloud-mounted `~/Projects` back to a real local dir. |
| `--dotfiles-init/-track/-status` | `cmd_dotfiles_*` | Bare-repo dotfiles lane (work-tree = `$HOME`). |
| `--dotfiles-remote <url>` | `cmd_dotfiles_adopt` | Adopt an existing dotfiles repo (clone --bare, collision-aside, checkout). |
| `--icloud-status/-download/-evict <path>` | `cmd_icloud_*` | macOS iCloud true-offload (evict gated behind `--i-understand-data-loss-risk`). |
| **`--reclaim [PATH]`** | **`cmd_reclaim`** | **Delete regenerable build artifacts to free disk (see below).** |

### `--reclaim [PATH]` — regenerable build-artifact sweep

The **delete-side** counterpart to `--offload`. It purges known-regenerable build/cache dirs
(Rust `target/`, `node_modules`, Gradle/Maven/CMake `build/`, `__pycache__` + Python tool caches,
`*.egg-info`, framework caches) under `PATH` (default: cwd), plus an opt-in fixed allow-list of
global user caches (`--global`: Homebrew, npm, pip, Xcode DerivedData, `~/.gradle/caches`).

Unlike `--offload`, **there is no cloud copy** — deletion is the only outcome, so the entire design
rests on **false-positive-safe detection**. The governing rule (from `docs/preparation/research-reclaim.md`,
implemented per `docs/architecture/reclaim-diff.md`):

> A candidate is reclaimable only if **anchored by a sibling toolchain manifest** proving it is
> build output, **and** (for generic names `build`/`dist`/`out`) **git-ignored/untracked**. Anything
> **git-tracked** is never deleted. Generic names with no manifest → never. Outside a git repo →
> only tool-native-authoritative anchors (`target/`+`cargo`/`mvn` present) or pure-bytecode names
> (`__pycache__` etc.). When in doubt → exclude.

Implementation invariants (in `cmd_reclaim` + the `reclaim_*` helpers, ~L1934-2143):

- **Fail-closed git predicates**: `reclaim_in_repo`/`reclaim_is_tracked`/`reclaim_is_ignored`
  resolve *any* git error to the **non-deleting** answer. A corrupt/locked index can only ever
  protect a dir. (`reclaim_is_tracked` returns "not tracked" ONLY on `ls-files` exit 1.)
- **Symlinked manifests never anchor** (`reclaim_manifest` requires a regular, non-symlink file).
- **Traversal guards**: `find -type d` (no `-L`, no symlink follow); every candidate is
  `cd && pwd -P`-canonicalized and refused unless strictly under the resolved root; matched dirs
  stop descent (the `accepted[]` array); `node_modules` containing `.git` is skipped.
- **Guarded delete**: every `rm -rf` routes through `reclaim_rm`'s degenerate-path `case` refusal
  (`""|"/"|"$HOME"|"$RECLAIM_ROOT"|*..*`). Tool-native clean (`cargo`/`mvn`/`gradle clean`) is
  preferred; guarded `rm` is the fallback.
- **No `RECLAIM_ACTIVE` recovery trap** (deliberate): a half-finished sweep of regenerable dirs is
  harmless and idempotently re-runnable, so unlike offload/relocate/migrate it needs no recovery
  message. It still arms `begin_mutating_mode` for the lock + not-root guard.
- Dry-run default; `--apply` alone gates the delete (no extra consent flag — detection guarantees
  only regenerable artifacts are admitted).

## Invariants to preserve (all modes)

These are enforced across the script — keep them when editing:

1. **bash 3.2-safe.** macOS ships bash 3.2. No `[[ ]]`, associative arrays, `mapfile`, `<()`,
   `readlink -f`. Use `cd … && pwd -P` to canonicalize. `set -euo pipefail` is active — expand
   possibly-empty arrays as `${arr[@]+"${arr[@]}"}`.
2. **Dry-run by default; `--apply` gates every mutation.** A bare invocation prints a plan and
   changes nothing. Deletion/mv/rm/sync only when `DRY_RUN=0`.
3. **`run()` prints every command** (`%q`-quoted) and only executes under `--apply`.
4. **Single master `cleanup_handler` + flags — never a second `trap`.** bash 3.2 has no trap
   stacking. Mutating windows toggle their own `*_ACTIVE` flag; `cleanup_handler` reads them. The
   flag-toggling code must run in the **parent shell** (here-doc / tempfile redirect, never a
   `… | while` pipe — a subshell's flag writes never reach the handler).
5. **`begin_mutating_mode`** (`guard_not_root` + `install_cleanup_trap` + apply-only `acquire_lock`)
   arms every mutating mode. Read-only modes (`--classify`, `--*-status`, dry-runs) do not lock.
6. **Degenerate-path refusal before any `rm`/`mv`**: `case` guard on `""|"/"|"$HOME"|…`.
7. **No backticks inside quoted strings or here-docs** (team footgun — they execute at parse/source
   time). Build strings with `printf`; messages via `log`/`info`/`warn`.
8. **home-tree.sh is frozen** relative to provision-script features unless the task says otherwise.

## Testing & dev

```sh
make lint     # shellcheck bin/*.sh hooks/pre-commit tests/*.sh (honors .shellcheckrc)
make test     # tests/smoke.sh — sandboxed HOME + sandbox roots, never the real $HOME
make helper   # compile bin/icloud-uploaded from the .swift source (macOS; graceful no-swiftc skip)
make install  # chmod +x + wire hooks/pre-commit (shellcheck gate) into .git/hooks
```

- **Run scripts with `/bin/bash`** (3.2 on macOS).
- Smoke tests build isolated fixtures under `tests/sandbox/` and override `HOME` for any `--apply`
  path — a test must **never** touch the real `$HOME`. New mutating behavior needs sandboxed
  coverage before it ships.
- There is **no CI** configured on the repo; `make lint`/`make test` + the pre-commit hook are the
  gate. Run them before proposing a merge.

## Workflow conventions

- Feature work happens on a branch; merges to `main` are **squash** PRs (GitHub appends `(#N)` to
  the squashed title — visible in `git log`).
- Each substantial feature gets a PREPARE research doc (`docs/preparation/research-<topic>.md`) and
  an ARCHITECT diff-spec (`docs/architecture/<topic>-diff.md`) before/with the code. Follow the
  existing diff-spec structure (files-touched table, exact bash bodies, bash-3.2 footgun list,
  reasoning chain, resolved decisions).
