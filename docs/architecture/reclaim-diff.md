# `--reclaim` Architecture Spec (step 10 — regenerable build-artifact sweep)

**Phase:** PACT Architect (as-built) · **Branch:** merged to `main` via PR #30 (squash `39388c3`)
**Upstream:** PREPARE research `docs/preparation/research-reclaim.md` (commit `239a3ab`).
**Counterpart:** `--offload` (`offload-on-demand-diff.md`) — but `--reclaim` has **no cloud lane**.

> **As-built note.** This document was written *after* the feature shipped (commits `6319ffc`
> feat + `7e36994` review-harden), reverse-documented from the merged `cmd_reclaim()` and its
> helpers in `bin/cloud-xdg-provision.sh`. It records the design that landed, not a pre-code plan.
> The line numbers below refer to the merged file.

---

## 0. What `--reclaim` is (and how it differs from `--offload`)

`--reclaim [PATH]` is the **delete-side** counterpart to `--offload`. It purges
**known-regenerable** build/cache artifacts (Rust `target/`, `node_modules`, Gradle/Maven/CMake
build output, `__pycache__` + Python tool caches, `*.egg-info`, framework caches) to free disk,
plus an opt-in fixed allow-list of global user caches.

The critical difference: **`--offload` uploads-then-verifies-then-drops** (a durable cloud copy is
the safety net). `--reclaim` has **no net** — it just deletes. So the *entire* design rests on
**false-positive-safe detection**: it must never delete a real, non-regenerable, or tracked dir.
The governing rule (research §2):

> A candidate is reclaimable only if **anchored by a sibling toolchain manifest** proving it is
> build output, **and** (for generic/ambiguous names) it is **git-ignored/untracked**. Anything
> **tracked** is never touched. Generic names (`build`/`dist`/`out`) with no manifest → never.
> Outside a git repo → only tool-native-authoritative anchors or pure-bytecode names. When in
> doubt → **exclude**.

---

## 1. Files touched

| File | Change |
|---|---|
| `bin/cloud-xdg-provision.sh` | config (`RECLAIM_GLOBAL`/`RECLAIM_ROOT`); `--reclaim [PATH]` + `--global` flags + `usage()`; the `reclaim_*` helper block (§4); `cmd_reclaim` (§3); dispatch wiring (§7) |
| `tests/smoke.sh` | R1–R4 reclaim coverage (test-engineer): dry-run classification, apply-deletes-decoys-survive, degenerate-root refusal, symlinked-manifest refusal. Sandboxed `HOME` + sandbox root — never real `$HOME` |
| `docs/preparation/research-reclaim.md` | the PREPARE research this spec implements |
| `bin/lib/xdg-common.sh` · `bin/home-tree.sh` | **untouched** (no new shared helpers needed) |

---

## 2. Config + flags

Config defaults (`bin/cloud-xdg-provision.sh` ~L101-104):

```sh
# Reclaim (step 10) — DELETE-side sweep of regenerable build artifacts (counterpart to
# --offload). dry-run default; --apply acts; --global also sweeps the fixed cache
# allow-list. RECLAIM_ROOT is set by cmd_reclaim + read by reclaim_rm's guard.
RECLAIM_GLOBAL=0
RECLAIM_ROOT=""
```

Arg-parse (~L454-457) — **root is OPTIONAL** (unlike the offload/hydrate `${1:?…}` required-arg
modes). The next token is consumed as the root only if it is not a flag:

```sh
    --reclaim)            set_mode reclaim
                          # optional root path: consume the next arg only if it's not a flag
                          if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then shift; MODE_ARG="$1"; fi ;;
    --global)             RECLAIM_GLOBAL=1 ;;
```

`usage()` (~L390-398):

```
  --reclaim [PATH]          Sweep PATH (default: cwd) for build artifacts (Rust target/,
                            node_modules, Gradle/Maven/CMake build, __pycache__, …) and
                            DELETE the regenerable ones (dry-run unless --apply). Tool-native
                            clean (cargo/mvn/gradle) preferred; guarded rm fallback.
  --global                  Also sweep the fixed user-cache allow-list (Homebrew, npm,
                            pip, Xcode DerivedData, ~/.gradle/caches).
```

