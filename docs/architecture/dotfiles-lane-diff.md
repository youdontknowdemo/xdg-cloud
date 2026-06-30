# Slice 3 — Dotfiles bare-repo lane Diff-Spec (step 8)

**Phase:** PACT Architect (apply-ready diff-lock) · **Branch:** `feature/dotfiles-lane`
**Upstream:** plan §D5, research `docs/preparation/research-offload-dotfiles-macos.md` (dotfiles §3e),
teachback Task #43. **Builds on merged slices 1–2** (`a116568`): `MODE`/`MODE_ARG`/`set_mode`/
`begin_mutating_mode` (line 984: `guard_not_root; install_cleanup_trap; acquire_lock`); `--dotfiles-init/-track/-status`
already parsed (lines 359–361) and **reserved-die** in `dispatch_mode` (line 1329–1330).

> **Scope: step 8 only (init/track/status, LOCAL-side).** Lead-confirmed decisions:
> **ADOPT (clone+checkout) is DEFERRED** — design documented in §7, NOT implemented/tested here.
> **rc target = refuse-don't-guess** (§3). No lib change. home-tree.sh FROZEN; do NOT touch the
> rclone filter heredoc, `HOMETREE_KEYS`, `XDG_DIR_REGISTRY`, `CLOUDXDG_KEYS`, or any slice-1/2
> L3/SAFE_DIRS/§6/offload assertion.

---

## 0. Files touched

| File | Change |
|---|---|
| `bin/cloud-xdg-provision.sh` | config consts + `--dotfiles-rc` flag; `usage()`; `dotfiles_git` + 5 helpers + 3 `cmd_dotfiles_*`; dispatch wiring |
| `tests/smoke.sh` | NEW dotfiles coverage (test-engineer; sandbox-HOME) — no change to existing assertions |
| `bin/lib/xdg-common.sh`, `bin/home-tree.sh` | UNTOUCHED |

---

## 1. Config consts + `--dotfiles-rc` flag

Add near the other config (after the offload `CODE_*` block), using literal values (NOT the
`:=` env idiom for the fixed paths; `DOTFILES_RC` uses it):

```sh
DOTFILES_DIR="$HOME/.dotfiles"                       # the bare repo (work-tree = $HOME)
DOTFILES_ALIASES="$XDG_CONFIG_HOME/xdg-cloud/aliases.sh"   # dedicated sourced alias file
DOTFILES_SENTINEL="# >>> xdg-cloud dotfiles >>>"     # rc-block start marker (idempotency key)
DOTFILES_SENTINEL_END="# <<< xdg-cloud dotfiles <<<" # rc-block end marker
: "${DOTFILES_RC:=}"                                 # explicit rc path (--dotfiles-rc); else $SHELL-derived
RC_TARGET=""                                         # resolved rc (set by dotfiles_resolve_rc; see §3)
```

Arg-parse: add beside the other value-taking flags (in the existing `case`):

```sh
    --dotfiles-rc)        shift; DOTFILES_RC="${1:?--dotfiles-rc needs a path}" ;;
```

`usage()`: move the three dotfiles flags out of the "reserved" note into Modes, and add:

```
  --dotfiles-init        Create a bare ~/.dotfiles repo + install the `dotfiles` alias
                         (dry-run unless --apply). Idempotent; backs up your rc first.
  --dotfiles-track <p>   Track a dotfile/dir into the bare repo (refuses cloud-xdg-managed
                         paths). --apply to commit.
  --dotfiles-status      Show tracked-file status + whether the alias/rc block are installed.
  --dotfiles-rc PATH     Shell rc to edit (default: ~/.zshrc for zsh, ~/.bashrc for bash).
                         macOS bash login shells usually want --dotfiles-rc ~/.bash_profile.
```

(Delete the `--dotfiles-*` entries from the existing "reserved, not yet implemented" line.)

---

## 2. `dotfiles_git` wrapper + repo predicate

