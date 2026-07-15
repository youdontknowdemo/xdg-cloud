# `repo-park` / `repo-restore` Architecture Spec (sourceable function file)

> ARCHITECT diff-spec for the repo-park feature. Inputs reconciled: the PREPARE research
> (`docs/preparation/research-repo-park.md`, all mechanics empirically verified per its §7)
> and the user's production-tested `~/.bash_aliases` implementation. Where they diverge,
> §4 records exactly what changed and why — every divergence is either a **locked user
> decision** (dry-run default), a **verified safety hole** in the tested version (bare-repo
> guard, `${1:?}` shell-kill), or the research's **empirically stronger plumbing** (option b).
> Additional probes beyond research §7 were verified in a fresh throwaway lab on this
> machine (bash 3.2.57 + zsh 5.9) — marked **[lab-verified]** below.

## 0. What this ships

Two shell functions in a **sourceable, self-contained** file:

- **`repo-park [--apply|-y] [-f|--force] <dir>`** — reduce a pushed git clone to a
  remotes-only marker: delete the working tree + `.git` objects/refs, keep `.git/config`
  (remotes verbatim) + `HEAD` + `hooks/` + `info/`, re-scaffold with `git init -q`.
  **Dry-run by default** — a bare invocation prints the exact `%q`-quoted deletion plan and
  touches nothing; `--apply`/`-y` acts. `-f` is **orthogonal**: it overrides the
  *state* refusals (dirty / unpushed / stash / detached) in both modes, never the dry-run gate.
- **`repo-restore <dir> [branch]`** — fetch + `checkout -f -B` back to a live clone.
  Acts immediately (constructive; the dry-run lock applies to park only). Branch detection
  preserves the user's tested chain, with one new *first*-preference source
  (`xdgcloud.parkedBranch`, recorded at park time — research §4 bookkeeping).

Destructive on arbitrary user repos → carries the full `reclaim_rm`-grade guard bar
(`bin/cloud-xdg-provision.sh:2598-2607`, `:2671-2673`) adapted to the one **critical
inversion** for sourced code (research §3): never `exit`, never `trap`, never `set`
toggles, never a global — refusals are `printf … >&2; return 1`.

## 1. Files touched