---

## 3. Trap posture — NO new `RECLAIM_ACTIVE` flag (deliberate)

`cmd_reclaim` calls `begin_mutating_mode` (`guard_not_root` + `install_cleanup_trap` +
apply-only `acquire_lock`) like every mutating mode. But — unlike `--offload`/`--relocate`/
`--migrate-projects` — it adds **no** `RECLAIM_ACTIVE` branch to `cleanup_handler`.

**Why:** an interrupt mid-reclaim leaves some artifacts deleted and some not. Every deleted item
is **regenerable by definition** (that is the whole admission criterion), so a half-finished sweep
is *harmless*: rebuild regenerates it, and re-running `--reclaim` is idempotent (already-gone dirs
simply aren't rediscovered). There is no recoverable-but-confusing half-state to explain, so no
recovery message is warranted. The lock still releases on every exit path via the existing
`LOCK_OWNED` branch. This is the key trap-design divergence from the data-loss-critical offload lane.

---

## 4. The detection helpers (exact merged bodies)

### 4.1 Size + git predicates (fail-closed)

```sh
reclaim_size() { du -sh "$1" 2>/dev/null | cut -f1 || printf '?'; }

reclaim_in_repo()    { git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; }

# Returns 0 (tracked -> DON'T delete) for a match AND for ANY git error; returns 1
# (not tracked) ONLY on the specific exit 1 that ls-files uses for a genuine no-match.
# Fail-closed: a corrupt index / lock / abnormal git state (exit 128) is NEVER read as
# "not tracked".  [7e36994 review hardening]
reclaim_is_tracked() {
  local rc
  git -C "$2" ls-files --error-unmatch -- "$1" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && return 1   # exit 1 == clean no-match -> not tracked
  return 0                      # exit 0 (tracked) or any other (error) -> treat as tracked (safe)
}
reclaim_is_ignored() { git -C "$2" check-ignore -q -- "$1" >/dev/null 2>&1; }
```

The **fail-closed** direction is the load-bearing choice: every predicate resolves any error to the
**non-deleting** answer (in-repo→false, tracked→true, ignored→false). A garbled git state can only
ever *protect* a dir, never expose it.

### 4.2 Manifest + anchor (symlinked-manifest rejection)

```sh
# A manifest must be a REGULAR, non-symlink file — a symlinked Cargo.toml/package.json must
# not qualify an out-of-tree dir for deletion nor aim tool-native clean at an attacker-chosen
# project.  [7e36994 review hardening; smoke R4]
reclaim_manifest() { [ -f "$1/$2" ] && [ ! -L "$1/$2" ]; }

# reclaim_anchor NAME PARENT -> echoes the toolchain kind if PARENT holds an anchoring
# manifest for a candidate named NAME (else empty). Always returns 0.
reclaim_anchor() {
  local name="$1" p="$2"
  case "$name" in
    target)
      if   reclaim_manifest "$p" Cargo.toml; then printf 'cargo'
      elif reclaim_manifest "$p" pom.xml;    then printf 'maven'; fi ;;
    node_modules|.next|.nuxt|.svelte-kit|.turbo)
      reclaim_manifest "$p" package.json && printf 'node' ;;
    build|dist|out)
      if   reclaim_manifest "$p" package.json;   then printf 'node'
      elif reclaim_manifest "$p" build.gradle || reclaim_manifest "$p" build.gradle.kts; then printf 'gradle'
      elif reclaim_manifest "$p" pyproject.toml || reclaim_manifest "$p" setup.py; then printf 'py'
      elif reclaim_manifest "$p" CMakeLists.txt; then printf 'cmake'; fi ;;
  esac
  return 0
}
```

### 4.3 Guarded delete + tool-native clean

```sh
# Degenerate-path refusal (mirror the offload guard) then rm -rf. RECLAIM_ROOT is refused
# too, so the sweep root itself can never be the rm target.
reclaim_rm() {
  local d="$1"
  case "$d" in
    ""|"/"|"$HOME"|"$RECLAIM_ROOT") die "internal: refusing rm of unsafe path '$d'" ;;
    *..*)                           die "internal: refusing rm of path with '..': '$d'" ;;
  esac
  printf '  [run]     rm -rf %q\n' "$d"
  rm -rf "$d" || warn "  rm failed for $d (left as-is)"
  return 0
}

# Tool-native clean inside a project dir. Returns 1 if the tool is ABSENT (caller falls
# back to guarded rm); 0 if it ran (or the clean errored — warned, left as-is). The `cd`
# bounds the blast radius to that one project (cargo clean touches only its own target/).
reclaim_toolclean() {
  local dir="$1"; shift
  command -v "$1" >/dev/null 2>&1 || return 1
  printf '  [run]     (cd %q &&' "$dir"; printf ' %q' "$@"; printf ')\n'
  ( cd "$dir" 2>/dev/null && "$@" >/dev/null 2>&1 ) || warn "  $* failed in $dir (left as-is)"
  return 0
}

# Gradle: prefer ./gradlew, then gradle, else (in-repo anchored+ignored) guarded rm.
reclaim_gradle_clean() {
  local p="$1" d="$2"
  if [ -x "$p/gradlew" ]; then
    printf '  [run]     (cd %q && ./gradlew clean)\n' "$p"
    ( cd "$p" 2>/dev/null && ./gradlew -q clean >/dev/null 2>&1 ) || warn "  gradlew clean failed in $p"
    return 0
  fi
  reclaim_toolclean "$p" gradle -q clean && return 0
  reclaim_rm "$d"
}
```

---

## 5. `cmd_reclaim` — the sweep (algorithm)

### 5.1 Root resolution + refusal (~L2037-2043)

```sh
root="${1:-$PWD}"
[ -d "$root" ] || die "reclaim root does not exist: $root"
rootreal="$(cd "$root" 2>/dev/null && pwd -P)" || die "cannot resolve reclaim root: $root"
case "$rootreal" in
  ""|"/"|"$HOME") die "refusing to sweep '$rootreal' (too broad — never a blind \$HOME/root walk). Pass a project or dev dir." ;;
esac
RECLAIM_ROOT="$rootreal"
```

**Decisions locked here:** default root = **cwd** (`$PWD`); an implicit `/` or `$HOME` is
**refused** (there is never a blind home walk). `pwd -P` canonicalizes (no `realpath -f` on macOS
bash 3.2).

### 5.2 Discovery (~L2050-2054)

```sh
tf="$(mktemp "${TMPDIR:-/tmp}/xdg-reclaim.XXXXXX")" || die "cannot create temp file"
find "$rootreal" -type d \( -name target -o -name node_modules -o -name __pycache__ \
    -o -name .pytest_cache -o -name .mypy_cache -o -name .ruff_cache -o -name '*.egg-info' \
    -o -name .next -o -name .nuxt -o -name .svelte-kit -o -name .turbo \
    -o -name build -o -name dist -o -name out \) -print0 > "$tf" 2>/dev/null || true
```

- `-type d` (no `-L`) → **symlinks are never enumerated or followed** (a symlinked `node_modules`
  → real code elsewhere is `-type l`, invisible to the walk).
- NUL-delimited into a **tempfile**, read back with `while IFS= read -r -d '' cand < "$tf"` in the
  **parent shell** (redirect, not a pipe) — so the `accepted[]` array accumulates in scope (the
  here-doc-not-pipe / R2 discipline). A pipe would run the loop in a subshell and lose the array.

### 5.3 Per-candidate gates (~L2058-2113)

For each candidate, in order:

1. **Canonicalize + under-root**: `cr="$(cd "$cand" && pwd -P)"`; `case "$cr" in "$rootreal"/*) …` —
   anything not strictly under the resolved root is skipped (no-ascend guard).
2. **Stop-descend**: skip if `cr` is inside an already-`accepted` match (find lists parents before
   children, so a matched `node_modules` is accepted first and its contents pruned).
3. **Classify** via `reclaim_anchor` + a per-name `case`:

| Candidate name | Rule → decision |
|---|---|
| `__pycache__` `.pytest_cache` `.mypy_cache` `.ruff_cache` `*.egg-info` | unambiguous name → `rm` |
| `target` | `Cargo.toml`→`cargo` · `pom.xml`→`maven` · else skip |
| `node_modules` | inner `.git`→skip (checked-out dep) · `package.json`→`rm` · else skip |
| `.next` `.nuxt` `.svelte-kit` `.turbo` | `package.json`→`rm` · else skip |
| `build` `dist` `out` | **require** manifest **AND** in-repo **AND** not-tracked **AND** git-ignored, then: gradle→`gradle` · cmake+`CMakeCache.txt`→`rm` · else (node/py)→`rm` |

4. **Belt-and-suspenders tracked check** (~L2097-2099): even an unambiguous name, if in-repo AND
   tracked, is downgraded to skip (`"$base is git-tracked"`).
5. **Outside-a-repo tier gate** (~L2104-2113): if the candidate is **not** in a git repo, only
   - pure-bytecode/cache names (`__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `*.egg-info`), or
   - `target/` when its `cargo`/`maven` tool is actually **present** (tool-native-authoritative)

   survive; everything else (`node_modules`, `.next`, generic) is refused. (Generic names never
   reach here with a decision — they already required in-repo above.)

### 5.4 Plan + delete (~L2115-2142)

Accepted candidates are appended to `accepted[]`, sized with `reclaim_size`, and added to a printed
`plan` (`reclaim [decision]  <size>  <path>` / `skip  -  <path>  (<why>)`). Deletion happens
**only** when `DRY_RUN=0`, dispatched by decision:

```sh
cargo)  reclaim_toolclean "$parent" cargo clean || reclaim_rm "$cand" ;;
maven)  reclaim_toolclean "$parent" mvn -q clean || reclaim_rm "$cand" ;;
gradle) reclaim_gradle_clean "$parent" "$cand" ;;
rm)     reclaim_rm "$cand" ;;
```

Then, if `--global`, `reclaim_global_caches` runs. Finally the plan prints; dry-run reports the
count + the `--global` hint, apply reports the reclaimed count.

---

## 6. Global caches (opt-in `--global`) — fixed allow-list, never tree-walked (~L2012-2032)

```sh
reclaim_global_caches() {
  # brew cleanup -s · npm cache clean --force · pip3 cache purge  (tool-native, bounded)
  # rm -rf ~/Library/Developer/Xcode/DerivedData/*   (hardcoded literal, ${dd:?} guard)
  # rm -rf ~/.gradle/caches                          (hardcoded literal, ${gc:?} guard)
}
```

These are **fixed known paths**, never discovered by the walk, and gated purely behind `--global`.
Tool-native where a self-healing command exists (`brew`/`npm`/`pip`); guarded literal `rm` for the
pure-artifact dirs. Download caches (`~/.m2`, cargo registry, go modcache) and Xcode `Archives` are
**excluded** per research §5 (slow re-fetch / shippable builds).

---

## 7. Dispatch wiring (~L2159)

```sh
dispatch_mode() {
  case "$MODE" in
    …
    reclaim)          cmd_reclaim         "$MODE_ARG" ;;
    *)                die "internal: unknown mode '$MODE'" ;;
  esac
}
```

---

## 8. bash 3.2 / shellcheck / footguns (binding)

- `set -euo pipefail` is active → the accepted-array is expanded empty-safe as
  `${accepted[@]+"${accepted[@]}"}` (a bare `"${accepted[@]}"` would trip `set -u` when empty).
- Every `rm -rf` routes through `reclaim_rm`'s degenerate-path `case` refusal (SC2115 / data-loss).
- No backticks anywhere (team footgun — they execute inside quoted strings/heredocs); plan built
  with `printf`/string concat, messages via `log`/`info`/`warn` single args.
- No `[[ ]]`, assoc arrays beyond the indexed `accepted[]`, `mapfile`, `<()`, or `readlink -f`.
- The discovery loop reads a NUL tempfile via **redirect** (parent shell), never a pipe.
- `find … -print0 … || true` and `du … || printf '?'` keep partial-permission failures from
  aborting under `set -e`.

---

## 9. Reasoning chain (why the design is safe)

- **Detection is the only net, so it is fail-closed at every predicate** — *because* there is no
  cloud copy to fall back on (the offload lane's `rclone check --download` gate has no analogue
  here). `reclaim_in_repo`/`is_tracked`/`is_ignored` resolve every error to the non-deleting
  answer, so a corrupt/locked git state can only ever protect a dir.
- **Tiered by name-ambiguity** — *because* `target/`+`Cargo.toml` is intrinsically build output,
  but `build/` is also a common source-dir name; the generic tier therefore demands anchor **and**
  git-ignored **and** in-repo **and** not-tracked, making a false positive require several
  independent coincidences.
- **Outside-a-repo, trust only the toolchain or the name** — *because* without a `git check-ignore`
  signal we cannot prove disposability, *except* where `cargo`/`mvn clean` bounds its own blast
  radius (tool-native-authoritative) or the name is intrinsically bytecode (`__pycache__`).
  A lone `node_modules` in `/tmp` is "almost certainly" disposable — but that is not the bar for an
  irreversible `rm`, so it is refused.
- **Tool-native preferred over `rm`** — *because* `cargo`/`mvn`/`gradle clean` know their own layout
  and touch only that project's output; `rm` is the guarded fallback (tool absent, or in-repo
  anchored+ignored).
- **No recovery trap** — *because* a half-finished sweep of regenerable dirs is harmless and
  idempotently re-runnable; there is no confusing half-state to narrate (contrast the offload/
  relocate/migrate windows, which do arm recovery messages).
- **Symlinked manifests rejected; symlinks never walked; root refused as an rm target** — *because*
  an attacker (or an accidental link) must not be able to steer classification or `cargo clean`
  toward an out-of-tree or precious directory.

---

## 10. Decisions — RESOLVED (as shipped)

- [x] **Default root = cwd** (`$PWD`); implicit `/` or `$HOME` **refused**. No blind home walk.
- [x] **Global caches = opt-in `--global`**, a fixed allow-list, never tree-discovered.
- [x] **Tool-native clean preferred** (`cargo`/`mvn`/`gradle clean`); guarded `rm` fallback.
- [x] **`--apply` alone gates the delete** — no extra `--yes`/consent flag. The detection model
  guarantees only regenerable artifacts are ever admitted, so `--apply` (the repo-wide safe-by-
  default gate) is sufficient. (Contrast `--icloud-evict`, which needs
  `--i-understand-data-loss-risk` precisely because it has no equivalent detection guarantee.)
- [x] **`.venv`/`venv`, `vendor/`, Xcode `Archives`, download caches = excluded** (research §5).

### Known limitations / v2 candidates (non-blocking; recorded, not built)

- **`--global` without `--reclaim`** is a silent no-op (the flag is only read inside `cmd_reclaim`).
  A stray `--global` could warn instead of doing nothing.
- **Global-cache deletes** (`DerivedData/*`, `~/.gradle/caches`) use hardcoded literals with
  `${:?}` guards but bypass `reclaim_rm`'s `case` guard — low risk, but routing them through a
  guarded helper would unify the discipline.
- **Dry-run plan** shows the decision tag (`[cargo]`) but not the literal `cargo clean` line it
  would run — cosmetic.
- **CMake `build/`** additionally requires git-ignored (stricter than research §1's marker-only
  rule) — a safe, conservative choice that may skip a non-ignored out-of-source build dir.
- **`.venv`/pnpm/yarn store** opt-in reclaim (research §5 / uncertainties) — deferred.

---

## 11. Test coverage (`tests/smoke.sh`, sandboxed)

| Test | Asserts |
|---|---|
| **R1** dry-run | classifies 3 reclaimable dirs, marks `rm` decisions, deletes nothing; decoys (unanchored `build/`, tracked `build/`, `node_modules` with inner `.git`, loose `node_modules`) all skipped and untouched |
| **R2** apply | reclaimable deleted (`__pycache__`, gitignored+anchored `build/`, in-repo `node_modules`), all decoys survive, tracked siblings intact |
| **R3** refusals | `/` refused (too broad) with explanatory message; nonexistent root refused |
| **R4** symlink | a symlinked `Cargo.toml` does **not** anchor `target/` (0 reclaimable; dir untouched) |

All R1–R4 run in a sandbox (`tests/sandbox/`) with `HOME` and the reclaim root overridden — never
the real `$HOME`. Full suite green (34 reclaim assertions).