```sh
# Run git against the bare dotfiles repo with $HOME as the work tree. Body only (no source-time run).
dotfiles_git() { git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" "$@"; }

# True (0) if $DOTFILES_DIR is OUR bare repo (idempotency / refuse-clobber discriminator).
dotfiles_is_ours() {
  [ -d "$DOTFILES_DIR" ] || return 1
  [ "$(git --git-dir="$DOTFILES_DIR" rev-parse --is-bare-repository 2>/dev/null)" = "true" ]
}
```

---

## 3. rc resolution — refuse-don't-guess (sets a GLOBAL, never `$()`)

```sh
# Resolve the rc to edit into RC_TARGET. --dotfiles-rc wins; else by $SHELL basename. Unknown/unset
# $SHELL => DIE requiring --dotfiles-rc (NEVER guess-edit the wrong rc — the alias would silently
# never load). MUST be called WITHOUT command-substitution: `die` (exit 1) inside $() exits only the
# SUBSHELL, so a `rc="$(resolve)"` form would NOT terminate the parent on failure (bash gotcha).
dotfiles_resolve_rc() {
  if [ -n "$DOTFILES_RC" ]; then RC_TARGET="$DOTFILES_RC"; return 0; fi
  case "$(basename "${SHELL:-}")" in
    zsh)  RC_TARGET="$HOME/.zshrc" ;;
    bash) RC_TARGET="$HOME/.bashrc" ;;
    *)    die "cannot determine your shell rc from \$SHELL='${SHELL:-}'. Re-run with
  --dotfiles-rc PATH (e.g. macOS bash login shells often want --dotfiles-rc ~/.bash_profile)." ;;
  esac
}
```

---

## 4. `cmd_dotfiles_init`

```sh
cmd_dotfiles_init() {
  begin_mutating_mode                      # guard_not_root + trap + (apply-only) lock
  # refuse-clobber idempotency:
  if [ -e "$DOTFILES_DIR" ] || [ -L "$DOTFILES_DIR" ]; then
    dotfiles_is_ours || die "$DOTFILES_DIR exists but is not our bare git repo — refusing to clobber it."
    info "bare repo already present at $DOTFILES_DIR — ensuring config + alias only."
  fi
  dotfiles_resolve_rc                       # sets RC_TARGET or dies (in THIS shell)
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] git init --bare $DOTFILES_DIR        (skipped if already present)"
    info "[dry-run] dotfiles config --local status.showUntrackedFiles no"
    info "[dry-run] write alias file: $DOTFILES_ALIASES"
    info "[dry-run] add guarded source block to: $RC_TARGET   (only if sentinel absent; rc backed up first)"
    return 0
  fi
  dotfiles_is_ours || run git init --bare "$DOTFILES_DIR"
  dotfiles_git config --local status.showUntrackedFiles no
  # alias file — $HOME stays LITERAL (single-quoted alias value), written via printf with escaped
  # \$HOME under a double-quoted format; NO backticks (team footgun: backticks in a quoted string
  # can execute at parse/source time).
  mkdir -p "$(dirname "$DOTFILES_ALIASES")"
  {
    printf '%s\n' "# Generated by $SELF — bare-repo dotfiles alias. Sourced from your shell rc."
    printf '%s\n' "alias dotfiles='git --git-dir=\$HOME/.dotfiles --work-tree=\$HOME'"
  } > "$DOTFILES_ALIASES"
  info "Wrote alias file: $DOTFILES_ALIASES"
  dotfiles_install_rc_source                # idempotent + #5b backup (see §5)
  info "Done. Open a new shell (or '. $RC_TARGET') then: dotfiles status"
}
```

---

## 5. `dotfiles_install_rc_source` — the riskiest piece (idempotent + backup-first + never-clobber)

