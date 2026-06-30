# Slice 1 — Implementation Diff-Spec (lib classification + dispatch skeleton + read-only report)

**Phase:** PACT Architect (light, diff-lock pass) · **Branch:** `feature/home-classification`
**Upstream:** design Task #8, teachback Task #18, plan `docs/plans/home-classification-dotfiles-plan.md`
**Scope:** roadmap steps 1–3 ONLY. ZERO destructive offload/dotfiles/drop logic. Apply-ready for the coder.

> **⚠️ PLAN CORRECTION (read first).** The plan's *schema* section says P2 "removes the
> `projects|Projects|Projects||1` row from `XDG_DIR_REGISTRY`." That is WRONG and would
> break the build. The plan's *roadmap* section is correct: **KEEP the `projects` row in
> `XDG_DIR_REGISTRY`; remove `projects` from `CLOUDXDG_KEYS` ONLY.** Reason: home-tree.sh
> (frozen) derives `SAFE_DIRS` from `HOMETREE_KEYS` (which still contains `projects`) via
> `registry_row "projects"` → field 3. Deleting the registry row makes that derivation
> emit an empty slot → smoke **L3 SAFE_DIRS assertion fails** AND the §6 rclone-filter
> coupling (`+ /Projects/**`) breaks. This spec implements the correct version.

---

## 0. Files touched (slice 1)

| File | Change | Notes |
|---|---|---|
| `bin/lib/xdg-common.sh` | ADD table+keysets+helpers; remove `projects` from one line | Additive + 1 keyset edit |
| `bin/cloud-xdg-provision.sh` | ADD mode dispatch + 2 read-only modes; remove 1 `print_mapping` line | No change to default provision flow |
| `tests/smoke.sh` | L3 golden 9→8 (deliberate same-commit) | SAFE_DIRS assertion UNCHANGED |
| `bin/home-tree.sh` | **UNTOUCHED (frozen)** | — |
| rclone filter heredoc / `HOMETREE_KEYS` | **UNTOUCHED (§6/§7)** | — |

---

## 1. `bin/lib/xdg-common.sh` — exact additions

### 1a. Remove `projects` from `CLOUDXDG_KEYS` (line 93) — the ONLY edit to existing lib content

```diff
-CLOUDXDG_KEYS="desktop documents downloads music pictures videos public templates projects"
+CLOUDXDG_KEYS="desktop documents downloads music pictures videos public templates"
```

**KEEP UNCHANGED:** the `projects|Projects|Projects||1` registry row (line 86), `HOMETREE_KEYS`
(line 106), and the §6 coupling comment. Add this clarifying comment immediately above the
`projects` registry row (line 86):