| File | Change |
|---|---|
| `bin/xdg-repo-park.sh` | **NEW** — the sourceable function file. Full body in §2. No shebang; `# shellcheck shell=bash` line 1; exec-guard. |
| `tests/smoke.sh` | `park_root=""` cleanup var wired into the EXIT trap (like `rec_root`, `:44,:51`); new P1–P5 groups appended before the final `echo "smoke: PASS"`. §5. |
| `README.md` | New top-level section between `## xdg-tui` (ends ~L165) and `## home-tree.sh` (~L166). §6. |
| `Makefile` | **NO change.** `lint`'s `shellcheck bin/*.sh …` glob (`Makefile:20`) covers the new file. `make install`'s `chmod +x bin/*.sh` (`Makefile:47`) will mark it executable — harmless: the exec-guard turns accidental execution into a usage message + exit 64 (research §1). |
| `bin/cloud-xdg-provision.sh`, `bin/home-tree.sh`, `bin/lib/xdg-common.sh` | **Untouched.** The file is self-contained (research §3: `die()` at `bin/lib/xdg-common.sh:23` calls `exit 1` — sourced, that kills the user's terminal). |

## 2. `bin/xdg-repo-park.sh` — exact body

> **These exact bodies were assembled into a lab file and verified** (macOS bash 3.2.57 +
> zsh 5.9, throwaway `mktemp` fixture, never a real repo): shellcheck clean under the repo
> settings (`--enable=all` minus the `.shellcheckrc` disables); exec-guard rc=64; dry-run
> deletes nothing (incl. `-f` alone); `--apply` parks with markers set and a **multi-value
> `remote.origin.fetch` surviving byte-for-byte**; restore round-trips content (incl. a
> `dir with spaces/`), clears markers, re-establishes upstream; all 12 refusals fire with
> the exact message fragments in §5's P4 table; under zsh both lanes work and refusals
> `return` (sourcing shell survives). Coders may transcribe verbatim. One wording
> constraint is load-bearing: messages avoid a literal `$HOME` (SC2016) and backticks
> (CLAUDE.md invariant 7).

### 2.1 Header + exec-guard (research §1, verified §7 #3-4)

```bash
# shellcheck shell=bash
#
# xdg-repo-park.sh — repo-park / repo-restore shell functions.
# SOURCED from your shell rc, never executed:   . /path/to/bin/xdg-repo-park.sh
#
# repo-park [--apply|-y] [-f] <dir>  reduce a pushed clone to a remotes-only marker
#                                    (dry-run by default; --apply deletes)
# repo-restore <dir> [branch]        fetch + checkout the clone back
#
# Self-contained: does NOT source bin/lib/xdg-common.sh (its die() exits, which
# would kill your interactive shell). bash 3.2-safe; also sources under zsh.
# Helpers are namespaced _repo_park_*; nothing here exits, traps, or writes a
# shell-global — every refusal is a stderr message + non-zero return.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  printf 'xdg-repo-park.sh defines shell functions - source it, do not run it:\n  . %s\n' "$0" >&2
  exit 64
fi
```

(The `exit 64` is the **only** exit in the file and is unreachable when sourced —
verified both shells, research §7 #4. No shebang: its absence is the repo's "source me"
signal, `bin/lib/xdg-common.sh:5`.)

### 2.2 `_repo_park_rm` — the guarded delete (mirrors `reclaim_rm`, `bin/cloud-xdg-provision.sh:2598-2607`)

```bash
# _repo_park_rm APPLY TOP HOME_REAL PATH — guarded delete of one entry.
# Layer 3 of the guard bar (§3 of the diff-spec): degenerate-path case refusal
# (reclaim_rm mirror) + strictly-under-TOP confinement. Prints the %q-quoted
# ledger line in both modes (run()'s copy-paste contract, provision :215-218);
# deletes only when APPLY=1. Any refusal or rm failure returns 1 -> caller aborts.
_repo_park_rm() {
  local apply="$1" top="$2" home_real="$3" d="$4"
  case "$d" in
    ""|"/"|"$HOME"|"$home_real"|"$top")
      printf 'repo-park: internal: refusing rm of unsafe path: %s\n' "$d" >&2; return 1 ;;
    *..*)
      printf 'repo-park: internal: refusing rm of path with "..": %s\n' "$d" >&2; return 1 ;;
    "$top"/*) : ;;
    *)
      printf 'repo-park: internal: refusing rm outside %s: %s\n' "$top" "$d" >&2; return 1 ;;
  esac
  if [ "$apply" -eq 1 ]; then
    printf '  [run]     rm -rf %q\n' "$d"
    rm -rf "$d" || { printf 'repo-park: rm failed for %s - aborting\n' "$d" >&2; return 1; }
  else
    printf '  [dry-run] rm -rf %q\n' "$d"
  fi
  return 0
}
```

Notes:
- Case-pattern quoting: `"$top"/*` — the quoted expansion is literal, the `/*` is the
  pattern (identical idiom to `cmd_reclaim`'s strictly-under-root check, `:2692`).
- `"$top"` itself is in the refusal list (the root is never an rm target — mirror of
  `RECLAIM_ROOT` in `reclaim_rm:2601`).
- Divergence from `reclaim_rm`: rm failure **aborts** (`return 1`) instead of
  warn-and-continue. Reclaim sweeps independent artifacts; park is one repo mid-surgery —
  continuing after a failed delete produces a half-parked state silently. Abort is
  recoverable (§3, "interruption safety").

### 2.3 `repo-park`

```bash
repo-park() {
  # zsh compat: unmatched globs must expand to nothing (bash default behavior is
  # handled by the [ -e ]||[ -L ] guard below); localoptions scopes it to this call.
  if [ -n "${ZSH_VERSION:-}" ]; then setopt localoptions nullglob; fi
  local usage='usage: repo-park [--apply|-y] [-f|--force] <dir>'
  local apply=0 force=0 target=""
  local top gtop home_real wt n_wt remotes st up stash branch sz e g n=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --apply|-y)  apply=1 ;;
      -f|--force)  force=1 ;;
      -h|--help)   printf '%s\n' "$usage"; return 0 ;;
      --)
        shift
        while [ $# -gt 0 ]; do
          if [ -n "$target" ]; then printf 'repo-park: one directory at a time\n' >&2; return 2; fi
          target="$1"; shift
        done
        break ;;
      -*) printf 'repo-park: unknown option: %s\n%s\n' "$1" "$usage" >&2; return 2 ;;
      *)
        if [ -n "$target" ]; then printf 'repo-park: one directory at a time\n' >&2; return 2; fi
        target="$1" ;;
    esac
    shift
  done
  if [ -z "$target" ]; then printf '%s\n' "$usage" >&2; return 2; fi

  # --- Layer 1: canonicalize + degenerate refusal (research §5.1-2) -------------
  top="$(cd "$target" 2>/dev/null && pwd -P)" \
    || { printf 'repo-park: no such dir: %s\n' "$target" >&2; return 1; }
  home_real="$(cd "$HOME" 2>/dev/null && pwd -P)" || home_real="$HOME"
  case "$top" in
    ""|"/"|"$HOME"|"$home_real")
      printf 'repo-park: refusing to park %s (never / or your home dir - the dotfiles lane makes the home dir a git work tree)\n' "$top" >&2
      return 1 ;;
  esac

  # --- Layer 2: repo-shape refusals (research §5.3-7) ---------------------------
  # Linked worktree: its .git is a gitdir-pointer FILE (research §7 #15). Checked
  # before show-toplevel because show-toplevel succeeds inside one.
  if [ -f "$top/.git" ]; then
    printf 'repo-park: %s is a linked worktree (.git is a file) - park the main clone, or git worktree remove this first\n' "$top" >&2
    return 1
  fi
  # Toplevel identity: one probe kills three attacks - plain non-repo dir (rev-parse
  # fails), BARE repo (rev-parse --show-toplevel exits 128 in bare: lab-verified;
  # NOTE the tested alias's `rev-parse --is-inside-work-tree >/dev/null` prints
  # "false" and exits 0 in a bare repo - a hole this probe closes), and a SUBDIR
  # (toplevel differs -> would nuke the parent repo).
  gtop="$(git -C "$top" rev-parse --show-toplevel 2>/dev/null)" \
    || { printf 'repo-park: not a git work tree (or bare): %s\n' "$top" >&2; return 1; }
  gtop="$(cd "$gtop" 2>/dev/null && pwd -P)" \
    || { printf 'repo-park: cannot resolve the toplevel of %s\n' "$top" >&2; return 1; }
  if [ "$gtop" != "$top" ]; then
    printf 'repo-park: %s is inside the repo at %s - park the toplevel\n' "$top" "$gtop" >&2
    return 1
  fi
  # Attached linked worktrees: deleting objects strands every sibling (fail-closed:
  # if the enumeration itself fails, refuse).
  wt="$(git -C "$top" worktree list --porcelain 2>/dev/null)" || wt=""
  if [ -z "$wt" ]; then
    printf 'repo-park: cannot enumerate worktrees of %s - refusing\n' "$top" >&2; return 1
  fi
  n_wt="$(printf '%s\n' "$wt" | grep -c '^worktree ' || true)"
  if [ "$n_wt" -ne 1 ]; then
    printf 'repo-park: %s has linked worktrees attached (git worktree list) - remove them first\n' "$top" >&2
    return 1
  fi
  # Submodules: v1 scope cut - their git dirs live in .git/modules; restore would
  # need submodule-update plumbing. Refuse loudly (research §5.7).
  if [ -e "$top/.gitmodules" ]; then
    printf 'repo-park: %s uses submodules - not supported (v1); park the submodule-free clones instead\n' "$top" >&2
    return 1
  fi
  # No remotes: park would be plain deletion - HARD refusal, -f does not override
  # (research §5, tested-alias semantics preserved).
  remotes="$(git -C "$top" remote 2>/dev/null)" || remotes=""
  if [ -z "$remotes" ]; then
    printf 'repo-park: no remotes - refusing (nothing to restore from): %s\n' "$top" >&2
    return 1
  fi
  # Idempotency: an already-parked dir is a no-op success.
  if [ "$(git -C "$top" config --get xdgcloud.parked 2>/dev/null)" = "1" ]; then
    printf 'repo-park: already parked: %s (repo-restore to rehydrate)\n' "$top"
    return 0
  fi

  # --- Layer 2b: state refusals, -f overridable (research §5 table) -------------
  st="$(git -C "$top" status --porcelain 2>/dev/null)" \
    || { printf 'repo-park: git status failed in %s - refusing\n' "$top" >&2; return 1; }
  if [ -n "$st" ] && [ "$force" -eq 0 ]; then
    printf 'repo-park: uncommitted changes (commit/push first, or -f to discard):\n' >&2
    git -C "$top" status --short >&2
    return 1
  fi
  up="$(git -C "$top" rev-list --branches --not --remotes --count 2>/dev/null)" || up=""
  if [ -z "$up" ]; then
    printf 'repo-park: cannot count unpushed commits in %s - refusing\n' "$top" >&2; return 1
  fi
  if [ "$up" -ne 0 ] && [ "$force" -eq 0 ]; then
    printf 'repo-park: %s commit(s) not on any remote (push first, or -f to discard): %s\n' "$up" "$top" >&2
    return 1
  fi
  stash="$(git -C "$top" stash list 2>/dev/null)" \
    || { printf 'repo-park: git stash list failed in %s - refusing\n' "$top" >&2; return 1; }
  if [ -n "$stash" ] && [ "$force" -eq 0 ]; then
    printf 'repo-park: stash entries would be destroyed (apply/drop them, or -f to discard): %s\n' "$top" >&2
    return 1
  fi
  # Detached-HEAD probe: symbolic-ref is empty+rc1 on detached, prints the branch
  # (even unborn) otherwise [lab-verified].
  branch="$(git -C "$top" symbolic-ref --short -q HEAD 2>/dev/null)" || branch=""
  if [ -z "$branch" ] && [ "$force" -eq 0 ]; then
    printf 'repo-park: detached HEAD (checkout a branch, or -f; restore then uses the remote default): %s\n' "$top" >&2
    return 1
  fi

  # --- Plan header ---------------------------------------------------------------
  sz="$(du -sh "$top" 2>/dev/null | cut -f1)" || sz="?"
  if [ "$apply" -eq 1 ]; then
    printf 'repo-park: parking %s   (APPLY - deleting working tree + git objects)\n' "$top"
  else
    printf 'repo-park: plan for %s   (dry-run - nothing deleted; --apply to park)\n' "$top"
  fi
  printf '  branch: %s   remotes: %s   size: %s\n' \
    "${branch:-<detached>}" "$(printf '%s\n' "$remotes" | paste -sd, -)" "$sz"

  # --- Bookkeeping (research §4): recorded BEFORE any deletion; survives in the
  # kept config. parkedBranch makes restore's branch detection offline and exact.
  if [ "$apply" -eq 1 ]; then
    git -C "$top" config xdgcloud.parked 1
    if [ -n "$branch" ]; then git -C "$top" config xdgcloud.parkedBranch "$branch"; fi
    git -C "$top" config xdgcloud.parkedAt "$(date +%Y-%m-%dT%H:%M:%S)"
  else
    printf '  [dry-run] git config xdgcloud.parked 1 (+ parkedBranch, parkedAt)\n'
  fi

  # --- Working tree: every toplevel entry except .git (research §4 delete set).
  # Glob loop, NOT find|while: no subshell (the counter works, `return 1` behaves
  # identically in bash and zsh), newline-safe filenames, empty-dir safe under
  # both shells [lab-verified]. The three patterns cover * , .x* , ..x* ; the
  # [ -e ]||[ -L ] guard drops bash's unexpanded literals.
  for e in "$top"/* "$top"/.[!.]* "$top"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    case "${e##*/}" in .git) continue ;; esac
    _repo_park_rm "$apply" "$top" "$home_real" "$e" \
      || { printf 'repo-park: aborted - %s is partially parked; run: git checkout -f HEAD (or repo-restore)\n' "$top" >&2; return 1; }
    n=$((n + 1))
  done

  # --- .git internals: delete set per research §4 (keep config/HEAD/hooks/info).
  for g in objects refs logs index packed-refs FETCH_HEAD ORIG_HEAD; do
    if [ -e "$top/.git/$g" ]; then
      _repo_park_rm "$apply" "$top" "$home_real" "$top/.git/$g" \
        || { printf 'repo-park: aborted - %s is partially parked; repo-restore recovers\n' "$top" >&2; return 1; }
    fi
  done

  # --- Re-scaffold / summary -------------------------------------------------------
  if [ "$apply" -eq 1 ]; then
    git -C "$top" init -q \
      || { printf 'repo-park: git init failed in %s - repo-restore should still recover it\n' "$top" >&2; return 1; }
    printf 'repo-park: parked %s - remotes kept: %s\n' "$top" "$(git -C "$top" remote | paste -sd, -)"
  else
    printf '  [dry-run] git init -q   (re-scaffold; .git/config with remotes kept verbatim)\n'
    printf 'repo-park: %s working-tree entries + git objects would be deleted (currently %s). Re-run with --apply to park.\n' "$n" "$sz"
  fi
  return 0
}
```

### 2.4 `repo-restore`

The user's tested branch-detection chain is **preserved verbatim** as the fallback; two
hardenings are added in front of it (parkedBranch preference; parked-shape guard) and the
may-be-empty command substitutions get `|| true` so the function survives callers running
under `set -e` (§8 #6).

```bash
repo-restore() {
  local usage='usage: repo-restore <dir> [branch]'
  local target="${1:-}" b="${2:-}" top r
  if [ -z "$target" ]; then printf '%s\n' "$usage" >&2; return 2; fi

  top="$(cd "$target" 2>/dev/null && pwd -P)" \
    || { printf 'repo-restore: no such dir: %s\n' "$target" >&2; return 1; }
  git -C "$top" rev-parse --git-dir >/dev/null 2>&1 \
    || { printf 'repo-restore: not a git repo: %s\n' "$top" >&2; return 1; }
  r="$(git -C "$top" remote 2>/dev/null | head -1)" || r=""
  if [ -z "$r" ]; then printf 'repo-restore: no remote in %s\n' "$top" >&2; return 1; fi

  # Refuse to force-reset a LIVE repo: checkout -f -B discards local state. Restore
  # only dirs marked parked by repo-park, or park-SHAPED dirs (unborn HEAD - covers
  # dirs parked by the pre-xdg-cloud alias, which recorded no marker).
  # rev-parse --verify -q HEAD: rc=1 on unborn HEAD, rc=0 once commits exist [lab-verified].
  if [ "$(git -C "$top" config --get xdgcloud.parked 2>/dev/null)" != "1" ]; then
    if git -C "$top" rev-parse --verify -q HEAD >/dev/null 2>&1; then
      printf 'repo-restore: %s is a live repo (not parked) - refusing checkout -f over it\n' "$top" >&2
      return 1
    fi
  fi

  git -C "$top" fetch "$r" || return 1

  # Branch detection - tested chain preserved, one new first preference:
  #   1. explicit [branch] argument
  #   2. xdgcloud.parkedBranch      (recorded at park time - offline + exact)
  #   3. symbolic-ref refs/remotes/$r/HEAD   (present on cloned-but-never-parked dirs)
  #   4. remote main|master from branch -r   (post-fetch, offline)
  #   5. literal "main"
  if [ -z "$b" ]; then
    b="$(git -C "$top" config --get xdgcloud.parkedBranch 2>/dev/null)" || true
  fi
  if [ -z "$b" ]; then
    b="$(git -C "$top" symbolic-ref "refs/remotes/$r/HEAD" 2>/dev/null | sed "s|^refs/remotes/$r/||")" || true
    if [ -z "$b" ]; then
      b="$(git -C "$top" branch -r 2>/dev/null | grep -E "$r/(main|master)\$" | head -1 | sed "s|^[[:space:]]*$r/||")" || true
    fi
    b="${b:-main}"
  fi

  # Checkout - tested logic preserved verbatim (checkout -B re-establishes upstream
  # tracking from unborn HEAD, research §7 #8-9).
  if git -C "$top" show-ref --verify --quiet "refs/remotes/$r/$b"; then
    git -C "$top" checkout -f -B "$b" "refs/remotes/$r/$b" || return 1
  else
    git -C "$top" checkout -f "$b" 2>/dev/null || git -C "$top" checkout -f master || return 1
  fi

  # Clear the park markers (research §4).
  git -C "$top" config --unset xdgcloud.parked       2>/dev/null || true
  git -C "$top" config --unset xdgcloud.parkedBranch 2>/dev/null || true
  git -C "$top" config --unset xdgcloud.parkedAt     2>/dev/null || true
  printf 'repo-restore: restored %s on %s (from %s)\n' "$top" "$b" "$r"
  return 0
}
```

## 3. Guard-bar analysis — why the `rm` is safe (mission #3)

Three independent layers must all pass before any byte is deleted; each alone already
blocks the catastrophic cases:

1. **Canonicalized root** (`cd "$target" && pwd -P`) + **degenerate `case` refusal** on
   `""|"/"|"$HOME"|"$home_real"` — the `reclaim_rm`/`cmd_reclaim` mirror
   (`bin/cloud-xdg-provision.sh:2600-2603`, `:2671-2673`). `$home_real` matters because
   macOS `/tmp` and `$HOME` can be symlinks (research §7 #13) and because the dotfiles
   lane makes `$HOME` itself a git work tree (`bin/cloud-xdg-provision.sh:95`) — without
   this case guard, `repo-park ~` would pass every git check.
2. **Toplevel identity** — `rev-parse --show-toplevel` must succeed AND canonicalize to
   exactly `$top`. Kills: non-repo dirs (probe fails), **bare repos** (probe exits 128 —
   lab-verified; closes the tested alias's `--is-inside-work-tree` hole, which prints
   `false` with **exit 0** in a bare repo), and subdirs (toplevel ≠ `$top`, which would
   otherwise delete the parent repo's tree). Plus the shape refusals: linked-worktree
   pointer file, attached-worktree count (fail-closed on enumeration error),
   `.gitmodules`, no-remotes (hard).
3. **`_repo_park_rm` per-path guard** — re-runs the degenerate `case` (now including
   `"$top"` itself and `*..*`) and requires `"$top"/*` prefix on every path. The only
   path sources are the `maxdepth-1` glob over `$top` and the fixed
   `objects/refs/logs/index/packed-refs/FETCH_HEAD/ORIG_HEAD` list — never
   helper-stdout, never user input (destruction-lane invariant from the evict lane).

**Interruption safety**: deletion order is working tree → `.git` internals → `git init`.
Abort during phase 1 leaves `.git` intact (`git checkout -f HEAD` restores everything);
abort during phase 2 leaves config+HEAD intact and `repo-restore` recovers (research §4
verified restore-from-unborn works; `git init -q` in an existing repo is safe and
idempotent, `git-init(1)`). No trap needed — consistent with reclaim's no-recovery-trap
posture (`docs/architecture/reclaim-diff.md` §3) and mandatory here (sourced code must
not install traps).

## 4. Divergences from the tested `~/.bash_aliases` version (mission #1/#2/#4)

| # | Tested behavior | Shipped behavior | Why |
|---|---|---|---|
| 1 | Acts immediately | **Dry-run default; `--apply`/`-y` gates deletion; `-f` orthogonal** | Locked user decision. Mirrors the repo-wide invariant (CLAUDE.md #2) and reclaim's discipline (`:2676-2677`). |
| 2 | Plumbing (a): `find . -mindepth 1 -delete && git init -q` + replay `remote.*` via `config --get-regexp \| while read k v` | **Plumbing (b): keep `.git/config`+`HEAD`+`hooks`+`info`; surgical delete; `git init -q`** | Research §4 bake-off: (b) preserves **multi-value fetch refspecs byte-for-byte** (replay with `git config k v` silently collapses them — second write replaces, needs `--add`), values with spaces/globs, and all non-remote config (`credential.*`, `core.*`, partial-clone `promisor`/`partialclonefilter`, sha256 `extensions.objectformat`). Also keeps user hooks + `info/exclude` — data **not recoverable from the remote**. Zero parsing, less code. |
| 3 | `rev-parse --is-inside-work-tree >/dev/null` as the repo check | `rev-parse --show-toplevel` + canonical-equality | **Lab-verified hole**: in a bare repo the tested probe prints `false` and exits **0** — the guard passes and `find -delete` would destroy a bare repo (which *is* its objects). Also adds subdir protection the tested version lacks (`repo-park sub/` from inside a repo would have deleted `sub/`'s siblings? No — worse: `find "$d"` scoped it, but `git init` in a subdir corrupts nothing yet leaves the parent repo dirty with a nested repo; the toplevel check makes the semantics exact). |
| 4 | `"${1:?usage…}"` for the missing-arg case | Explicit `[ -z "$target" ] … return 2` | **Lab-verified**: `${1:?}` inside a sourced function **kills a non-interactive shell** (bash 3.2 and zsh both; outer shell dies, rc 127/1). Any user script that sources the rc and calls `repo-park` with a bug would terminate. |
| 5 | No unpushed/stash/detached/worktree/submodule/bare checks | Full research-§5 refusal set | Deleting objects destroys anything not on a remote; each probe is cheap and verified (research §7 #11-16). All state refusals honor the tested `-f` override; no-remotes stays hard (tested semantics). |
| 6 | Restore branch detection: symbolic-ref remote HEAD → `branch -r` main/master → `main`; `show-ref` gate; `checkout -f -B` | **Preserved verbatim** as steps 3-5; `xdgcloud.parkedBranch` inserted as step 2 | Mission #4. parkedBranch (research §4) restores the branch the user was actually on, offline and exact; the tested chain remains the proven fallback for unmarked dirs. `\|\| true` added on may-be-empty substitutions (set-e-proofing, §8 #6). |
| 7 | Restore acts on any repo | Parked-shape guard: marker `xdgcloud.parked=1` OR unborn HEAD | `checkout -f -B` discards local state; refusing live repos prevents "restore" from resetting an active clone. The unborn-HEAD escape hatch keeps dirs parked by the old alias (no marker) restorable — tested workflows keep working. |
| 8 | `( cd "$d" && … )` subshell | `git -C "$top" …` throughout | Lab-verified `git -C dir init -q` works; avoids cd-subshell cwd games entirely. |

## 5. Smoke groups (`tests/smoke.sh`) — mission #6

### 5.1 Harness wiring (two small edits near the top)

- After `rec_root=""` (`tests/smoke.sh:44`): add `park_root=""` with the same comment style.
- In `cleanup()` (`:51`): `rm -rf "${sandbox}" ${rec_root:+"${rec_root}"} ${park_root:+"${park_root}"}`.

### 5.2 New groups — appended immediately before the final `echo "smoke: PASS"`

Placement after the reclaim groups keeps the hermetic git identity exports (`:3240-3241`)
in effect. Fixture root **outside the work tree** via `host_tmp` (`:39`) — mandatory for
the not-a-repo refusal (same reasoning as `rec_root`, `:3242-3246`).

```bash
# ===========================================================================
# repo-park / repo-restore (bin/xdg-repo-park.sh) — sourced-function contract.
# Destructive-on-repos: every fixture lives under park_root (mktemp, outside
# the work tree, EXIT-trap cleaned). CAPTURE-then-INSPECT throughout.
# ===========================================================================
PARKLIB="${repo}/bin/xdg-repo-park.sh"
park_root="$(mktemp -d "${host_tmp}/xdg-park-smoke.XXXXXX")"
# Invoke a function from the sourced file in a fresh /bin/bash (L3 pattern, :1143).
park_run() { /bin/bash -c '. "$1"; shift; "$@"' _ "${PARKLIB}" "$@"; }

# Fixture: local bare "remote" + a pushed clone with a spaces path (research §2).
git init -q --bare "${park_root}/origin.git"
git clone -q "${park_root}/origin.git" "${park_root}/work" 2>/dev/null
( cd "${park_root}/work" && echo hello > f.txt && mkdir -p "dir with spaces" \
    && echo deep > "dir with spaces/g.txt" && git add -A && git commit -qm init \
    && git push -q origin HEAD )
defbr="$(git -C "${park_root}/work" symbolic-ref --short HEAD)"   # main OR master — never assume
```

**P1 — dry-run is the default and deletes nothing** (R1 style, `:3272-3288`):
`out="$(park_run repo-park "${park_root}/work" 2>&1)"` →
`assert_contains "dry-run - nothing deleted"`, `assert_contains "[dry-run] rm -rf"`,
then `[ -e ]` loop over `f.txt`, `dir with spaces/g.txt`, `.git/objects` — all present.
Also run once with **`-f` and no `--apply`** and re-assert nothing deleted
(orthogonality proof: `-f` never implies apply).

**P2 — `--apply` parks**: `park_run repo-park --apply "${park_root}/work"` → `f.txt`
and `dir with spaces` gone; `git -C work remote -v` still names `origin.git`;
`git -C work config --get xdgcloud.parked` = `1`; `config --get xdgcloud.parkedBranch`
= `${defbr}`; `.git/hooks` still present; `[ ! -e .git/index ]`.

**P3 — restore round-trips**: `park_run repo-restore "${park_root}/work"` → `f.txt`
content = `hello`; `dir with spaces/g.txt` back; `git status --porcelain` empty;
`git -C work log --oneline` non-empty; current branch = `${defbr}`;
`config --get xdgcloud.parked` now **unset** (set +e capture, expect rc 1);
`git rev-parse --abbrev-ref '@{upstream}'` = `origin/${defbr}`.

**P4 — every refusal exits non-zero and names the cause** (R3 pattern:
`set +e; out="$(park_run repo-park … 2>&1)"; rc=$?; set -e` + `assert_nonzero` +
`assert_contains`):

| Case | Fixture | Expected message fragment |
|---|---|---|
| non-repo dir | `mkdir "${park_root}/plain"` | `not a git work tree` |
| bare repo | `${park_root}/origin.git` | `not a git work tree (or bare)` |
| subdir | `${park_root}/work/dir with spaces` (post-P3) | `park the toplevel` |
| dirty | `echo change >> work/f.txt` (then `git checkout -f` to reset) | `uncommitted changes` |
| unpushed | commit without push (then `git reset --hard origin/${defbr}`) | `not on any remote` |
| no remotes | fresh `git init` dir + one commit | `no remotes` |
| linked worktree (the linked dir) | `git -C work worktree add "${park_root}/linked" -b tmpbr` | `is a linked worktree` |
| linked worktree (the main clone) | same fixture, park `work` | `linked worktrees attached` (then `git worktree remove` + delete `tmpbr`) |
| detached HEAD | `git -C work checkout -q --detach` (then re-checkout `${defbr}`) | `detached HEAD` |
| restore on a live repo | `park_run repo-restore "${park_root}/work"` while un-parked | `not parked` |
| missing arg | `park_run repo-park` | usage line, rc=2 — **and the harness shell survives** (the `${1:?}` regression this replaces) |
| direct execution | `set +e; /bin/bash "${PARKLIB}"; rc=$?` | rc=64, `source it` |

**P5 — zsh smoke (gated)**: `if command -v zsh >/dev/null 2>&1; then … fi` — repeat P1
(dry-run deletes nothing) and one refusal via
`zsh -c '. "$1"; shift; "$@"' _ "${PARKLIB}" …`, asserting the refusal **returns**
(rc≠0 but the zsh process itself completes the trailing `echo alive` sentinel — proves
no `exit` fired). Skip with an `echo "… SKIPPED (no zsh)"` line, I4-style (`:3231`).

## 6. README section — mission #7

Insert as a new top-level section **after `## xdg-tui …` (ends ~L165) and before
`## home-tree.sh …` (~L166)**:

```markdown
## `xdg-repo-park.sh` — park/restore pushed git clones (optional, sourced)

Frees the disk of a fully-pushed clone **without losing the ability to get it back**:
`repo-park` deletes the working tree + git objects but keeps `.git/config` (your
remotes, verbatim) so the directory stays a valid, remotes-only marker.
`repo-restore` fetches and checks it back out — on the branch you were on.

Add to your `~/.bashrc` / `~/.zshrc` (it defines functions; it is not a script):

    . /path/to/xdg-cloud/bin/xdg-repo-park.sh

    # ALWAYS dry-run first — prints exactly what would be deleted, touches nothing:
    repo-park ~/repos/some-clone
    # when the plan looks right:
    repo-park --apply ~/repos/some-clone
    # later, get it back:
    repo-restore ~/repos/some-clone

**Destructive under `--apply`** — anything not on a remote is gone for good.
`repo-park` refuses dirty trees, unpushed commits, stashes, and detached HEAD
(`-f` overrides those four; nothing overrides a repo with no remotes). Known
blind spots: local-only tags and reflog-only commits are destroyed silently.
Not supported: submodules, bare repos, linked worktrees (all refused).
```

## 7. Makefile — no change (mission #5 confirmation)

- `Makefile:20` `shellcheck bin/*.sh …` matches `bin/xdg-repo-park.sh` — lint-covered
  with zero edits. Research §7 #3 verified a no-shebang, `# shellcheck shell=bash`,
  functions-only file with hyphenated names lints clean under `.shellcheckrc`
  (`enable=all` minus the repo disables); the `setopt` guard line was additionally
  lab-verified clean.
- `Makefile:47` `chmod +x bin/*.sh` will mark it executable — accepted; the §2.1
  exec-guard makes direct execution self-explaining (exit 64 + usage), smoke-asserted in P4.

## 8. bash 3.2 / zsh / sourced-function footguns (binding) — mission #9

1. **Never `exit`, `die`, `trap`, `set -e/-u` toggles, or globals.** The file runs in
   the user's shell. All refusals: `printf … >&2; return 1|2`. The exec-guard's
   `exit 64` is unreachable when sourced (research §7 #4). No `begin_mutating_mode`,
   no lock (a park is one-dir-scoped and idempotently recoverable).
2. **`${1:?}` is banned** — lab-verified it kills a **non-interactive** sourcing shell
   in both bash 3.2 and zsh. Explicit `[ -z … ] && usage; return 2` instead (as if/fi,
   see #4).
3. **No `find|while` / `printf|while read` pipes for anything needing parent-shell
   state or `return`.** In zsh the *last* pipe segment runs in the **current shell**, so
   an `exit` there kills the terminal; in bash it's a subshell, so counters vanish. The
   glob for-loop (§2.3) sidesteps both — no subshell in either shell — and is
   newline-in-filename safe. Option (b) plumbing also eliminated the tested version's
   `config --get-regexp | while read k v` replay entirely.
4. **Trailing `[ cond ] && cmd` as a function's last statement returns 1** on the
   false path (known repo lesson: set-e + trailing AND-list). Every conditional tail is
   `if/fi`.
5. **zsh NOMATCH**: an unmatched glob aborts zsh by default.
   `if [ -n "${ZSH_VERSION:-}" ]; then setopt localoptions nullglob; fi` at function
   top — parse-safe in bash (never executed), scoped to the call in zsh; the
   `[ -e ]||[ -L ]` guard handles bash's literal-pattern fallthrough. Lab-verified
   identical output in both shells, including empty dirs.
6. **set-e-proof substitutions**: callers may source the file in scripts running
   `set -e`. Every command substitution that may legitimately fail/return-empty gets
   `|| var=""` or `|| true` (`b="$(…| grep …)" || true`). The smoke harness itself runs
   `set -euo pipefail` around the `park_run` boundary, which exercises this.
7. **zsh word-splitting divergence** (research §7 #17): never rely on unquoted
   expansion; iterate via globs or literal `for` lists only. Everything is quoted.
8. **bash 3.2 bans** (CLAUDE.md invariant 1): no `[[ ]]`, no arrays needed here, no
   `mapfile`, no `<()`, no `readlink -f` — canonicalize with `cd … && pwd -P` only.
9. **No backticks in quoted strings/messages** (CLAUDE.md invariant 7) — all messages
   are plain printf text; the §2.3 abort message deliberately words its recovery hint
   backtick-free ("run: git checkout -f HEAD").
10. **Case-pattern literalness**: quoted `"$top"` inside a case pattern is literal even
    if the path contains glob characters; the `/*` suffix is the only pattern part
    (idiom from `cmd_reclaim:2692`).
11. **Spaces in paths**: covered by the glob loop + universal quoting; P2/P3 smoke a
    `dir with spaces/` fixture through the full park/restore round trip.
12. **`paste -sd, -`** (from the tested alias) is POSIX and present on macOS + Linux —
    kept for the remotes summary line.

## 9. Reasoning chain

Dry-run-by-default is a locked user decision → the function needs a plan/act split
without the script's global `DRY_RUN` → all-locals arg parsing with inline `%q` ledger
printing (research §3), which required abandoning the tested version's act-immediately
shape. Preserving the tested version's *proven* behavior therefore means preserving its
**decision semantics** (refusal messages, `-f` override, restore's branch-detection
chain, first-remote choice) rather than its plumbing — and its plumbing had three
lab-verified defects (bare-repo hole, `${1:?}` shell-kill, multi-value-refspec-collapsing
replay) that the research's option (b) removes wholesale, because keeping `.git/config`
means there is nothing to parse or replay. Option (b) in turn forces the delete set to be
surgical (objects/refs/logs/index/packed-refs/FETCH_HEAD/ORIG_HEAD), which is exactly
what makes interruption safe (config+HEAD always survive → repo-restore always recovers)
and what lets `-f` stay orthogonal to `--apply`: force only widens *which repos may be
parked*, never *whether deletion happens*. The guard bar then ports from `reclaim_rm`
because both lanes share the same threat model (a destructive sweep that must never
false-positive), with the sourced-function inversion (return-not-exit) as the only
structural change — and zsh scope (ruled IN, §10 #1) dictated the glob-loop delete walk,
since it is the one iteration construct with identical no-subshell semantics in bash 3.2
and zsh.

## 10. Resolved decisions

| # | Question (research §9 / mission) | Ruling |
|---|---|---|
| 1 | zsh in scope? | **Yes** — dotfiles lane treats zsh first-class (`bin/cloud-xdg-provision.sh:1543`), macOS default shell. Bodies written to the bash∩zsh subset (§8 #3/#5/#7); zsh-gated P5 smoke group. |
| 2 | Stash refusal hard or `-f`? | **`-f`-overridable** (research recommendation; consistent with dirty/unpushed). |
| 3 | `--tags` in the unpushed probe? | **No (v1)** — documented blind spot in README §6 and the file header. |
| 4 | `--apply` vs `-y` | **Both, synonyms.** `--apply` is the repo idiom; `-y` is muscle-memory. `-f`/`--force` likewise synonyms. |
| 5 | Provision-script `--repo-park` mode? | **Out of scope** (research §9.5) — noted for a future slice; `dispatch_mode` (`:2781`) would absorb it cheaply. |
| 6 | Plumbing (a) vs (b) — mission #2 | **(b)**: keep `.git/config`+`HEAD`+`hooks`+`info`, surgical delete, `git init -q`. Justification in §4 row 2. |
| 7 | File path — mission #5 | **`bin/xdg-repo-park.sh`** (research §1 option A; NOT `xdg-repo-aliases.sh` — "aliases.sh" is the generated dotfiles artifact, `bin/cloud-xdg-provision.sh:95`). |
| 8 | Restore dry-run? | **No** — mission locks dry-run for park only; restore is constructive and stays act-immediately as tested. Its new parked-shape guard (§4 row 7) covers the force-reset hazard instead. |
| 9 | S2 partition — mission #8 | **One `pact-devops-engineer` coder** for all four files (shell function file + smoke + README; Makefile untouched). Single domain (shell/tooling), tightly coupled deliverables (smoke asserts exact message strings from the function file), no parallelizable seam — a second coder would only create message-string drift. |

## 11. Test-phase notes (beyond smoke)

- TEST may add: partial-clone / `extensions.objectformat=sha256` fixture (research §8
  risk row 5 — config is kept so extensions persist, but restore round-trip unproven);
  multi-value fetch-refspec round-trip assert (research §7 #7 proved the mechanism;
  a smoke assert would pin it); restore with an explicit `[branch]` argument.
- The P4 message-fragment asserts are the contract: coders must not reword refusal
  messages without updating P4 in the same change.