```sh
# Add a guarded `source` block for the alias file to RC_TARGET, ONCE. Idempotency key = the
# sentinel comment (grep -qF, fixed-string). Backs up the rc first with the #5b uniquifier
# pattern (timestamp + counter, -e OR -L to catch a dangling-symlink backup path). The source
# line is written SINGLE-QUOTED so ${XDG_CONFIG_HOME:-$HOME/.config} expands at rc-source time
# (per-machine), NOT at write time; no backticks.
dotfiles_install_rc_source() {
  local bak stamp n
  if [ -f "$RC_TARGET" ] && grep -qF "$DOTFILES_SENTINEL" "$RC_TARGET" 2>/dev/null; then
    info "rc already contains the xdg-cloud dotfiles block ($RC_TARGET) — leaving it."
    return 0
  fi
  if [ -e "$RC_TARGET" ] || [ -L "$RC_TARGET" ]; then
    stamp="$(date +%Y%m%d-%H%M%S)"; bak="${RC_TARGET}.bak-${stamp}"; n=1
    while [ -e "$bak" ] || [ -L "$bak" ]; do bak="${RC_TARGET}.bak-${stamp}.${n}"; n=$((n + 1)); done
    cp "$RC_TARGET" "$bak"; info "Backed up $RC_TARGET -> $bak"
  fi
  mkdir -p "$(dirname "$RC_TARGET")"
  {
    printf '%s\n' "$DOTFILES_SENTINEL"
    printf '%s\n' '[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/xdg-cloud/aliases.sh" ] && . "${XDG_CONFIG_HOME:-$HOME/.config}/xdg-cloud/aliases.sh"'
    printf '%s\n' "$DOTFILES_SENTINEL_END"
  } >> "$RC_TARGET"
  info "Added the xdg-cloud dotfiles source block to $RC_TARGET"
}
```

> **Idempotency contract:** the sentinel grep is the ONLY gate — re-running `--dotfiles-init` after
> the block exists is a no-op (no duplicate append, no second backup). The block is **appended**,
> never rewriting existing rc content; the backup precedes any write. If the user deletes the block,
> a re-run re-adds it (and backs up again). Removal is manual (documented), to avoid an rc-rewriter.

---

## 6. `cmd_dotfiles_track` + overlap/recursion guard

```sh
# Refuse tracking a path that collides with a cloud-xdg-managed lane or recurses into the bare
# repo. Name-based on the top-level $HOME component (no CLOUD_ROOT needed): reject user-data
# redirect targets (CLOUDXDG_KEYS), CODE/offload containers (CODE_KEYS), machine-local dirs
# (LOCAL_KEYS), and $HOME/.dotfiles itself. bash-3.2 param-expansion only (no readlink -f).
dotfiles_guard_path() {
  local arg="$1" abs rel top k nm
  case "$arg" in /*) abs="$arg" ;; *) abs="$HOME/$arg" ;; esac
  case "$abs" in "$HOME"/*) : ;; *) die "refusing '$arg' — outside \$HOME (the dotfiles work-tree)." ;; esac
  rel="${abs#"$HOME"/}"; top="${rel%%/*}"
  [ "$top" = ".dotfiles" ] && die "refusing \$HOME/.dotfiles (the bare repo itself — recursion)."
  for k in $CLOUDXDG_KEYS; do                                  # shellcheck disable=SC2086
    nm="$(local_name "$(field "$(registry_row "$k")" 2)" "$(field "$(registry_row "$k")" 3)")"
    [ "$top" = "$nm" ] && die "refusing '$top' — it is a cloud-xdg redirect target (user-data lane)."
  done
  for k in $CODE_KEYS; do                                      # shellcheck disable=SC2086
    nm="$(local_name "$(field "$(code_row "$k")" 2)" "$(field "$(code_row "$k")" 3)")"
    [ "$top" = "$nm" ] && die "refusing '$top' — it is a CODE/offload container (manage with --offload)."
  done
  for k in $LOCAL_KEYS; do                                     # shellcheck disable=SC2086
    nm="$(local_name "$(field "$(code_row "$k")" 2)" "$(field "$(code_row "$k")" 3)")"
    [ "$top" = "$nm" ] && die "refusing '$top' — it is a machine-local dir (never tracked)."
  done
}

cmd_dotfiles_track() {                       # $1 = path (v1: single path via MODE_ARG)
  begin_mutating_mode
  dotfiles_is_ours || die "no dotfiles bare repo at $DOTFILES_DIR — run --dotfiles-init first."
  dotfiles_guard_path "$1"                    # dies on overlap/recursion
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] dotfiles add $1"; info "[dry-run] dotfiles commit -m 'track: $1'"; return 0
  fi
  run git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" add "$1"
  dotfiles_git commit -m "track: $1"
  info "Tracked: $1"
}
```