```sh
# `projects` is CODE-classified for cloud-xdg (P2) and is NOT in CLOUDXDG_KEYS, so it no
# longer enters OFFLOAD_SET / the symlink lane. This row REMAINS because home-tree.sh
# (frozen) still lists `projects` in HOMETREE_KEYS and derives SAFE_DIRS from this row's
# linuxName (field 3); the §6 rclone-filter `+ /Projects/**` coupling depends on it.
```

### 1b. New classification block — append AFTER `xdg_offload_set()` (after line 127)

Declarations-only: a string, two key lists, five functions. No top-level command that can
return non-zero (ADR §4.3 preserved). 3.2-safe; mirrors `registry_row()`/`field()` idioms.

```sh
# ---------------------------------------------------------------------------
# Home-dir classification registry (slice 1) — classes OUTSIDE the XDG-symlink lane.
#   code  : git-managed dirs eligible for rclone offload-on-demand (offloadable=1)
#   local : machine-local dirs that must NEVER offload or symlink (offloadable=0)
#   Schema:  canonical|macName|linuxName|class|offloadable
# SEPARATE from XDG_DIR_REGISTRY by design so xdg_offload_set() + smoke L3 stay
# byte-identical (except the deliberate P2 removal of `projects` from CLOUDXDG_KEYS).
# `projects` is listed here as code AND remains an XDG_DIR_REGISTRY row (home-tree needs
# that row — see line 86). home_class() resolves the overlap to `code` (precedence below).
# ---------------------------------------------------------------------------
HOME_CLASS_REGISTRY="
repos|repos|repos|code|1
androidstudio|AndroidStudioProjects|AndroidStudioProjects|code|1
projects|Projects|Projects|code|1
pyenv|pyenv|pyenv|local|0
applications|Applications|Applications|local|0
syslog|log|log|local|0
qemu|QEMU|QEMU|local|0
"

# Membership + order per new lane (explicit, like CLOUDXDG_KEYS — not registry-scanned).
CODE_KEYS="repos androidstudio projects"
LOCAL_KEYS="pyenv applications syslog qemu"

# Echo the HOME_CLASS_REGISTRY row for a canonical key (or nothing). First match wins.
# Exact structural mirror of registry_row() — proven safe to call inside $( … ).
code_row() {
  printf '%s\n' "$HOME_CLASS_REGISTRY" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      "$1|"*) printf '%s\n' "$line"; break ;;
    esac
  done
}

# Class for ANY canonical key: code|local from HOME_CLASS_REGISTRY (checked FIRST so
# `projects` resolves to code), else xdg if it is an XDG_DIR_REGISTRY row, else unknown.
home_class() {
  local cr xr
  cr="$(code_row "$1")"
  if [ -n "$cr" ]; then field "$cr" 4; return 0; fi
  xr="$(registry_row "$1")"
  if [ -n "$xr" ]; then printf '%s' "xdg"; return 0; fi
  printf '%s' "unknown"
}

# Predicates (for use in `if`; SC2310 is disabled repo-wide in .shellcheckrc).
is_machine_local() { [ "$(home_class "$1")" = "local" ]; }
is_code_dir()      { [ "$(home_class "$1")" = "code" ]; }

# Parameterized rclone-remote precondition (offload lane, later slice). Each script
# wraps it with its own config var + message — do NOT byte-copy home-tree's
# require_rclone (divergent message; dedup rule). True (0) iff rclone present AND a
# remote named "$1" is configured. Body runs only when CALLED (not at source time).
rclone_remote_exists() {
  command -v rclone >/dev/null 2>&1 || return 1
  rclone listremotes 2>/dev/null | grep -qx "$1:"
}
```

**Exact canonical keys + names (per column):**

| canonical | macName | linuxName | class | offloadable |
|---|---|---|---|---|
| `repos` | `repos` | `repos` | code | 1 |
| `androidstudio` | `AndroidStudioProjects` | `AndroidStudioProjects` | code | 1 |
| `projects` | `Projects` | `Projects` | code | 1 |
| `pyenv` | `pyenv` | `pyenv` | local | 0 |
| `applications` | `Applications` | `Applications` | local | 0 |
| `syslog` | `log` | `log` | local | 0 |
| `qemu` | `QEMU` | `QEMU` | local | 0 |

> Canonical `syslog` chosen for the `log` dir to avoid `log` reading like a verb/keyword and
> to keep canonicals unique-prefix-safe for the `case "$1|"*` match. macName/linuxName stay
> the on-disk `log`.

---

## 2. The `projects` removal + the new 8-row L3 golden

### 2a. `xdg_offload_set()` NEW output (the L3 golden) — 8 rows, exact, in order

```
desktop|Desktop|Desktop|XDG_DESKTOP_DIR|1
documents|Documents|Documents|XDG_DOCUMENTS_DIR|1
downloads|Downloads|Downloads|XDG_DOWNLOAD_DIR|1
music|Music|Music|XDG_MUSIC_DIR|1
pictures|Pictures|Pictures|XDG_PICTURES_DIR|1
videos|Movies|Videos|XDG_VIDEOS_DIR|1
public|Public|Public|XDG_PUBLICSHARE_DIR|1
templates|Templates|Templates|XDG_TEMPLATES_DIR|1
```

**Desktop and Documents stay** (user-confirmed). Only `projects` is gone.

### 2b. `tests/smoke.sh` L3 edits (lines 1110–1137)

```diff
-#     the library and assert (a) xdg_offload_set() reproduces cloud-xdg's 9-row
+#     the library and assert (a) xdg_offload_set() reproduces cloud-xdg's 8-row
@@
-echo "smoke: L3 — registry derivation reproduces OFFLOAD_SET (9 rows, order) + SAFE_DIRS"
+echo "smoke: L3 — registry derivation reproduces OFFLOAD_SET (8 rows, order) + SAFE_DIRS"
@@ expected_offload block
   'public|Public|Public|XDG_PUBLICSHARE_DIR|1' \
-  'templates|Templates|Templates|XDG_TEMPLATES_DIR|1' \
-  'projects|Projects|Projects||1')"
+  'templates|Templates|Templates|XDG_TEMPLATES_DIR|1')"
@@
-  ok "xdg_offload_set reproduces the 9-row OFFLOAD_SET in cloud-xdg order"
+  ok "xdg_offload_set reproduces the 8-row OFFLOAD_SET in cloud-xdg order"
```

**DO NOT TOUCH** line 1150 (`SAFE_DIRS` = `Documents Pictures Music Videos Projects Notes`) —
it stays green because the registry row + `HOMETREE_KEYS` are kept. **DO NOT TOUCH** line 367
(`+ /Projects/**` filter).

### 2c. `bin/cloud-xdg-provision.sh` `print_mapping` (line 798) — remove the projects line

```diff
-  projects  (convention)      ~/Projects           -> $CLOUD_ROOT/$(cloud_name projects Projects)
```

(Optional hygiene, not required for green: soften the line-24 header comment "+ a projects
area offload cleanly" since projects no longer offloads via this lane.)

After 1a+2b+2c: `make test` green; `make lint` rc 0.

---

## 3. `~/Projects` symlink-migration sequence (non-destructive)

> **⛔ DEFERRED (lead decision 2026-06-30): do NOT implement in slice 1.** `--migrate-projects`
> is a *mutating* helper (`mkdir`/`rsync`/`mv`); slice 1 is zero-destructive. **Reserve the
> flag INERT** in the dispatch skeleton (§4) alongside the offload/dotfiles flags, and
> implement `cmd_migrate_projects` in the **offload slice**. The algorithm below is the spec
> for that later slice — coder builds it THEN, not now. A pre-existing `~/Projects` symlink
> **keeps working untouched** after the `CLOUDXDG_KEYS` removal (cloud-xdg simply stops
> managing it); migration is only needed when the user later wants it as a local git dir.

**Why (for the later slice):** an existing user who already ran cloud-xdg has `~/Projects` as a
symlink into the cloud mount. To make it a CODE dir it must be restored as a real local dir.
**Never delete user data.**

**Surface (later slice): a dedicated `--migrate-projects` mode** (dry-run default, `--apply`
to act). NOT folded into `--classify` (must stay read-only) and NOT into provision `main`
(surprising). Gate it exactly like `relocate_dir` (dry-run/`--apply`, `guard_not_root`, master
cleanup trap), with sandbox-HOME tests.

**Algorithm (`cmd_migrate_projects`):**

```
localpath = $HOME/Projects            # local_name(Projects,Projects) = Projects both OS
CASE on ~/Projects:
  (a) absent (! -e AND ! -L)          -> info "no ~/Projects to migrate."; return 0
  (b) real directory (-d AND ! -L)    -> info "~/Projects already a local dir."; return 0
  (c) symlink (-L):
        target = readlink ~/Projects
        if target is NOT under the cloud mount (not "$CLOUD_ROOT"/* and not a known
           cloud-provider prefix) OR is dangling:
              warn "leaving foreign/dangling ~/Projects symlink untouched"; return 0
        else (cloud-mount symlink — the P2 case):
           [dry-run prints the plan; --apply does]:
           1. mv ~/Projects  ~/Projects.cloud-symlink.<stamp>   # moves the LINK, not data
                                                                # (uniquify stamp like relocate_dir)
           2. mkdir ~/Projects                                   # fresh real local dir
           3. rsync -a "<target>/" "~/Projects/"  (cp -a fallback)  # pull cloud data local
           4. verify_copy "<target>" "~/Projects" "<copier>"    # reuse existing verifier
                 on mismatch -> die; leave aside symlink + cloud copy intact
           5. info: cloud copy at <target> and link aside at ~/Projects.cloud-symlink.<stamp>
                    are RETAINED — delete only after you confirm ~/Projects is correct.
```

**Invariants:** removing/renaming a symlink never touches its target; the cloud data and the
aside link are always retained; verify before declaring success; `--apply` required to mutate.
Resolving `CLOUD_ROOT` for case (c) reuses `resolve_cloud_root`/`normalize_cloud_root`.

---

## 4. Mode-dispatch skeleton (`bin/cloud-xdg-provision.sh`)

Default (MODE empty) = today's provision flow (`main`, unchanged). Exactly one lane per run.

### 4a. Globals — add near the other flag defaults (after line 75)

```sh
MODE=""          # "" = provision lane (main). Else a subcommand mode (dispatch_mode).
MODE_ARG=""      # argument for value-taking modes (--offload <dir>, etc.)
```

### 4b. `set_mode()` helper — refuse two lanes in one invocation

```sh
set_mode() {
  [ -z "$MODE" ] || die "choose ONE mode per run (already set: --$MODE, then --$1)."
  MODE="$1"
}
```

### 4c. Arg-parse cases — add inside the existing `while`/`case` (lines 266–276)

```sh
    # --- read-only report modes (slice 1, implemented) ---
    --classify)         set_mode classify ;;
    --offload-status)   set_mode offload-status ;;
    # --- reserved lanes (later slices — recognized, INERT in slice 1) ---
    --migrate-projects) set_mode migrate-projects ;;
    --offload)          set_mode offload;  shift; MODE_ARG="${1:?--offload needs a dir}" ;;
    --hydrate)          set_mode hydrate;  shift; MODE_ARG="${1:?--hydrate needs a dir}" ;;
    --dotfiles-init)    set_mode dotfiles-init ;;
    --dotfiles-track)   set_mode dotfiles-track; shift; MODE_ARG="${1:?--dotfiles-track needs a path}" ;;
    --dotfiles-status)  set_mode dotfiles-status ;;
```

### 4d. Dispatch — replace the bare `main` at the bottom (line 864)

```sh
dispatch_mode() {
  case "$MODE" in
    classify)          cmd_classify ;;
    offload-status)    cmd_offload_status ;;
    migrate-projects|offload|hydrate|dotfiles-init|dotfiles-track|dotfiles-status)
        die "mode '--$MODE' is reserved but not implemented in this build (slice 1 = classification + read-only reporting only)." ;;
    *)                 die "internal: unknown mode '$MODE'" ;;
  esac
}

if [ -n "$MODE" ]; then dispatch_mode; else main; fi
```

Read-only modes need NO `acquire_lock`/cloud-root (placing dispatch at file end means
`detect_platform` already ran at line 288; `resolve_cloud_root` runs only inside `main`).
(The deferred `cmd_migrate_projects` will resolve cloud-root itself and arm the trap
`install_cleanup_trap` before mutating — in its later slice, not now.)

### 4e. `usage()` additions — document the two lanes

```
Modes (default with no mode flag = provision/symlink lane above):
  --classify             Report the class of every known ~/ entry (read-only).
  --offload-status       Report which code dirs are offloaded vs local (read-only).
  (reserved, not yet implemented: --migrate-projects/--offload/--hydrate/
   --dotfiles-init/-track/-status)
```

---

## 5. Read-only report contracts (ZERO mutation)

### 5a. `cmd_classify` — classify every known top-level `~/` entry

- **Iterates:** `CLOUDXDG_KEYS` (class xdg), `CODE_KEYS` (class code), `LOCAL_KEYS` (class local).
  (Word-split each list with `# shellcheck disable=SC2086`, like existing loops.)
- **Per canonical:** local name = `local_name "$mac" "$lin"` (mac/lin from the row — XDG via
  `registry_row`, code/local via `code_row`); inspect `$HOME/<name>`:
  - `-L` → `symlink -> <readlink>`  · `-d` (not `-L`) → `local dir`  · else → `absent`.
- **Prints** one aligned line per entry: `<class>  <name>  <state>`, e.g.
  ```
  xdg     Documents     symlink -> /…/My Drive/documents
  code    repos         local dir
  code    projects      symlink -> /…/My Drive/projects   (migrate with --migrate-projects)
  local   pyenv         local dir
  ```
  Append a trailing note: dotfiles handled by the (reserved) dotfiles mode; unlisted `~/`
  entries are unclassified.
- **Writes nothing**: no `mkdir`, `ln`, `rm`, no file creation. `run()` not used. Returns 0.

### 5b. `cmd_offload_status` — code dirs: offloaded vs local

- **State dir (read-only):** `$XDG_STATE_HOME/xdg-cloud/offloaded/<canonical>` (the offload
  lane will WRITE these later; slice 1 only READS). If the dir is absent → treat all as local.
- **Iterates** `CODE_KEYS`; per canonical:
  - state file present → `offloaded -> <remote:dest>` (+ `since <ts>` parsed via
    `grep '^remote=' | cut -d= -f2-` style — same 3.2 idiom).
  - else → `local` (optional read-only hint: `git -C "$HOME/<name>" status --porcelain` empty?
    `clean`/`dirty` — read-only; safe to include or defer).
- **Writes nothing.** Returns 0. (In slice 1 this will report all `local`, validating the
  state-dir read path before any offload exists.)

---

## 6. bash 3.2 / shellcheck notes (binding)

- New `for k in $CODE_KEYS` / `$LOCAL_KEYS` / `$CLOUDXDG_KEYS` loops → `# shellcheck disable=SC2086`.
- `code_row` mirrors `registry_row` (function-defined `case`, safe inside `$( … )`); do NOT
  inline a `case` directly within a `$( … )` (the 3.2 command-subst-case footgun).
- No `[[ ]]`, assoc arrays, `mapfile`, `<()`, `readlink -f`. `readlink` (no `-f`) only on a
  known symlink in case (c).
- Lib stays declarations-only: `rclone_remote_exists` etc. only EXECUTE when called, never at
  source time → `set -euo pipefail` source safety (§4.3) preserved.
- Predicates used in `if` (SC2310 disabled). Command-subst-in-condition (SC2312 disabled).

---

## 7. Build order for the coder (slice 1)

1. Lib §1 (table+keysets+helpers, remove `projects` from `CLOUDXDG_KEYS`). Run `make test` —
   confirm L3 fails ONLY on the expected_offload count (proves the change is isolated).
2. Smoke §2b L3 golden 9→8 + print_mapping §2c. `make test` GREEN, `make lint` rc 0.
3. Dispatch skeleton §4 + `usage()` (all reserved flags — incl `--migrate-projects` — die inert).
4. Read-only `cmd_classify` + `cmd_offload_status` §5.

`cmd_migrate_projects` (§3) is DEFERRED to the offload slice — do NOT build it in slice 1.

---

## 8. Reasoning chain (non-obvious choices)

- **Keep the `projects` registry row, remove from `CLOUDXDG_KEYS` only** — *because*
  `xdg_offload_set` iterates `CLOUDXDG_KEYS` (so removal there alone yields 8 rows) while
  home-tree's frozen `SAFE_DIRS` reads the row via `HOMETREE_KEYS` + the §6 filter coupling
  (so the row must persist). This is the single correct reading; the plan's "delete the row"
  is an error this pass corrects.
- **Separate `HOME_CLASS_REGISTRY`, not a 6th column** — *because* a 6th column makes
  `xdg_offload_set` emit 6-field rows, breaking L3's exact field-count golden; a separate table
  keeps the XDG lane byte-identical save the deliberate `projects` golden.
- **`home_class` checks code/local FIRST** — *because* `projects` is intentionally in BOTH
  tables; precedence resolves it to `code` deterministically.
- **`--migrate-projects` as its own guarded mode, not in `--classify`** — *because* migration
  mutates (mkdir/rsync/mv) and classify must stay zero-mutation; reusing `relocate_dir`'s
  dry-run/`--apply`/trap discipline keeps the data-safety contract.
- **Non-destructive migration (rename link aside, copy back, retain cloud+aside)** — *because*
  the user's data is the cloud copy; we restore a local copy without ever deleting the source,
  mirroring `relocate_dir`'s aside-retain ethic.
- **`rclone_remote_exists` lands in the lib now though unused in slice 1** — *because* it is a
  pure declaration (no source-time cost) and the lead listed it; the offload lane (later slice)
  wraps it per-script to honor the dedup rule.
