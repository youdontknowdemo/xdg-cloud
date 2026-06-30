# Architecture — Shared Library + Unified Dir Registry (Issues #2 / #3)

**Phase:** PACT Architect · **Author:** pact-architect · **Date:** 2026-06-30
**Branch:** `feature/shared-lib-dedup` (in-place, NOT a worktree)
**Upstream:** PREPARE brief `docs/preparation/xdg-cloud.md`; TEACHBACK Task #6 (accepted)
**Implements:** one coherent, behavior-preserving refactor by a single coder.

> **Prime directive — this is a NO-BEHAVIOR-CHANGE refactor.** Both scripts just
> passed an intense data-safety review. The acceptance gate is byte-identical
> output (golden diff) **and** both full smoke suites passing **unchanged**.
> When in doubt, do NOT extract. Conservative dedup beats clever unification.

---

## 1. Executive Summary

`bin/cloud-xdg-provision.sh` (796 lines) and `bin/home-tree.sh` (310 lines) share a
small set of **byte-identical** plumbing helpers and two **divergent** directory-set
definitions. This design:

- **#3** — extracts ONLY the byte-identical helpers into a sourced library
  `bin/lib/xdg-common.sh`, found via a bash-3.2 symlink-/CWD-safe self-location
  snippet. Helpers that *look* shared but differ behaviorally (notably `run()`) stay
  per-script.
- **#2** — introduces ONE canonical directory registry in the library. Both scripts
  **derive their directory naming/attributes** from it, while each **keeps its own
  membership and ordering** (cloud-xdg manages Desktop/Downloads/Public/Templates;
  home-tree manages Notes; the two sets are deliberately NOT identical and are NOT
  forced identical).

Net code removed: ~25 lines of true duplication (4 logging helpers + `field` +
platform detection + XDG base defaults + `SELF`), plus the two divergent dir tables
collapse to one registry + two thin membership lists.

---

## 2. Duplication & Divergence Inventory (exact)

### 2.1 BYTE-IDENTICAL — safe to extract to the library

| Helper | cloud-xdg lines | home-tree lines | Notes |
|---|---|---|---|
| `log()` `info()` `warn()` `die()` | 107–110 | 50–53 | Character-for-character identical. |
| XDG base defaults (`: "${XDG_*:=...}"`) | 46–49 | 26–29 | Identical 4-line block. |
| Platform detection (uname case) | 267–273 (inline) | 106–117 (`detect_platform()`) | **Same logic, same PLATFORM output.** Formatting/wrapping differs only. |
| `SELF="$(basename "$0")"` | 79 | 47 | Identical line. `$0` is unchanged by sourcing, so computing it in the lib is safe (see §4.4). |
| `field()` pipe-splitter | 429 | — (not present) | Lives only in cloud-xdg today; **both** scripts need it after the registry refactor. |

### 2.2 DIVERGENT — must STAY per-script (do NOT extract or parameterize)