> **v1 = single path per invocation** (`MODE_ARG`). Multi-path `--dotfiles-track a b c` would need
> the arg parser to collect trailing args into a list — flagged as a trivial follow-up (§8 D-3).

---

## 7. `cmd_dotfiles_status` (read-only) + dispatch wiring + DEFERRED adopt

```sh
cmd_dotfiles_status() {                       # read-only: NO begin_mutating_mode
  if ! dotfiles_is_ours; then info "no dotfiles bare repo at $DOTFILES_DIR (run --dotfiles-init)."; return 0; fi
  log "Tracked dotfiles (git status -s):"
  dotfiles_git status -s
  [ -f "$DOTFILES_ALIASES" ] && info "alias file: present ($DOTFILES_ALIASES)" \
                              || info "alias file: MISSING ($DOTFILES_ALIASES) — run --dotfiles-init"
  # rc sentinel: best-effort, read-only, never die. Check --dotfiles-rc if given, else both rc files.
  local rc found=0
  for rc in ${DOTFILES_RC:+"$DOTFILES_RC"} "$HOME/.zshrc" "$HOME/.bashrc"; do
    [ -f "$rc" ] && grep -qF "$DOTFILES_SENTINEL" "$rc" 2>/dev/null && { info "rc source block: present in $rc"; found=1; }
  done
  [ "$found" -eq 0 ] && info "rc source block: not found (run --dotfiles-init, or --dotfiles-rc PATH)"
}
```

**Dispatch wiring** — replace the reserved-die line so the three dotfiles modes are LIVE:

```sh
    dotfiles-init)    cmd_dotfiles_init ;;
    dotfiles-track)   cmd_dotfiles_track "$MODE_ARG" ;;
    dotfiles-status)  cmd_dotfiles_status ;;
```

