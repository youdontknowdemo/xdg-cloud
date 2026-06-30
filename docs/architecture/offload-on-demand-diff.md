# Slice 2 — Offload-on-demand Diff-Spec (steps 4–7, CRITICAL data-loss slice)

**Phase:** PACT Architect (apply-ready diff-lock) · **Branch:** `feature/offload-on-demand`
**Upstream:** design Task #8, teachback Task #31, slice-1 spec `home-classification-slice1-diff.md`,
research `docs/preparation/research-offload-dotfiles-macos.md`.
**Builds on merged slice 1** (commit `8bced8f`): lib `HOME_CLASS_REGISTRY`/`CODE_KEYS`/`LOCAL_KEYS`/
`code_row`/`home_class`/`is_code_dir`/`is_machine_local`/`rclone_remote_exists`; cloud-xdg
`MODE`/`MODE_ARG`/`set_mode`/`dispatch_mode` with `--offload`/`--hydrate`/`--migrate-projects`
**reserved-inert**; `cmd_offload_status` reads `$XDG_STATE_HOME/xdg-cloud/offloaded/<canonical>`
(a FILE) parsing a `remote=` line. **Scope: steps 4–7 only. Dotfiles/brctl (8–9) OUT.**

> **CODE-class dirs NEVER enter `OFFLOAD_SET`.** This is the rclone-REMOTE lane (frees space),
> mutually exclusive from the symlink-into-mount lane. Do NOT touch the rclone filter heredoc,
> `HOMETREE_KEYS`, `XDG_DIR_REGISTRY` rows, `CLOUDXDG_KEYS`, or the slice-1 L3/SAFE_DIRS/§6
> assertions. home-tree.sh FROZEN.

---

## ⚠️ DECISION D-OFFLOAD-GRANULARITY (architect's call; confirm)