| Helper | Why it diverges | Evidence |
|---|---|---|
| **`run()`** | cloud-xdg uses `printf ' %q' "$@"` (per-arg shell-quoting); home-tree uses `printf '%s' "$*"` (unquoted, space-joined). | cloud-xdg 111–122 vs home-tree 55–62. Smoke **Group 11 / M6** asserts cloud-xdg dry-run renders `My\ Cloud\ Drive` (backslash-escaped). Unifying to `%q` would make home-tree start escaping; unifying to `%s` would drop cloud-xdg's escaping and fail smoke. **KEEP TWO `run()`s.** |
| `ensure_local_base` vs `ensure_local_xdg` | Same `mkdir -p` loop, but different `log`/`info` wording AND each calls its own `run()`. | cloud-xdg 434–441 (extra trailing `info` line) vs home-tree 132–138. |
| macOS Drive-mount detection | cloud-xdg `resolve_cloud_root` (275–304) does multi-mount **disambiguation** (Issue #4: dies on 0 or >1). home-tree `find_macos_drive_mount` (121–127) takes the **first match**, informational only. | Opposite semantics — not duplication. |
| `usage()`, `main()` | Entirely different content per tool. | — |

> **Rule for the coder:** extract a helper **only** if it is byte-identical between
> the two scripts today (the §2.1 set). Anything with any behavioral difference (§2.2)
> stays where it is. If you find a helper not listed here that you think is shared,
> diff the two implementations byte-for-byte before touching it.

### 2.3 The divergent directory sets

**cloud-xdg `OFFLOAD_SET`** (lines 92–102) — format `canonical|macName|linuxName|xdgVar|redirect`, **9 dirs**, in this order:

```
desktop|Desktop|Desktop|XDG_DESKTOP_DIR|1
documents|Documents|Documents|XDG_DOCUMENTS_DIR|1
downloads|Downloads|Downloads|XDG_DOWNLOAD_DIR|1
music|Music|Music|XDG_MUSIC_DIR|1
pictures|Pictures|Pictures|XDG_PICTURES_DIR|1
videos|Movies|Videos|XDG_VIDEOS_DIR|1
public|Public|Public|XDG_PUBLICSHARE_DIR|1
templates|Templates|Templates|XDG_TEMPLATES_DIR|1
projects|Projects|Projects||1
```

**home-tree `SAFE_DIRS`** (line 32) — capitalized indexed array, **6 dirs**, in this order:

```
SAFE_DIRS=(Documents Pictures Music Videos Projects Notes)
```

**Divergence map (PRESERVE EXACTLY):**

| Dir | cloud-xdg | home-tree | Note |
|---|---|---|---|
| Desktop, Downloads, Public, Templates | ✅ managed | ❌ not in SAFE set | cloud-xdg-only |
| Notes | ❌ absent | ✅ managed | **home-tree-only** |
| Documents, Pictures, Music, Videos, Projects | ✅ | ✅ | shared — but **order differs** |
| videos naming | macName `Movies` / linuxName `Videos` | uses `Videos` | home-tree's name == registry **linuxName** column |

> **Ordering is load-bearing.** home-tree iterates `Documents, Pictures, Music, …`
> (Pictures **before** Music). The registry's order is cloud-xdg's order
> (`…music, pictures…`, Music **before** Pictures). The two orders are
> incompatible in a single linear scan — so home-tree MUST iterate its **own**
> ordered key list with per-key lookups, NOT scan the registry. (§5.3)

**home-tree `NEVER_DIRS`** (line 36, `Cache State Config Downloads`) and the
**rclone filter** (`write_filter`, 153–187) are home-tree-specific policy and stay
**hardcoded in home-tree** — see the coupling invariant in §6.

---

## 3. Component View

```
                bin/lib/xdg-common.sh   (NEW — sourced, never executed)
                ┌─────────────────────────────────────────────┐
                │ # shellcheck shell=bash                       │
                │ log() info() warn() die()      (identical)    │
                │ field()                        (registry parse)│
                │ detect_platform() -> PLATFORM  (identical)    │
                │ xdg_init_base_defaults()       (XDG_* defaults)│
                │ SELF (basename $0)                             │
                │ XDG_DIR_REGISTRY   (the ONE canonical table)  │
                │ CLOUDXDG_KEYS / HOMETREE_KEYS (membership+order)│
                │ registry_row(canon)  xdg_offload_set()        │
                └───────────────┬───────────────────┬───────────┘
                  source + derive│                   │source + derive
          ┌───────────────────────┐         ┌──────────────────────────┐
          │ bin/cloud-xdg-provision│         │ bin/home-tree.sh          │
          │ self-locate + source   │         │ self-locate + source      │
          │ OFFLOAD_SET=xdg_offload_set│      │ SAFE_DIRS from HOMETREE_KEYS│
          │ KEEPS: run(), resolve_  │         │ KEEPS: run(), find_macos_ │
          │  cloud_root, relocate,  │         │  drive_mount, write_filter│
          │  traps, lock, cloud_name│         │  (hardcoded), do_backup,  │
          │  local_name, is_redirect│         │  do_bisync, NEVER_DIRS    │
          └───────────────────────┘         └──────────────────────────┘
```

The library is **declarations-only** (function definitions + variable assignments +
the `:`-default idiom). It contains no top-level command that can fail, so sourcing
it under `set -euo pipefail` cannot abort the caller (§4.3).

---

## 4. Shared Library Design (#3)

### 4.1 Location

`bin/lib/xdg-common.sh` — a `lib/` subdir under `bin/` keeps the two executables and
their shared code co-located and makes the relative path from each script trivially
`<script-dir>/lib/xdg-common.sh`.

### 4.2 Self-location snippet (bash 3.2, symlink- and CWD-safe)

Placed in **each script**, immediately after `set -euo pipefail`. It must resolve the
script's real directory **without** `readlink -f` (GNU-only; absent on stock macOS),
following a chain of symlinks, and work regardless of the caller's CWD.

```sh
set -euo pipefail

# --- locate & source the shared library (bash 3.2; symlink- and CWD-safe) ---
__self_src="${BASH_SOURCE[0]}"
while [ -h "$__self_src" ]; do
  __self_dir="$(cd -P "$(dirname "$__self_src")" >/dev/null 2>&1 && pwd)"
  __self_src="$(readlink "$__self_src")"
  case "$__self_src" in
    /*) : ;;                                   # absolute target — use as-is
    *)  __self_src="$__self_dir/$__self_src" ;; # relative — resolve vs link dir
  esac
done
__self_dir="$(cd -P "$(dirname "$__self_src")" >/dev/null 2>&1 && pwd)"
XDG_COMMON_LIB="$__self_dir/lib/xdg-common.sh"
if [ ! -r "$XDG_COMMON_LIB" ]; then
  printf 'error: required library not found or unreadable: %s\n' "$XDG_COMMON_LIB" >&2
  exit 1
fi
# shellcheck source=bin/lib/xdg-common.sh
. "$XDG_COMMON_LIB"
```

Rationale: `[ -h ]`, `readlink` (no `-f`), `cd -P`, `dirname`, and `case` are all
bash-3.2 / macOS-coreutils safe. The `case` arm re-anchors a **relative** symlink
target against the link's own directory (the standard resolve-loop correctness point).
`readlink` runs only inside `while [ -h … ]`, so it is always called on an actual
symlink and never trips `set -e`.

**Missing-lib contract:** if the lib is absent or unreadable, print
`error: required library not found or unreadable: <abs-path>` to stderr and `exit 1`
**before** sourcing. (Mirrors the existing `die()` wording style, but `die` is not yet
available — it lives in the lib — so this one message is inlined.)

### 4.3 Sourcing × `set -euo pipefail`

- The library defines functions and assigns variables only. Function definitions,
  plain assignments, and the `: "${VAR:=default}"` idiom all return 0 → **sourcing
  cannot abort** the caller under `set -e`. The coder must NOT put any top-level
  command in the lib that can return non-zero (no `grep`, `[ … ]` tests, `command -v`,
  etc. at file scope).
- The library does **NOT** itself run `set -euo pipefail`. Each executable keeps its
  own `set -euo pipefail` (unchanged). A sourced lib that flipped global shell options
  would be a side effect on the caller; avoid it.
- `nounset` (`-u`) interaction: helper bodies must not reference unset variables. They
  only touch their own args and already-defaulted vars. `xdg_init_base_defaults` exists
  precisely to populate `XDG_*` before anything reads them.

### 4.4 Helper extraction details

- **`log/info/warn/die`** — move verbatim. Zero behavior change.
- **`field()`** — move verbatim (`field() { printf '%s' "$1" | cut -d'|' -f"$2"; }`).
- **`detect_platform()`** — the library owns the canonical function. **home-tree**
  already calls `detect_platform` first in `main()` — unchanged. **cloud-xdg** today
  runs the case **inline** at load (lines 267–273); replace those 7 lines with a single
  `detect_platform` call at the **same point** (top level, after arg parsing, before
  `main`). `PLATFORM` is global either way → identical value at every use site
  (`resolve_cloud_root`, `cloud_root_is_live`, `relocate_dir`, banner).
- **`xdg_init_base_defaults()`** — wraps the 4 `: "${XDG_*:=…}"` lines. Sets the four
  globals (no `local`, so assignment is global). Each script calls it **once at top
  level, right after sourcing**, mirroring today's load-time assignment. Verified no
  code between the original assignment site and `main()` reads these vars, so the call
  site move is behavior-neutral.
- **`SELF`** — set in the lib as `SELF="$(basename "$0")"`. `$0` is the **executed
  script's** path and is unchanged when a lib is `.`-sourced, so `SELF` resolves to the
  script's basename exactly as before. (Both scripts are only ever executed, never
  themselves sourced.)