**DEFERRED — fresh-machine ADOPT (design only; do NOT implement/test this slice):** a future
`--dotfiles-remote <url>` would `git clone --bare <url> "$DOTFILES_DIR"`, then `dotfiles checkout`.
`checkout` FAILS if a tracked file already exists locally; the safe handling is **collision→aside**:
parse the conflicting paths from the checkout error, move each to `<path>.pre-dotfiles-<stamp>`
(uniquified), then re-run `dotfiles checkout` — **never** `git checkout --force` (that silently
overwrites the user's existing files). This `$HOME`-checkout-clobber surface is exactly why adopt is
out of this slice; it lands in its own slice with sandbox-HOME collision tests.

---

## 8. bash 3.2 / shellcheck / footguns (binding) + user-decisions

- **`die`-inside-`$()` does NOT kill the parent** → `dotfiles_resolve_rc` sets the global `RC_TARGET`
  and is called bare (never `rc="$(dotfiles_resolve_rc)"`). This is the load-bearing correctness point.
- **No backticks** in any written line; alias `$HOME` kept literal via escaped `\$HOME` (double-quoted
  printf), the rc source line written **single-quoted** so `${XDG_CONFIG_HOME:-$HOME/.config}` expands
  at rc-source time, not write time.
- `case` only in function bodies (not inline in `$()`); `$(basename "${SHELL:-}")` in the case head is
  a plain command-sub (no case inside) — safe.
- `grep -qF` fixed-string sentinel; `rev-parse --is-bare-repository` guarded with `2>/dev/null` + string compare.
- `for k in $CLOUDXDG_KEYS` etc. → `# shellcheck disable=SC2086`. No `[[ ]]`/assoc/mapfile/`<()`/`readlink -f`.
- Mutating modes (`init`/`track`) call `begin_mutating_mode`; `status` does not. No `resolve_cloud_root`
  (dotfiles is purely local — no cloud mount involved).

**Resolved decisions (lead 2026-06-30):** adopt DEFERRED (design-only §7); rc refuse-don't-guess (§3);
config path `$XDG_CONFIG_HOME/xdg-cloud/aliases.sh`.
**Flag (minor) D-3:** `--dotfiles-track` is single-path in v1 (`MODE_ARG`); multi-path is a trivial
parser follow-up — confirm single-path is acceptable for v1.
**Note (edge):** if the user runs with a NON-default `XDG_CONFIG_HOME` but their interactive shell does
not export it before the source line, the `${XDG_CONFIG_HOME:-$HOME/.config}` fallback could miss the
alias file — documented; `--dotfiles-rc` + exporting `XDG_CONFIG_HOME` early covers it.

---

## 9. Build order (coder)

1. Config consts + `--dotfiles-rc` flag + `usage()` (§1). `make test` green (no behavior change).
2. `dotfiles_git` + `dotfiles_is_ours` + `dotfiles_resolve_rc` (§2–§3).
3. `dotfiles_install_rc_source` (§5) — the idempotent, backup-first rc-edit (test FIRST in sandbox).
4. `cmd_dotfiles_init` (§4).
5. `dotfiles_guard_path` + `cmd_dotfiles_track` (§6).
6. `cmd_dotfiles_status` (§7) + dispatch wiring.
7. Hand to test-engineer: sandbox-HOME for ALL dotfiles tests; assert rc idempotency (run init twice →
   one block, one backup), refuse-clobber (foreign ~/.dotfiles → die), overlap guard (track ~/Documents,
   ~/repos, ~/.dotfiles → die), unknown-`$SHELL` → die requiring --dotfiles-rc, alias-file literal `$HOME`.

---

## 10. Reasoning chain (rc-edit idempotency + alias-quoting)

- **Sentinel-grep idempotency, append-only, backup-first** — *because* the rc is the user's hand-owned
  file: we must never duplicate-append (breaks on every re-run), never rewrite/clobber (data loss), and
  always leave a restore point. The sentinel comment is a stable idempotency key independent of the
  source-line's exact text, so reformatting the line later still detects the existing block.
- **rc resolved into a GLOBAL, not via `$()`** — *because* `die`/`exit 1` inside command substitution
  exits only the subshell; a `rc="$(resolve)"` that "failed" would leave `rc=""` and the script would
  march on to edit an empty/wrong path. Setting `RC_TARGET` in the parent and `die`-ing there is the
  only way the refusal actually halts.
- **Refuse-don't-guess on unknown `$SHELL`** — *because* guessing the wrong rc means the alias is
  written but never loaded (a silent failure the user discovers much later); an explicit `die` +
  `--dotfiles-rc` hint fails loudly instead.
- **Alias value SINGLE-quoted (literal `$HOME`); source line SINGLE-quoted (`${XDG_CONFIG_HOME:-…}`)** —
  *because* both must expand in the USER's shell at use/source time, per-machine, not be frozen to this
  run's environment. Writing them via `printf` with escaped `\$` (or single-quoted args) keeps them
  literal in the file and dodges the backtick-in-quoted-string execution footgun.
- **Name-based overlap guard on the top-level `$HOME` component** — *because* it needs no `CLOUD_ROOT`
  resolution (the dotfiles lane never touches the mount) yet still refuses every managed user-data
  redirect target, CODE/offload container, machine-local dir, and the bare repo itself — keeping the
  dotfiles work-tree to genuine config/state dotfiles and preventing a track from fighting the
  symlink/offload lanes.
- **Adopt deferred** — *because* `dotfiles checkout` on a populated `$HOME` is the one operation that can
  overwrite existing user files; isolating it (with collision→aside + sandbox tests) keeps this slice's
  blast radius to the (reversible, backed-up) rc edit.
```