**CONFIRMED BY LEAD — Design A "container-unit push + per-repo fail-closed guards + single state
file":** `--offload <container>` discovers every git repo under the container and runs G1–G4 on
EACH; if **all** pass, it pushes the **whole container** as ONE rclone copy, writes ONE state file
`$state_dir/<canonical>` (matches slice-1's existing **state read-contract**), and drops the whole
container. If **any** repo fails, the whole offload is refused (fail-closed) and the blocking repos
are **named** (in both the dry-run plan AND `cmd_offload_status`, §5b) so the user can fix them.
If a CODE canonical is **itself** a single git repo (not a container), it is treated as one repo.
Per-subrepo (partial) offload is **deferred to v2**.

> The state READ-contract is unchanged (one `remote=` file per canonical), so slice-1's reader
> still works; the only slice-1 behavior change is `cmd_offload_status` GAINING per-repo blocker
> lines on the local side (§5b) — a strict output addition, its smoke assertion updated same-commit.

- **Why this over per-repo:** simplest state on the data-loss-critical path; no change to slice-1's
  `cmd_offload_status` reader/tests; faithful restore of non-git loose content too.
- **Cost:** all-or-nothing per container (one dirty repo blocks freeing the container; user
  commits/pushes and retries).

**ALTERNATIVE (Design B, per-repo)** — offload/drop/record each sub-repo independently
(`$state_dir/<canonical>/<repo>`). Finer control / partial offload, BUT requires updating
slice-1's `cmd_offload_status` to read a per-canonical SUBDIR + its smoke test. **Pick B only if
partial-per-repo offload is a v1 must.** This spec writes **Design A'**; switching to B changes
only the state path + status reader (noted inline).

**Other decisions to confirm:** `CODE_DEST` default = `xdg-offload/code`; repo-discovery depth =
**immediate subdirs (depth 1)** (predictable; avoids descending into nested submodules); drop
default = **rm-direct** + opt-in `--aside` (recommend `--aside` when a container holds significant
NON-git loose content — see §6).

---

## 0. Files touched

| File | Change |
|---|---|
| `bin/cloud-xdg-provision.sh` | config + flags; new `OFFLOAD_ACTIVE` trap branch; guards; offload/hydrate/migrate handlers; dispatch wiring; **`cmd_offload_status` enriched to name blocking repos (§5b)** |
| `tests/smoke.sh` | NEW offload coverage (test-engineer owns). L3 / SAFE_DIRS / §6 assertions UNCHANGED. The offload-status **state READ-contract** (`remote=` file per canonical) is unchanged, but its **local-side output gains per-repo blocker lines** (§5b) → its existing output assertion updates accordingly (same commit). |
| `bin/lib/xdg-common.sh` | none (helpers already present) · `bin/home-tree.sh` | UNTOUCHED |

---

## 1. Config + flags (`bin/cloud-xdg-provision.sh`)

Add near the other config defaults (after the `FAST_VERIFY` block, ~line 75), using the existing
`: "${VAR:=default}"` idiom:

```sh
# Code offload-on-demand (rclone REMOTE lane — NOT the cloud mount; only a remote frees space).
: "${CODE_REMOTE:=gdrive}"            # rclone remote name (require 'rclone config' to create it)
: "${CODE_DEST:=xdg-offload/code}"    # path inside the remote; per-container <canonical> appended
OFFLOAD_ASIDE=0                        # 1 = move aside + re-verify before rm (opt-in, --aside)
```

Add to the arg-parse `case` (the existing `while [ $# -gt 0 ]` loop):

```sh
    --code-remote)        shift; CODE_REMOTE="${1:?--code-remote needs a name}" ;;
    --code-dest)          shift; CODE_DEST="${1:?--code-dest needs a path}" ;;
    --aside)              OFFLOAD_ASIDE=1 ;;
```

Add to `usage()` (move offload/hydrate out of the "reserved" note; keep dotfiles reserved):

```
  --offload <dir>        Push a CODE dir to the rclone remote, verify, then free local
                         space (dry-run unless --apply). git = source of truth.
  --hydrate <dir>        Restore a previously offloaded CODE dir from the remote.
  --code-remote NAME     rclone remote for offload (default: gdrive).
  --code-dest PATH       Path inside the remote (default: xdg-offload/code).
  --aside                Offload: move local aside + re-verify before rm (extra safety).
  (reserved, not yet implemented: --dotfiles-init/-track/-status)
```

---

## 2. Trap: new `OFFLOAD_ACTIVE` branch on the SINGLE master handler

bash 3.2 allows ONE handler per signal — do NOT add a separate `trap`. Mirror the `RELOCATE_*`
pattern. Add the flags beside the `RELOCATE_*` block (~line 92):

```sh
# Offload drop-window state (slice 2). Set ACTIVE around the local rm so an interrupt leaves a
# clear recovery message. Unlike relocate, the cloud copy is already read-back-verified AND (for
# git content) the remote is a second net → recovery = re-run --offload (idempotent) or --hydrate.
OFFLOAD_ACTIVE=0
OFFLOAD_SRC=""
OFFLOAD_REMOTE=""
```

Add this branch to `cleanup_handler()` (BEFORE the `LOCK_OWNED` branch; idempotent, resets its flag):

```sh
  if [ "${OFFLOAD_ACTIVE:-0}" -eq 1 ]; then
    warn "INTERRUPTED mid-offload-drop — your data is SAFE:"
    warn "  cloud copy (read-back-verified): '$OFFLOAD_REMOTE'"
    warn "  local '$OFFLOAD_SRC' may be partially removed. Re-run --offload to finish,"
    warn "  or --hydrate to restore it. Delete NOTHING by hand until verified."
    OFFLOAD_ACTIVE=0
  fi
```

`on_signal`/`install_cleanup_trap` are unchanged. **Arming**: mutating modes call `begin_mutating_mode`
(below) which runs `install_cleanup_trap` + `acquire_lock` — same discipline as `main()`.

```sh
# Arm the shared safety machinery for a mutating subcommand mode (offload/hydrate/migrate).
# guard_not_root always; trap before lock (PR#11 order); acquire_lock is apply-only (dry-run no-op).
begin_mutating_mode() { guard_not_root; install_cleanup_trap; acquire_lock; }
```

> **here-doc-not-pipe rule:** any loop that toggles `OFFLOAD_ACTIVE` must run in the PARENT shell
> (so the flag reaches `cleanup_handler`). In Design A' the drop is a single straight-line block in
> `cmd_offload` (no loop around the rm), so this is automatic. If you ever wrap the drop in a loop,
> feed it with a here-doc, never `… | while` (R2 from the slice-1 ADR).

---

## 3. Step 4 — repo discovery + per-repo guards (exact bash-3.2 bodies)

```sh
# Echo the git work tree(s) to act on for a CODE container path. If the container is itself a
# git repo, it is the sole unit; else its immediate subdirs (depth 1) that are git work trees.
# bash-3.2: literal-glob stays literal when unmatched, guarded by [ -d ].
offload_repos_in() {
  local base="$1" d
  if git -C "$base" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s\n' "$base"; return 0
  fi
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 && printf '%s\n' "$d"
  done
}

# G2: clean working tree (no staged/unstaged/untracked).
g2_clean()    { [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ]; }
# G4: no stashes (a clean tree can still hide them; stashes are never pushed).
g4_no_stash() { [ -z "$(git -C "$1" stash list 2>/dev/null)" ]; }

# G3: emit a human line per branch that BLOCKS offload (no upstream, or ahead of upstream).
# Empty output => every local branch is fully pushed. bash-3.2: for-each-ref + while read; @{u}
# resolved with an rc check so a missing upstream is a REFUSAL, never a set -e abort. Pipe→subshell
# is fine here (read-only; we consume the echoed lines, not a flag).
g3_unpushed() {
  local d="$1"
  git -C "$d" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null \
  | while IFS= read -r b; do
      up="$(git -C "$d" rev-parse --abbrev-ref "${b}@{u}" 2>/dev/null || true)"
      if [ -z "$up" ]; then printf '    branch %s has no upstream\n' "$b"; continue; fi
      n="$(git -C "$d" rev-list --count "${b}@{u}..${b}" 2>/dev/null || printf '?')"
      [ "$n" = "0" ] || printf '    branch %s is ahead of %s by %s commit(s)\n' "$b" "$up" "$n"
    done
}

# Aggregate G2/G3/G4 for one repo. Echo blocker lines; empty => safe to drop (after G5 verify).
# (G1 is implied: offload_repos_in only yields git work trees.)
repo_offload_blockers() {
  local d="$1" out=""
  g2_clean    "$d" || out="${out}    uncommitted or untracked changes (git status not clean)
"
  out="${out}$(g3_unpushed "$d")"
  g4_no_stash "$d" || out="${out}
    stashes present (git stash list non-empty)"
  printf '%s' "$out"
}
```

**Dry-run plan (zero mutation):** `cmd_offload` iterates `offload_repos_in`, prints per repo
`would offload: <repo>` or `WOULD BLOCK: <repo>` + its blocker lines, then `would rclone copy
<container> -> <remote:dest>` and `would free local <container>`. Touches nothing.

---

## 4. Step 5 — push + read-back verify + state file

```sh
# cloud-xdg's rclone precondition. Wraps the lib's parameterized rclone_remote_exists() with
# cloud-xdg's CODE_REMOTE + its own message (home-tree keeps its own require_rclone; do NOT
# byte-copy — message + config var diverge, per the dedup rule).
require_code_rclone() {
  rclone_remote_exists "$CODE_REMOTE" && return 0
  die "rclone remote '$CODE_REMOTE:' not available. Install rclone + 'rclone config' to create
  it, or pass --code-remote NAME. Code offload uses an rclone REMOTE (only a remote frees space)."
}

# Write the per-container offload record. key=value lines (parseable via grep+cut — matches
# cmd_offload_status's `remote=` reader). Built with printf, NOT a heredoc, and NO backticks
# anywhere (team footgun: backticks inside a quoted/heredoc string can execute).
write_offload_state() {
  local key="$1" remote="$2" src="$3" sf stamp
  sf="$XDG_STATE_HOME/xdg-cloud/offloaded/$key"
  stamp="$(date +%Y-%m-%dT%H:%M:%S)"
  mkdir -p "$XDG_STATE_HOME/xdg-cloud/offloaded"
  { printf 'remote=%s\n' "$remote"
    printf 'source=%s\n' "$src"
    printf 'offloaded_at=%s\n' "$stamp"; } > "$sf"
}
```

**Push + verify (apply mode; dry-run prints via `run()`):**

```sh
run rclone copy --immutable "$container" "$dest" --progress
# verify is the gate (G5) — read-back proves DURABLE upload, not just a mount-view stat:
if [ "$DRY_RUN" -eq 0 ]; then
  rclone check --download --one-way "$container" "$dest" \
    || die "post-copy read-back verify FAILED for $container -> $dest. Nothing dropped. Retry."
fi
```

`dest="$CODE_REMOTE:$CODE_DEST/$canonical"`. (Design B: `dest=…/$canonical/$repo`, per repo.)

---

## 5. Step 6 — guarded local DROP (the critical window)

```sh
# Inside cmd_offload, AFTER guards pass AND read-back verify rc=0 AND state recorded:
[ "$DRY_RUN" -eq 0 ] || { info "[dry-run] would free local: $container"; return 0; }

# DATA-LOSS GUARD (SC2115): never rm a degenerate path.
case "$container" in
  ""|"/"|"$HOME") die "internal: refusing rm of unsafe path '$container'" ;;
esac
[ -n "$(ls -A "$container" 2>/dev/null)" ] || { warn "$container already empty; nothing to drop."; return 0; }

OFFLOAD_ACTIVE=1; OFFLOAD_SRC="$container"; OFFLOAD_REMOTE="$dest"
if [ "$OFFLOAD_ASIDE" -eq 1 ]; then
  stamp="$(date +%Y%m%d-%H%M%S)"; aside="${container}.pre-offload-${stamp}"
  n=1; while [ -e "$aside" ] || [ -L "$aside" ]; do aside="${container}.pre-offload-${stamp}.${n}"; n=$((n+1)); done
  mv "$container" "$aside"
  # re-verify the aside still matches the remote, then rm it:
  rclone check --download --one-way "$aside" "$dest" \
    || die "re-verify of aside vs remote FAILED — kept '$aside', dropped nothing else."
  rm -rf "$aside"
else
  rm -rf "$container"
fi
OFFLOAD_ACTIVE=0
info "Offloaded $container -> $dest. Restore with: $SELF --hydrate <dir> --apply"
```

**Warn on non-git / untracked-precious content** before the drop: any file under `$container`
NOT inside a discovered git repo has only the (verified) cloud copy as its backstop — no git net.
Emit a warning + recommend `--aside` for such containers. NEVER drop on copy-phase success alone
(the `rclone copy` rc is not enough — the independent `check --download` is the gate).

**Prominent regenerable-dir warning (lead-confirmed; v1 = copy faithfully, do NOT exclude).**
Before the push, scan for well-known large regenerable dirs and warn loudly so the user
understands the push SIZE and that offload still frees local space:

```sh
# Detect regenerable build dirs in the push (faithful copy in v1 — exclude-filters DEFERRED to v2).
warn_regenerable() {
  local base="$1" hit
  hit="$(find "$base" \( -name node_modules -o -name .gradle -o -name build -o -name __pycache__ \) \
          -type d -prune -print 2>/dev/null | head -n 20)"
  [ -z "$hit" ] && return 0
  warn "large regenerable dirs are INCLUDED in this push (v1 copies them faithfully — no filter yet):"
  printf '%s\n' "$hit" | sed 's/^/    /' >&2
  warn "  This inflates upload size/quota, but offload STILL frees the local space. A v2 rclone"
  warn "  exclude-filter will skip these. Use --aside if you want a local safety copy first."
}
```

Call `warn_regenerable "$container"` in both the dry-run plan and the apply path (before push).
**v2 note:** an rclone `--filter`/`--exclude` pass for `node_modules`/`.gradle`/`build`/`__pycache__`
(mirroring home-tree's filter ethos) is deferred — record it as a v2 follow-up, not built now.

---

## 5b. `cmd_offload_status` enrichment — name blocking repos (lead-confirmed)

Slice-1's `cmd_offload_status` reports each code dir as `offloaded -> <remote>` (state file present)
or `local (git: clean/dirty/absent)`. Enrich the **local** branch so a container that CANNOT be
offloaded names exactly which sub-repo blocks it (same info the dry-run shows) — so the user can fix
it without running `--offload`. **State READ-contract is unchanged** (still `[ -f "$state_dir/<canonical>" ]`
+ `remote=`); this only adds output on the local branch.

```sh
# Inside cmd_offload_status, in the `else` (local) branch, AFTER the existing git-hint line, when
# the dir exists: list any blocking repos (reuses the offload guards — read-only).
if [ -d "$target" ]; then
  for r in $(offload_repos_in "$target"); do          # shellcheck disable=SC2046,SC2086
    blk="$(repo_offload_blockers "$r")"
    [ -n "$blk" ] && { printf '%-6s %-22s %s\n' "" "" "blocked: $r"; printf '%s\n' "$blk" >&2; }
  done
fi
```

> bash-3.2 note: `for r in $(offload_repos_in …)` word-splits the newline list (paths assumed
> space-free for code dirs; if a path could contain spaces, switch to a `while IFS= read -r r`
> here-doc fed by the function output). Keep this read-only — no mutation in status.

The smoke assertion for `cmd_offload_status` updates same-commit to expect the new `blocked: <repo>`
lines when a sub-repo is dirty/unpushed. The `offloaded`/`local` lines and the state-file read path
are otherwise unchanged.

---

## 6. Step 7 — `--hydrate` (sentinel) + dispatch wiring

```sh
cmd_hydrate() {              # $1 = MODE_ARG (dir: canonical or local name)
  begin_mutating_mode
  # resolve canonical key + container path (see §7 resolver); refuse non-CODE-class.
  local sf sentinel remote
  sf="$XDG_STATE_HOME/xdg-cloud/offloaded/$canonical"
  [ -f "$sf" ] || die "$container is not recorded as offloaded (no $sf)."
  sentinel="$sf.hydrating"
  [ -f "$sentinel" ] && warn "a previous hydrate of $canonical was interrupted; re-running."
  remote="$(grep '^remote=' "$sf" 2>/dev/null | cut -d= -f2- || true)"
  [ -n "$remote" ] || die "state file $sf has no remote= line; refusing."
  # refuse to clobber an existing non-empty local dir:
  if [ -e "$container" ] && [ -n "$(ls -A "$container" 2>/dev/null)" ]; then
    die "$container exists and is non-empty; refusing to overwrite. Move it aside first."
  fi
  [ "$DRY_RUN" -eq 0 ] || { info "[dry-run] would hydrate $container from $remote"; return 0; }
  : > "$sentinel"                                   # mark BEFORE pull
  run rclone copy --checksum "$remote" "$container" --progress
  rclone check --download --one-way "$remote" "$container" \
    || die "post-pull verify FAILED — left sentinel '$sentinel'; re-run --hydrate."
  rm -f "$sentinel"; rm -f "$sf"                    # clear ONLY on verified success
  info "Hydrated $container from $remote."
  info "Alt for fully-pushed repos: 'git clone <remote-url>' is the canonical, self-verifying restore."
}
```

**Dispatch wiring** — replace the reserved-die line so offload/hydrate/migrate are LIVE; keep
dotfiles reserved:

```sh
dispatch_mode() {
  case "$MODE" in
    classify)         cmd_classify ;;
    offload-status)   cmd_offload_status ;;
    offload)          cmd_offload   "$MODE_ARG" ;;
    hydrate)          cmd_hydrate   "$MODE_ARG" ;;
    migrate-projects) cmd_migrate_projects ;;
    dotfiles-init|dotfiles-track|dotfiles-status)
        die "mode '--$MODE' is reserved but not implemented in this build (dotfiles = a later slice)." ;;
    *)                die "internal: unknown mode '$MODE'" ;;
  esac
}
```

`cmd_offload`/`cmd_hydrate` call `begin_mutating_mode` first and use `require_code_rclone`; they do
NOT call `resolve_cloud_root` (remote lane). `cmd_migrate_projects` (algorithm in the slice-1 spec
§3) calls `begin_mutating_mode` AND `resolve_cloud_root`/`normalize_cloud_root` (it inspects the
mount symlink). `--offload-status` stays read-only (no `begin_mutating_mode`).

---

## 7. Arg resolver + safety refusals (shared by offload/hydrate)

```sh
# Resolve MODE_ARG (a canonical key OR a platform local name) to (canonical, container path).
# REFUSE anything not CODE-class — this is the venv/machine-local data-loss guard.
resolve_code_target() {        # sets globals: canonical, container
  local arg="$1" k nm
  canonical=""; container=""
  for k in $CODE_KEYS; do                                   # shellcheck disable=SC2086
    nm="$(local_name "$(field "$(code_row "$k")" 2)" "$(field "$(code_row "$k")" 3)")"
    if [ "$arg" = "$k" ] || [ "$arg" = "$nm" ]; then canonical="$k"; container="$HOME/$nm"; return 0; fi
  done
  is_machine_local "$arg" && die "$arg is machine-local (never offloads — venvs/abs-paths break)."
  die "$arg is not a known CODE dir (offload-eligible: $CODE_KEYS). Refusing."
}
```

This refuses XDG dirs, machine-local dirs (Pyenv etc.), and arbitrary paths — only registered
CODE-class containers can be offloaded.

---

## 8. bash 3.2 / shellcheck / footguns (binding)

- `for k in $CODE_KEYS` → `# shellcheck disable=SC2086`.
- `rm -rf "$container"` guarded by the `case ""|"/"|"$HOME"` refusal (SC2115 / data-loss).
- `@{u}` resolution rc-guarded in `g3_unpushed` (no `set -e` abort on a no-upstream branch).
- Repo-discovery glob `"$base"/*/` is literal-when-unmatched; `[ -d ]` guards it.
- No backticks inside any quoted string / heredoc (team footgun — they execute at parse/source);
  state file built with `printf`, messages via `warn`/`info` single args.
- No `[[ ]]`, assoc arrays, `mapfile`, `<()`, `readlink -f`. New `case` only inside function bodies.
- Modes that mutate arm `begin_mutating_mode` (guard_not_root + trap + apply-only lock).

---

## 9. Build order (coder)

1. Config + flags + `usage()` (§1). `make test` still green (no behavior change yet).
2. Trap flags + `cleanup_handler` branch + `begin_mutating_mode` (§2).
3. Guards + `offload_repos_in` + `resolve_code_target` (§3, §7) — pure, dry-run plan only.
4. `require_code_rclone` + push + `check --download` verify + `write_offload_state` (§4).
5. Guarded DROP (§5) — apply-only, trap-protected, rm-safety guard, `--aside`.
6. `cmd_hydrate` + sentinel (§6).
7. Dispatch wiring (offload/hydrate/migrate LIVE; dotfiles still reserved) (§6) + wire `cmd_migrate_projects` (slice-1 §3 algorithm).
8. Hand to test-engineer: real-rclone→`type=local` remote for happy path; PATH-shim rclone for
   verify-fail injection; sandbox-HOME + in-sandbox target guard for every drop test (never real `$HOME`).

---

## 10. Reasoning chain (drop-safety + trap design)

- **Drop is gated on an INDEPENDENT read-back verify, not the copy rc** — *because* `rclone copy`
  succeeding only proves the upload was *attempted*; `rclone check --download --one-way` re-reads
  every byte from the provider, proving DURABLE presence (the exact gap `verify_copy` warns about
  for the mount lane). Only after that + the git guards is local deletion safe.
- **Per-repo G2/G3/G4 + container-unit push (Design A')** — *because* git is the source of truth
  per repo (clean+pushed+no-stash ⇒ `git clone` can fully reconstruct it), so the guards must be
  per-repo; but the offload UNIT stays the container to match slice-1's one-file-per-canonical
  reader and keep the critical path's state model trivial. Non-git loose content has only the
  verified cloud copy as a net → warn + recommend `--aside`.
- **Single master `cleanup_handler` + `OFFLOAD_ACTIVE` flag, never a second trap** — *because*
  bash 3.2 has no trap stacking; a separate `trap` would clobber the lock/relocate/probe handlers.
  The drop block is straight-line in the parent shell, so the flag the handler reads is always in
  scope (the here-doc-not-pipe rule, R2).
- **State written BEFORE the drop; rm-safety `case` refusal; `--aside` re-verify** — *because* an
  interrupt mid-rm must leave a recoverable, correctly-reported state (status shows offloaded,
  re-run finishes), and a degenerate `$container` must never reach `rm -rf`.
- **`--hydrate` sets a sentinel before pulling, clears it only on a passing post-pull verify** —
  *because* a crashed hydrate would otherwise look complete; the lingering sentinel makes the
  interrupted state self-detecting on the next run.
- **Refuse non-CODE targets (`resolve_code_target`)** — *because* offloading a venv/abs-path or a
  machine-local dir would re-hydrate broken; the classifier's `local` class is the guard.

---

## 11. Decisions — RESOLVED (lead-confirmed 2026-06-30)

- [x] **D-OFFLOAD-GRANULARITY = Design A** (container-unit push, one state file per canonical,
  per-repo fail-closed guards; refuse whole offload if any repo blocks; name the blockers in dry-run
  AND `cmd_offload_status`; a single-git-repo canonical is treated as one repo). Per-subrepo = v2.
- [x] **Regenerable content** = copy faithfully in v1 + **prominent warning** (§5, `warn_regenerable`);
  rclone exclude-filters DEFERRED to **v2**.
- [x] `CODE_DEST` default = `xdg-offload/code`.
- [x] Repo-discovery depth = immediate subdirs (depth 1); container-or-self handled.
- [x] Drop default = rm-direct + opt-in `--aside` (recommend `--aside` when a container holds large
  regenerable/non-git loose content).

### Deferred to v2 (record, do NOT build now)
- Per-subrepo (partial) offload + per-repo state records.
- rclone `--exclude`/`--filter` for `node_modules`/`.gradle`/`build`/`__pycache__`.
- iCloud `brctl evict/download` true-offload sub-mode (steps 8–9, separate slice).