---

## 5. Unified Directory Registry (#2)

### 5.1 The ONE canonical table (in the library)

Keep cloud-xdg's existing 5-field schema **unchanged** —
`canonical|macName|linuxName|xdgVar|redirect` — and define the **superset** (cloud-xdg's
9 dirs in cloud-xdg's order, with the home-tree-only `notes` row appended):

```sh
# canonical|macName|linuxName|xdgVar|redirect
XDG_DIR_REGISTRY="
desktop|Desktop|Desktop|XDG_DESKTOP_DIR|1
documents|Documents|Documents|XDG_DOCUMENTS_DIR|1
downloads|Downloads|Downloads|XDG_DOWNLOAD_DIR|1
music|Music|Music|XDG_MUSIC_DIR|1
pictures|Pictures|Pictures|XDG_PICTURES_DIR|1
videos|Movies|Videos|XDG_VIDEOS_DIR|1
public|Public|Public|XDG_PUBLICSHARE_DIR|1
templates|Templates|Templates|XDG_TEMPLATES_DIR|1
projects|Projects|Projects||1
notes|Notes|Notes||1
"
```

Field semantics are exactly today's (see cloud-xdg header 81–91). The `notes` row uses
`Notes` for both mac/linux names and an empty `xdgVar` (home-tree never writes
`user-dirs.dirs`; cloud-xdg never sees `notes`).

### 5.2 Membership + order lists (in the library)

Each tool's **membership and order** are explicit, separate from attributes:

```sh
# Each tool manages a DIFFERENT subset in a DIFFERENT order — deliberate divergence.
CLOUDXDG_KEYS="desktop documents downloads music pictures videos public templates projects"
HOMETREE_KEYS="documents pictures music videos projects notes"
```

> Note `HOMETREE_KEYS` keeps Pictures **before** Music — home-tree's existing order.

### 5.3 Lookup + selection helpers (in the library)

```sh
# Echo the registry row for a canonical key (or nothing). First match wins.
registry_row() {
  printf '%s\n' "$XDG_DIR_REGISTRY" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      "$1|"*) printf '%s\n' "$line"; break ;;
    esac
  done
}

# Emit cloud-xdg's offload set: the rows for CLOUDXDG_KEYS, in that order.
# Reproduces today's OFFLOAD_SET line-for-line.
xdg_offload_set() {
  local k
  # shellcheck disable=SC2086   # intentional word-split of the space-separated key list
  for k in $CLOUDXDG_KEYS; do registry_row "$k"; done
}
```

The `case "$line" in "$1|"*)` pattern anchors on the canonical key followed by a
literal `|`, so `music` never matches `musicvideos` etc. (all current keys are unique
prefixes anyway). 3.2-safe constructs only: `printf | while read`, `case`, `cut` (via
`field`), indexed-array append.

### 5.4 How each script consumes the registry

**cloud-xdg** — replace the literal `OFFLOAD_SET="..."` block (92–102) with:

```sh
OFFLOAD_SET="$(xdg_offload_set)"
```

Everything downstream (`ensure_cloud_tree` 443–451, the main redirect loop 772–778,
`write_user_dirs` 695–710) consumes `$OFFLOAD_SET` **unchanged**. The derived value
omits the original leading/trailing blank lines, but every consumer already does
`[ -z "$line" ] && continue`, and no consumer echoes the raw string → **identical
effective iteration and identical output**.

> **CRITICAL — keep the here-doc, never a pipe.** cloud-xdg's main redirect loop
> (lines 772–778) feeds `$OFFLOAD_SET` via a **here-doc** (`done <<EOF … EOF`), NOT
> `printf … | while`, specifically so `redirect_one` → `relocate_dir` runs in the
> **parent shell** where the `PROBE_ACTIVE` / `RELOCATE_ACTIVE` / `LOCK_OWNED` trap
> flags live (see cloud-xdg 124–163, 762–771). A pipe would run that loop body in a
> subshell whose flag writes never reach the parent handler and whose traps reset to
> default — silently disabling probe-revert and mid-relocate recovery on SIGINT/TERM.
> The refactor changes only **where `$OFFLOAD_SET` is sourced from**; the here-doc
> feeding mechanism MUST remain. (Regression-guarded by smoke's PR#11 interrupt group.)

**home-tree** — replace the literal `SAFE_DIRS=(…)` (line 32) with a registry-derived
build using its own key list and the **linuxName** column (field 3):

```sh
SAFE_DIRS=()
# shellcheck disable=SC2086   # intentional word-split of HOMETREE_KEYS
for __k in $HOMETREE_KEYS; do
  SAFE_DIRS+=("$(field "$(registry_row "$__k")" 3)")
done
```

linuxName per key yields `Documents Pictures Music Videos Projects Notes` — byte-identical
to today's literal array, in the same order. `ensure_home_tree` (140–146) is unchanged.

`NEVER_DIRS` (line 36) stays literal (Cache/State/Config are not user-dirs and are not
in the registry).

---

## 6. ⚠️ Coupling Invariant — registry linuxName ↔ rclone filter

home-tree's **rclone filter** (`write_filter`, 153–187) is a **hardcoded heredoc** and
is the **single source of truth for what may reach the cloud**. It is NOT derived from
the registry. Its allow lines are:

```
+ /Documents/**   + /Pictures/**   + /Music/**   + /Videos/**   + /Notes/**   + /Projects/**
```

**Invariant:** the registry **linuxName** for each `HOMETREE_KEYS` entry MUST equal the
corresponding filter allow-path name. If a future edit renames, e.g., the `videos`
linuxName to something other than `Videos`, `ensure_home_tree` would create a folder the
filter no longer allows → **silent backup gap / potential data-leak surface**.

**Mitigations the coder MUST apply:**
1. Leave the filter heredoc **untouched** in this refactor.
2. Add a prominent comment in the lib next to `HOMETREE_KEYS`/registry stating this
   coupling.
3. The equivalence gate (§7) MUST include a **byte-identical golden check of the
   generated rclone filter file** before vs after. Any drift fails the refactor.

---

## 7. Equivalence Verification — Coder's Acceptance Gate

All three are **mandatory** and **non-negotiable** (the `run()` divergence + registry
refactor make output-equivalence the only real proof of no regression).

### 7.1 Both smoke suites pass UNCHANGED
`bash tests/smoke.sh` ends in `smoke: PASS`, with **no edits to `tests/smoke.sh`**.
(The suite already exercises both scripts: dry-run banners, apply idempotency, relocate,
B1–B6 guards, `--style mac` naming, forced-Linux `user-dirs.dirs`, the rclone filter
content, CLI error paths, and the PR#11 interrupt/trap regressions.)

### 7.2 Golden output diff — before vs after (byte-identical)
Capture `stdout`+`stderr`(+`rc`) from the **committed** scripts (`git show HEAD:bin/…`
into temp copies) and the **working-tree** scripts, in a throwaway sandbox
(`HOME`/`TMPDIR`/cloud under a temp dir), and `diff` each pair — all empty:

**cloud-xdg-provision.sh (dry-run unless noted):**
- `--cloud-root "$C"` (default)
- `--cloud-root "$C" --style mac`
- `--cloud-root "$C" --redirect-downloads`
- `--cloud-root "$C with spaces"` — guards the `run()` `%q` quoting (M6)
- forced-Linux via a `uname` PATH-shim (`-s`→`Linux`), dry-run — guards Linux naming
  (`~/Videos`) and the `user-dirs.dirs` mapping path
- forced-Linux **apply** in a sandbox HOME + `--allow-local-root`, then **diff the
  written `$XDG_CONFIG_HOME/user-dirs.dirs`** before vs after (registry-derived content)

**home-tree.sh (dry-run):**
- `--root "$H"` (default)
- **Filter golden:** run it, then `diff` the generated
  `${TMPDIR}/home-tree.rclone-filter` before vs after (§6) — MUST be byte-identical

### 7.3 Lint clean
`make lint` exits 0 (see §8).

---

## 8. Makefile / pre-commit Lint Implications

Current `Makefile` `lint` target:
```
shellcheck bin/*.sh hooks/pre-commit tests/*.sh
```
`bin/*.sh` does **not** match `bin/lib/xdg-common.sh` (no recursion). Update the glob:
```
shellcheck bin/*.sh bin/lib/*.sh hooks/pre-commit tests/*.sh
```
The `hooks/pre-commit` hook runs `make lint`, so it is covered automatically by the same
change — no separate hook edit.

**Shellcheck cleanliness requirements (lib must lint clean):**
- Library top line: `# shellcheck shell=bash` (the lib has **no shebang** and is sourced,
  so shellcheck needs the dialect hint).
- In each script, the `# shellcheck source=bin/lib/xdg-common.sh` directive (shown in
  §4.2) sits directly above `. "$XDG_COMMON_LIB"` so shellcheck follows the dynamic
  source and sees lib-defined symbols (avoids SC1091 and SC2154 for `PLATFORM`,
  `XDG_DIR_REGISTRY`, etc.).
- The two `for k in $CLOUDXDG_KEYS` / `$HOMETREE_KEYS` loops need
  `# shellcheck disable=SC2086` (intentional word-split of a space-separated list).
- Keep `printf | while read` (not a herestring) — herestrings are fine in 3.2 but the
  pipe form here is read-only (no trap flags) so subshell scoping is irrelevant.

---

## 9. bash 3.2 Compliance Checklist (every new construct)

| Construct used | 3.2-safe? |
|---|---|
| `${BASH_SOURCE[0]}`, indexed arrays, `arr+=(x)` | ✅ (indexed only; no associative) |
| `[ -h ]`, `readlink` (no `-f`), `cd -P`, `dirname`, `basename` | ✅ macOS coreutils |
| `printf | while IFS= read -r` | ✅ |
| `case "$x" in pat) … ;; esac` | ✅ |
| `cut -d'|' -f"$n"` (`field`) | ✅ |
| `: "${VAR:=default}"` | ✅ |
| **Avoided:** `declare -A`, `mapfile`/`readarray`, `<()`, `[[ … ]]`, `${v^^}`/`${v,,}`, `$'…'`, namerefs, `readlink -f` | ✅ none introduced |

---

## 10. Risk Register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Unifying `run()` regresses M6 `%q` quoting | — | High (smoke fail) | **Designed out:** two `run()`s stay per-script (§2.2). |
| R2 | De-piping cloud-xdg's redirect loop into a pipe breaks trap flags | Med | **Critical** (silent loss of interrupt safety) | Keep the here-doc; change only `$OFFLOAD_SET`'s source (§5.4). PR#11 smoke group regression-guards it. |
| R3 | registry linuxName drifts from the hardcoded rclone filter | Low | **High** (data-leak/backup gap) | Filter untouched; coupling comment; filter golden check (§6, §7.2). |
| R4 | home-tree ordering changes (Pictures/Music swap) | Med | Med (golden diff fail) | Own `HOMETREE_KEYS` list, not registry scan (§5.3); golden diff catches it. |
| R5 | Lib top-level command trips `set -e` at source time | Low | High (script won't start) | Lib is declarations-only (§4.3). |
| R6 | New lib not covered by lint glob → unreviewed shell | Med | Med | Update Makefile glob + directives (§8). |
| R7 | Self-location wrong under symlink/odd CWD | Low | High (can't find lib) | Standard 3.2 resolve loop + readable-guard error (§4.2). |
| R8 | `xdg_init_base_defaults`/`detect_platform` call-site move changes load-time behavior | Low | Med | Verified no intervening reads; call both at top level right after sourcing (§4.4). |

---

## 11. Implementation Order (single coder, one PR)

1. Create `bin/lib/xdg-common.sh` with `# shellcheck shell=bash`; add `log/info/warn/die`,
   `field`, `detect_platform`, `xdg_init_base_defaults`, `SELF`, `XDG_DIR_REGISTRY`,
   `CLOUDXDG_KEYS`, `HOMETREE_KEYS`, `registry_row`, `xdg_offload_set`.
2. cloud-xdg: insert self-location+source snippet after `set -euo pipefail`; delete the
   migrated helpers; replace inline platform case with `detect_platform`; call
   `xdg_init_base_defaults`; set `OFFLOAD_SET="$(xdg_offload_set)"`; **keep `run()`,
   the here-doc loop, traps, lock, all relocate logic untouched.**
3. home-tree: same self-location+source; delete migrated helpers; keep its own
   `detect_platform` call in `main`; call `xdg_init_base_defaults`; build `SAFE_DIRS`
   from `HOMETREE_KEYS`; **keep `run()`, `find_macos_drive_mount`, the rclone filter,
   `NEVER_DIRS` untouched.**
4. Update `Makefile` `lint` glob to include `bin/lib/*.sh`.
5. Run the §7 gate: golden diffs (incl. filter + user-dirs.dirs) empty, `bash
   tests/smoke.sh` → PASS unchanged, `make lint` rc 0.

---

## 12. Reasoning Chain

- **Behavior-preservation is the hard constraint**, so the first analytic step was a
  byte-level diff of every candidate-shared helper — *because* the scripts just passed a
  data-safety review and any output drift is a regression. That diff split helpers into
  "byte-identical → extract" (§2.1) and "looks shared but differs → leave" (§2.2).
- **`run()` is the pivotal find.** It looks like obvious duplication, but cloud-xdg's
  `%q` quoting is a *tested* contract (smoke M6) while home-tree's `%s` is its own. So
  the design extracts the four logging helpers but **not** `run()` — *which is why* the
  lib carries `log/info/warn/die` yet each script keeps its own `run()`.
- **The two dir sets diverge in membership AND order**, and the orders are mutually
  incompatible in a single scan (Music/Pictures swap). *Therefore* a single shared
  iteration cannot reproduce both outputs — *which forced* the "one attribute registry +
  per-tool ordered key list with lookups" shape (§5) rather than a shared loop.
- home-tree's create-names happen to equal the registry **linuxName** column, *so* it can
  derive names without new data — *but* that introduces a coupling to the hardcoded
  rclone filter (the cloud-safety source of truth), *which is why* §6 elevates the filter
  to an explicit invariant with its own golden check.
- cloud-xdg's interrupt safety depends on `relocate_dir` running in the parent shell,
  *which is why* the registry change is deliberately scoped to **only** the source of
  `$OFFLOAD_SET`, leaving the here-doc feeding mechanism (and traps/lock) untouched (R2).
- The lib is **declarations-only** *because* `set -euo pipefail` would abort the caller
  on any failing top-level command at source time (§4.3) — that constraint shaped what
  may and may not live in the lib.
```
