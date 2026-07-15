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
# Known v1 blind spots: local-only tags and reflog-only commits are destroyed
# silently; submodules, bare repos, and linked worktrees are refused.
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  printf 'xdg-repo-park.sh defines shell functions - source it, do not run it:\n  . %s\n' "$0" >&2
  exit 64
fi

# _repo_park_rm APPLY TOP HOME_REAL PATH — guarded delete of one entry.
# Layer 3 of the guard bar (diff-spec §3): degenerate-path case refusal
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
  # NOTE the tested alias's rev-parse --is-inside-work-tree probe prints
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
