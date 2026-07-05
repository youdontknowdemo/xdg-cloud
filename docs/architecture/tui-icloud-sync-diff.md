# TUI iCloud Sync — ARCHITECT diff-spec

**Phase:** PACT Architect · **Status:** CODE gate — both coders build exactly what this document specifies.
**Upstream:** approved plan `docs/plans/tui-icloud-sync-plan.md` (user-locked: bulk evict DEFERRED,
`icloud-sync-up` REJECTED permanently) and PREPARE research
`docs/preparation/research-tui-icloud-sync.md` (verified probe facts adopted throughout).
**Companion spec:** `docs/architecture/tui-offload-manager-diff.md` (PR #43) — its contracts
(ACTIONS table §5, wrap-don't-bypass §0, porcelain freeze §2.6, consent gate §6) are binding and
**unchanged** here.

---

## 0. What this PR is

Three script-side changes plus thin TUI wiring:

1. **Resolve-then-confine fix** in `icloud_resolve_under_root` (~L1867) — the enabling fix: on a
   provisioned machine every TUI iCloud action targets `$HOME/<localName>`, a symlink into
   CloudDocs, and today's lexical prefix match refuses it (verified, rc 1).
2. **`--icloud-sync-status <path>`** — new read-only summary lane: counts, byte totals, free-space
   line, `brctl status` health line. Batched helper invocation (single spawn per chunk).
3. **`--icloud-download` enhancement in place** — dataless-only filter; plan header with count +
   bytes; **free-space gate** (fail-closed) with a fixed margin. No new flag.

Locked out of scope: bulk/skip-and-report evict (own follow-up diff-spec); any `sync-up` action;
porcelain for iCloud lanes (verbatim panes ruled fine in PR #43, §12); consent-gate changes.
**`cmd_icloud_evict`'s body is byte-untouched** — but note honestly: the shared resolver fix
changes evict's *accept set* too (symlinked paths now resolve instead of dying). That is the
intended enabling fix from the plan (piece 1); every downstream gate (helper, consent,
all-or-nothing) is unchanged.

---

## 1. Files touched + S2 partition (zero shared files)

| File | Change | Owner (CODE) |
|---|---|---|
| `bin/cloud-xdg-provision.sh` | `ICLOUD_ROOT` env-default (§2.1); `ICLOUD_DL_MARGIN_BYTES` (§2.1); resolver rewrite (§2.2); four new helpers (§2.3); `cmd_icloud_sync_status` (§2.4); `cmd_icloud_download` rewrite (§2.5); arg-parse arm + dispatch entry + `usage()` lines (§2.6) | **devops-coder** |
| `tests/smoke.sh` | new **I3** group (resolve matrix + sync-status + download gate, §4.1–4.3); **I2 updates** — stat-shim format + subtest (l) rewrite (§4.4) | **devops-coder** |
| `bin/xdg_tui.py` | one `ACTIONS` row + two `ops_for_entry` list edits (§3) | **backend-coder** |
| `tests/tui/test_plan.py`, `tests/tui/test_model.py` | argv matrix + ops-list assertions (§4.5) | **backend-coder** |
| `README.md`, `CHANGELOG.md` | polish — **lead** commits | lead |
| `bin/icloud-uploaded.swift`, `Makefile`, `bin/lib/xdg-common.sh`, `bin/home-tree.sh`, `bin/xdg-tui` | **untouched** | — |

**S2 rule:** devops-coder owns all bash; backend-coder owns all python. The only cross-dependency
is the flag name `--icloud-sync-status` and its rc taxonomy (0 report / 1 die), both frozen by
this document — coders build against this spec, not each other's files.

---

## 2. Bash slice (exact bodies)

### 2.1 Config (L111–114 block)

`ICLOUD_ROOT` becomes env-overridable (**RATIFIED** — see §7 D2 for the confinement argument),
and the download margin is a named, env-overridable constant:

```sh
# iCloud brctl lane (slice 5, step 9) — macOS-only true-offload for iCloud-native data. SECONDARY
# to the rclone --offload (which verifies durable upload before dropping local); iCloud evict is
# heavily gated + fail-closed. status/download are stock; evict needs the compiled upload-state
# helper (make helper). HELPER and ROOT are env-overridable so the sandboxed smoke suite can shim
# them; the override CANNOT weaken confinement because icloud_resolve_under_root canonicalizes
# BOTH the root and the target (cd && pwd -P) before the prefix compare, and dies if the root
# itself does not resolve (fail closed).
: "${ICLOUD_ROOT:=$HOME/Library/Mobile Documents/com~apple~CloudDocs}"  # same iCloud root as cloud_root_is_live
: "${ICLOUD_HELPER:=$__self_dir/icloud-uploaded}"                  # compiled binary beside this script
ICLOUD_CONFIRM=0                                                    # set by --i-understand-data-loss-risk
ICLOUD_TARGET=""                                                    # resolved target (set by icloud_resolve_under_root)
# Free-space margin the bulk download must leave untouched (bytes). ENOSPC mid-hydrate jams
# fileproviderd (prior incident: a 100%-full disk froze ALL iCloud sync) — this is a safety gate,
# not cosmetics. Fixed 1 GiB, deliberately NOT a percentage: the incident profile is a nearly-full
# disk, where a %-of-download margin under-protects small downloads. Env-overridable as the smoke
# seam (huge value => deterministic refusal; 0 => deterministic pass) and as a user knob.
: "${ICLOUD_DL_MARGIN_BYTES:=1073741824}"
# As-built (added post-review): this value flows into an arithmetic context ($((bytes_need + …))),
# where bash re-evaluates a variable's VALUE as an expression — an array-subscript-with-command-
# substitution executes at eval time. Validate digits-only at load, fail-closed, matching the df guard.
case "${ICLOUD_DL_MARGIN_BYTES}" in ''|*[!0-9]*) die "ICLOUD_DL_MARGIN_BYTES must be a non-negative integer" ;; esac
```

> **As-built additions beyond the original spec bodies** (all committed, all test-pinned): (1) the
> `ICLOUD_DL_MARGIN_BYTES` load-time numeric guard above; (2) `< /dev/null` on the chunk-flush helper
> exec (§2.3) and on the download-loop `brctl` exec (§2.5) — both sever an inherited `while … < list`
> stdin. Reconciled here per the repo's as-built convention (cf. ADR §8.1 / F7).

### 2.2 `icloud_resolve_under_root` — resolve-then-confine (SAFETY-CRITICAL)

Full replacement for L1865–1874:

```sh
# Resolve $1 to a PHYSICAL absolute path, then require it under the RESOLVED $ICLOUD_ROOT.
# RESOLVE-THEN-CONFINE — the ordering is safety-critical and must never be reversed:
#   * confining the UNRESOLVED string admits a lexically-inside path that resolves OUTSIDE
#     CloudDocs (e.g. CloudDocs/escape -> /elsewhere), handing out-of-root paths to brctl;
#   * resolving AFTER the compare is the same bug with extra steps.
# Both sides are canonicalized: the target via cd && pwd -P (dirs) or dirname-resolve +
# basename re-join (files), and the ROOT itself via cd && pwd -P — a lexical root vs a
# physical target can never prefix-match (/tmp vs /private/tmp), and an env-overridden or
# symlinked root stays fail-closed. bash 3.2: no readlink -f; cd targets are always absolute
# (CDPATH cannot intercept). A root that does not resolve => die (fail closed).
# Final-component FILE symlinks are deliberately NOT followed (dirname-only resolution):
#   - out-of-root file symlink whose parent is in-root: admitted but INERT — every lane
#     enumerates via `find -type f` with no -H/-L, so a symlink is never a candidate and
#     no out-of-root path ever reaches brctl/stat/helper;
#   - in-root file reached via an out-of-root parent symlink chain is refused (fail closed).
# Sets the global ICLOUD_TARGET (physical path).
icloud_resolve_under_root() {
  local raw abs root_resolved dir base
  raw="$1"
  case "$raw" in /*) abs="$raw" ;; *) abs="$(pwd)/$raw" ;; esac
  root_resolved="$(cd "$ICLOUD_ROOT" 2>/dev/null && pwd -P)" \
    || die "iCloud Drive root not found or not resolvable ($ICLOUD_ROOT)."
  if [ -d "$abs" ]; then
    ICLOUD_TARGET="$(cd "$abs" 2>/dev/null && pwd -P)" \
      || die "cannot resolve path (unreadable or vanished): $abs"
  elif [ -e "$abs" ]; then
    dir="$(dirname "$abs")"; base="$(basename "$abs")"
    dir="$(cd "$dir" 2>/dev/null && pwd -P)" \
      || die "cannot resolve path (unreadable or vanished): $abs"
    ICLOUD_TARGET="$dir/$base"
  else
    die "no such path: $abs"
  fi
  case "$ICLOUD_TARGET" in
    "$root_resolved"|"$root_resolved"/*) : ;;
    *) die "path is not under iCloud Drive ($ICLOUD_ROOT): $ICLOUD_TARGET (resolved)" ;;
  esac
}
```

Behavioral deltas (all fail-closed, none weaken a gate):

| Input | Old | New |
|---|---|---|
| `$HOME/Documents` → symlink into CloudDocs | die "not under" (the TUI-killing bug) | **accepted**; `ICLOUD_TARGET` = physical CloudDocs path |
| `CloudDocs/escape` → symlink to outside dir | **accepted lexically** (latent hole) | **refused** ("not under … (resolved)") |
| `CloudDocs/linkdir/sub`, `linkdir` → outside | accepted lexically | refused |
| nonexistent path outside root | "not under iCloud Drive" | "no such path" (existence now checked first — resolution needs it) |
| root missing / unresolvable | "not under" on any target | "iCloud Drive root not found" |
| file symlink `CloudDocs/link` → outside file | accepted; inert (`find -type f` skips symlinks) | same: admitted, inert (documented invariant) |
| file symlink `$HOME/x` → file in CloudDocs | refused | still refused (final component not followed — known limitation, §8) |

The die message keeps the phrase `path is not under iCloud Drive` — existing smoke assertions
(I1a, `/tmp` target) keep passing (`/tmp` exists → resolves to `/private/tmp` → not under root).

### 2.3 New shared helpers (place after `icloud_is_dataless`, before `cmd_icloud_status`)

```sh
# Human-format a byte count via awk (bash 3.2 has no floating point). Prints e.g.
# "1.9 GiB (2044723200 bytes)" or, below 1 KiB, "512 B".
icloud_fmt_bytes() {                     # $1 = non-negative integer bytes
  awk -v b="$1" 'BEGIN {
    if (b >= 1073741824)   printf "%.1f GiB (%d bytes)", b/1073741824, b
    else if (b >= 1048576) printf "%.1f MiB (%d bytes)", b/1048576, b
    else if (b >= 1024)    printf "%.1f KiB (%d bytes)", b/1024, b
    else                   printf "%d B", b
  }'
}

# Available KiB on the volume holding $1, or nothing on failure. POSIX df -P -k; the
# Available column is located RELATIVE TO the Capacity (%) field, never positionally
# from the left or right — device names and mount points may contain spaces. Plain
# `df` (not /bin/df) so the sandbox can PATH-shim it. Callers must numeric-validate.
icloud_avail_kb() {                      # $1 = path on the volume
  df -P -k "$1" 2>/dev/null \
    | awk 'NR==2 { for (i = 1; i <= NF; i++) if ($i ~ /%$/) { print $(i-1); exit } }'
}

# One-line container health from `brctl status` (read-only QUERY — deliberately not via
# run(): the dry-run ledger is for mutations; precedent: mdls/stat in cmd_icloud_status).
# Prints "caught-up", "NOT-CAUGHT-UP", or "unknown (<why>)". Advisory: never dies.
icloud_sync_health() {
  command -v brctl >/dev/null 2>&1 || { printf 'unknown (brctl not found)\n'; return 0; }
  local line
  line="$(brctl status 2>/dev/null | grep -m1 'com\.apple\.CloudDocs')" || line=""
  if [ -z "$line" ]; then printf 'unknown (no CloudDocs container reported)\n'; return 0; fi
  case "$line" in
    *caught-up*) printf 'caught-up\n' ;;
    *)           printf 'NOT-CAUGHT-UP\n' ;;
  esac
}

# --- sync-status chunked-helper state (globals: bash 3.2 functions cannot return arrays,
# and the aggregation MUST run in the parent shell — counters incremented in a `… | while`
# subshell would be lost, the repo's invariant-#4 footgun). Initialized by
# cmd_icloud_sync_status before the walk; flushed by icloud_sync_flush_chunk.
SYNC_CHUNK=()        # pending helper argv (paths)
SYNC_SIZES=()        # parallel array: stat %z per pending path
SYNC_CHUNK_BYTES=0   # accumulated argv bytes for the pending chunk
SYNC_N_UP=0; SYNC_N_WAIT=0; SYNC_N_NOTIN=0; SYNC_N_ERR=0
SYNC_BYTES_EVICT=0

# argv budget per helper exec. macOS ARG_MAX is 1 MiB INCLUDING envp and pointer space;
# 128 KiB of path bytes + a 5000-arg cap leaves >= 7/8 headroom. Byte-budgeted (not
# count-only) because PATH_MAX-length paths at a fixed large count could overflow.
ICLOUD_CHUNK_MAX_BYTES=131072
ICLOUD_CHUNK_MAX_ARGS=5000

# Flush the pending chunk through ONE helper exec and aggregate PER-LINE states.
# Chunking breaks the helper's whole-set exit-code semantics, so the rc is IGNORED here —
# stdout ("<state>\t<path>", parse-stable per icloud-uploaded.swift) is the only signal.
# Sizes join by ORDER: the helper prints one line per argv path in argv order, and
# SYNC_SIZES was appended in lockstep with SYNC_CHUNK. Any input the helper failed to
# answer (fewer output lines than args) is counted as an error — fail-closed accounting.
icloud_sync_flush_chunk() {
  [ "${#SYNC_CHUNK[@]}" -gt 0 ] || return 0
  local hout line state size i tab
  tab="$(printf '\t')"
  hout="$(mktemp "${TMPDIR:-/tmp}/xdg-icloud.XXXXXX")" || die "cannot create temp file"
  # </dev/null (as-built, added post-review): mid-walk flushes run inside a `while … < list`
  # loop — the helper must never see the file list on stdin (silent under-scan otherwise).
  "$ICLOUD_HELPER" ${SYNC_CHUNK[@]+"${SYNC_CHUNK[@]}"} < /dev/null > "$hout" 2>/dev/null || true
  i=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    state="${line%%"$tab"*}"
    size="${SYNC_SIZES[$i]:-0}"
    case "$state" in
      uploaded)      SYNC_N_UP=$((SYNC_N_UP + 1)); SYNC_BYTES_EVICT=$((SYNC_BYTES_EVICT + size)) ;;
      not-uploaded)  SYNC_N_WAIT=$((SYNC_N_WAIT + 1)) ;;
      not-in-icloud) SYNC_N_NOTIN=$((SYNC_N_NOTIN + 1)) ;;
      *)             SYNC_N_ERR=$((SYNC_N_ERR + 1)) ;;
    esac
    i=$((i + 1))
  done < "$hout"
  rm -f "$hout"
  if [ "$i" -lt "${#SYNC_CHUNK[@]}" ]; then
    SYNC_N_ERR=$((SYNC_N_ERR + ${#SYNC_CHUNK[@]} - i))
  fi
  SYNC_CHUNK=(); SYNC_SIZES=(); SYNC_CHUNK_BYTES=0
}
```

### 2.4 `cmd_icloud_sync_status` (new; place after `cmd_icloud_status`)

Read-only class: **no** `begin_mutating_mode`, no lock, no trap arming (same posture as
`--icloud-status`/`--classify`). brctl and the helper are both optional (degrade, never die —
gates are macOS + resolve only). Exit 0 always on a completed report; rc 1 only from gate `die`s.

```sh
# --icloud-sync-status <path>: read-only RECURSIVE SUMMARY — the bulk companion to
# --icloud-status's per-file dump. Counts + byte totals + free space + container health.
# One find pass, one stat per file, ONE batched helper exec per chunk (~3.8 ms/file vs
# ~20 ms/spawn — measured; per-file spawn does not scale to bulk). No lock, no mutation.
cmd_icloud_sync_status() {               # $1 = path
  icloud_guard_macos
  icloud_resolve_under_root "$1"
  local have_helper=0; [ -x "$ICLOUD_HELPER" ] && have_helper=1
  log "iCloud sync status under: $ICLOUD_TARGET (read-only)"

  SYNC_CHUNK=(); SYNC_SIZES=(); SYNC_CHUNK_BYTES=0
  SYNC_N_UP=0; SYNC_N_WAIT=0; SYNC_N_NOTIN=0; SYNC_N_ERR=0; SYNC_BYTES_EVICT=0
  local ftmp f line size
  local n_total=0 n_dataless=0 bytes_down=0 n_mat_unknown=0 bytes_mat_unknown=0
  ftmp="$(mktemp "${TMPDIR:-/tmp}/xdg-icloud.XXXXXX")" || die "cannot create temp file"
  find "$ICLOUD_TARGET" -type f > "$ftmp" 2>/dev/null || true

  while IFS= read -r f; do
    [ -z "$f" ] && continue
    n_total=$((n_total + 1))
    # size FIRST in the format: %Sf may be empty, and a trailing empty field parses
    # safely while a leading one would shift the split.
    line="$(stat -f '%z %Sf' "$f" 2>/dev/null)" || line=""
    size="${line%% *}"
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    case "$line" in
      *dataless*)
        n_dataless=$((n_dataless + 1)); bytes_down=$((bytes_down + size)) ;;
      *)
        if [ "$have_helper" -eq 1 ]; then
          SYNC_CHUNK+=("$f"); SYNC_SIZES+=("$size")
          SYNC_CHUNK_BYTES=$((SYNC_CHUNK_BYTES + ${#f} + 1))
          if [ "$SYNC_CHUNK_BYTES" -ge "$ICLOUD_CHUNK_MAX_BYTES" ] \
             || [ "${#SYNC_CHUNK[@]}" -ge "$ICLOUD_CHUNK_MAX_ARGS" ]; then
            icloud_sync_flush_chunk
          fi
        else
          n_mat_unknown=$((n_mat_unknown + 1))
          bytes_mat_unknown=$((bytes_mat_unknown + size))
        fi ;;
    esac
  done < "$ftmp"
  rm -f "$ftmp"
  if [ "$have_helper" -eq 1 ]; then icloud_sync_flush_chunk; fi

  info "scanned: $n_total file(s)"
  info "dataless (to download): $n_dataless file(s), $(icloud_fmt_bytes "$bytes_down")"
  if [ "$have_helper" -eq 1 ]; then
    info "materialized + uploaded (evictable*): $SYNC_N_UP file(s), $(icloud_fmt_bytes "$SYNC_BYTES_EVICT")"
    info "materialized, NOT uploaded (waiting on iCloud): $SYNC_N_WAIT file(s)"
    info "not in iCloud (excluded from sync, e.g. .DS_Store): $SYNC_N_NOTIN file(s)"
    [ "$SYNC_N_ERR" -gt 0 ] && warn "unreadable / helper-error: $SYNC_N_ERR file(s) (counted as NOT evictable — fail closed)"
    info "*evictable is POTENTIAL only: with 'Optimize Mac Storage' OFF, evict frees nothing (no programmatic check)."
  else
    warn "upload split unknown — helper not built (run 'make helper'): $n_mat_unknown materialized file(s), $(icloud_fmt_bytes "$bytes_mat_unknown")"
  fi

  local avail_kb
  avail_kb="$(icloud_avail_kb "$ICLOUD_TARGET")" || avail_kb=""
  case "$avail_kb" in
    ''|*[!0-9]*) warn "free space: unknown (df failed)" ;;
    *) info "free space on volume: $(icloud_fmt_bytes $((avail_kb * 1024))) — a full download would use $(icloud_fmt_bytes "$bytes_down") (download keeps a $(icloud_fmt_bytes "$ICLOUD_DL_MARGIN_BYTES") margin)" ;;
  esac

  local health
  health="$(icloud_sync_health)"
  case "$health" in
    caught-up) info "container health (brctl status): caught-up" ;;
    NOT-CAUGHT-UP)
      warn "container health (brctl status): NOT caught up — one stuck item can wedge ALL iCloud
  transfers (verified failure mode). Bulk downloads may stall; re-run this status after they finish.
  (Unwedge trick: '$SELF --icloud-evict' on the stuck item cancels its stuck download.)" ;;
    *) info "container health: $health" ;;
  esac
  return 0
}
```

### 2.5 `cmd_icloud_download` (full replacement of L1906–1918)

Human output here is NOT golden-frozen (confirmed); style stays `log/info/warn` + `run()` lines.
The free-space gate runs in **both** dry-run and apply — the gate protects the mutation, and a
dry-run that would be refused must say so (rc 1 → the TUI renders a verbatim refused pane).

```sh
# --icloud-download <path>: materialize DATALESS files. Only ADDS data — reversible/safe. No
# helper needed. Dataless-only (materialized files are skipped: a re-download request is a
# no-op that just queues pointless fileproviderd work). FREE-SPACE GATE before any download
# is planned: ENOSPC mid-hydrate jams fileproviderd (prior incident) — refuse, in dry-run and
# apply alike, unless the download fits with ICLOUD_DL_MARGIN_BYTES to spare. Fail closed:
# an unparseable df is a refusal, never a shrug.
cmd_icloud_download() {                  # $1 = path
  begin_mutating_mode
  icloud_guard_macos; icloud_resolve_under_root "$1"; icloud_require_brctl
  local ftmp dtmp f line size n_dataless=0 bytes_need=0
  ftmp="$(mktemp "${TMPDIR:-/tmp}/xdg-icloud.XXXXXX")" || die "cannot create temp file"
  dtmp="$(mktemp "${TMPDIR:-/tmp}/xdg-icloud.XXXXXX")" || die "cannot create temp file"
  find "$ICLOUD_TARGET" -type f > "$ftmp" 2>/dev/null || true
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    line="$(stat -f '%z %Sf' "$f" 2>/dev/null)" || line=""
    case "$line" in *dataless*) : ;; *) continue ;; esac
    size="${line%% *}"
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    n_dataless=$((n_dataless + 1)); bytes_need=$((bytes_need + size))
    printf '%s\n' "$f" >> "$dtmp"
  done < "$ftmp"
  rm -f "$ftmp"
  if [ "$n_dataless" -eq 0 ]; then
    rm -f "$dtmp"
    info "nothing to download — no dataless files under: $ICLOUD_TARGET"
    return 0
  fi

  local avail_kb avail_bytes
  avail_kb="$(icloud_avail_kb "$ICLOUD_TARGET")" || avail_kb=""
  case "$avail_kb" in
    ''|*[!0-9]*)
      rm -f "$dtmp"
      die "cannot determine free space for $ICLOUD_TARGET (df failed) — refusing to plan a bulk
  download blind (ENOSPC can jam iCloud sync)." ;;
  esac
  avail_bytes=$((avail_kb * 1024))
  if [ "$avail_bytes" -lt $((bytes_need + ICLOUD_DL_MARGIN_BYTES)) ]; then
    rm -f "$dtmp"
    die "refusing to download: $n_dataless dataless file(s) need $(icloud_fmt_bytes "$bytes_need"),
  but only $(icloud_fmt_bytes "$avail_bytes") is free (a $(icloud_fmt_bytes "$ICLOUD_DL_MARGIN_BYTES") margin is kept —
  ENOSPC mid-download jams ALL iCloud sync). Free space first: '$SELF --reclaim',
  '$SELF --offload <dir>', or '$SELF --icloud-evict <path>'."
  fi
  info "download plan: $n_dataless dataless file(s), $(icloud_fmt_bytes "$bytes_need") to fetch — $(icloud_fmt_bytes "$avail_bytes") free (margin OK)."
  case "$(icloud_sync_health)" in
    NOT-CAUGHT-UP) warn "iCloud container is NOT caught up — downloads may stall behind a stuck item (advisory, not blocking)." ;;
  esac

  while IFS= read -r f; do [ -z "$f" ] && continue; run brctl download "$f"; done < "$dtmp"
  rm -f "$dtmp"
  if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] would download (hydrate) the $n_dataless file(s) above (re-run with --apply)."
  else info "Download (hydrate) requested for $n_dataless file(s). Delivery is asynchronous (fileproviderd); check '$SELF --icloud-sync-status' after."; fi
}
```

### 2.6 Arg parse + dispatch + usage

Arg parse (with the other iCloud arms, after `--icloud-status`, ~L480):

```sh
    --icloud-sync-status) set_mode icloud-sync-status; shift; MODE_ARG="${1:?--icloud-sync-status needs a path}" ;;
```

Dispatch (`dispatch_mode`, with the other iCloud entries, ~L2271):

```sh
    icloud-sync-status) cmd_icloud_sync_status "$MODE_ARG" ;;
```

`usage()` — add one line to the iCloud section and update the download line:

```
  --icloud-sync-status <p>  Recursive SUMMARY (read-only): dataless/uploaded/waiting counts,
                            bytes to download / evictable, free space, container health.
  --icloud-download <path>  Materialize (hydrate) DATALESS files — only ADDS data, reversible.
                            Refuses (fail-closed) when the download would not leave a 1 GiB
                            free-space margin (ENOSPC jams iCloud sync).
```

**Flag-naming ruling (CONFIRMED, D1):** distinct lane flag `--icloud-sync-status`, not a
`--icloud-sync <p> --status` modifier — `set_mode` enforces one lane per invocation, and a
modifier-on-mode would replicate exactly the conflict `--porcelain` avoided by being a modifier
on *existing* lanes. Three-verb symmetry with the existing trio is the established pattern.

---

## 3. TUI slice — `bin/xdg_tui.py` (wiring only; ~6 lines)

**ACTIONS row** (table at ~L87, after `icloud-status` — the ordering inside the dict is
cosmetic; `ops_for_entry` owns menu order):

```python
    "icloud-sync-status": {"flag": "--icloud-sync-status", "target": "path", "read_only": True},
```

**`ops_for_entry`** (~L247–252) — sync-status leads the iCloud block (it is the "look before you
touch" op):

```python
    if entry.klass == "code":
        return ["offload", "hydrate", "reclaim", "icloud-sync-status",
                "icloud-status", "icloud-download", "icloud-evict"]
    if entry.klass == "xdg":
        return ["icloud-sync-status", "icloud-status", "icloud-download", "icloud-evict"]
    return []
```

That is the **entire** python diff. Everything else is already generic:

- `run_action`'s `read_only` branch (capture → verbatim pane, no confirm, no apply) serves the
  new op unchanged; `target == "path"` joins `$HOME/<localName>` at call time as before.
- The download enhancement needs **zero** TUI change: a gate refusal is a `die` (rc 1) →
  `interpret_result` maps to `refused` → verbatim pane; the plan header rides inside the
  existing dry-run preview pane.
- No porcelain change (verbatim panes ruled fine, PR #43 §12); no consent-gate change (evict
  flow untouched); no `plan_action` change (7 code-class ops still fit the 1–9 menu keys).

---

## 4. Test architecture

### 4.1 Smoke group **I3** — resolver matrix + sync-status + download gate (devops-coder)

New macOS-gated group after I2, same harness conventions (sandboxed `HOME`, `set +e` capture to a
var, `pass_if`/`assert_nonzero`/`assert_contains`, recording brctl PATH-shim writing to a log).

**Fixture recipe** (per-case sandbox home `i3h`):

```
i3h/Library/Mobile Documents/com~apple~CloudDocs/   the sandbox CloudDocs root (real dir)
  td/f1 f2 …                                        plain fixture files
  escape -> ${sandbox}/outside                      ESCAPE: lexically in, resolves out
  linkdir -> ${sandbox}/outside                     mid-path escape parent
i3h/Documents -> <CloudDocs>/documents              provisioned-machine shape (symlink INTO root)
${sandbox}/outside/sub/…                            escape landing zone (must exist so cd succeeds)
rootlink -> <CloudDocs>                             symlinked-ROOT fixture for the override test
```

- **brctl shim**: extend the I2 shim — records `download`/`evict` argv to `$BRCTL_LOG` as today,
  and for `status` prints the contents of `$BRCTL_STATUS_FILE` (test writes a canned
  `<com.apple.CloudDocs[1] ... caught-up ...>` line, or one without `caught-up`, per case).
- **stub helper** (`ICLOUD_HELPER` env-shim): a bash script mapping basename → state, e.g.
  `case` on `*_UP*` → `uploaded`, `*_WAIT*` → `not-uploaded`, `.DS_Store|*_NOTIN*` →
  `not-in-icloud`, else `error`; prints `<state>\t<path>` per argv arg (tab via `printf`),
  exit 0/1 like the real helper (the lane must IGNORE the rc — see assertion below).
- **sandbox `ICLOUD_ROOT`**: default derivation via sandbox `HOME` covers most cases (the root is
  `$HOME/Library/Mobile Documents/…` and `HOME` is already overridden). The explicit
  `ICLOUD_ROOT=…/rootlink` case exercises the env override + root-side resolution.

**Symlink-escape matrix (the HIGH-priority fixtures):**

| # | Invocation target | Expect |
|---|---|---|
| a | `$HOME/Documents` (symlink INTO root) | rc 0; output names the RESOLVED CloudDocs path |
| b | `<CloudDocs>/escape` (lexically in, resolves out) | rc 1; `assert_contains "not under iCloud Drive"`; `$BRCTL_LOG` empty (nothing invoked) — run for BOTH `--icloud-sync-status` and `--icloud-download --apply` |
| c | `<CloudDocs>/linkdir/sub` (mid-path escape) | rc 1, "not under" |
| d | the root itself | rc 0 |
| e | plain subdir `<CloudDocs>/td` | rc 0 |
| f | nonexistent path | rc 1, "no such path" |
| g | `ICLOUD_ROOT=…/rootlink` + target under the REAL root | rc 0 (root resolved before compare — proves the override cannot create a lexical/physical mismatch) |
| h | `ICLOUD_ROOT=…/rootlink` + escape target (b) | rc 1 (override does not weaken confinement) |

### 4.2 Sync-status behavior asserts (I3, continued)

Fixture: 2 dataless (stat-shim, known sizes) + 2 `_UP` + 1 `_WAIT` + 1 `.DS_Store` + 1 error-name.

- summary counts and byte totals appear (grep the numbers; output is human but line-bounded).
- **rc-independence**: the stub helper exits 1 (mixed set) — sync-status still exits **0** and
  the counts are right (chunk rc is ignored; stdout parsed).
- helper ABSENT (`ICLOUD_HELPER=/nonexistent`) → rc 0, `upload split unknown … make helper` warn.
- health line: canned not-caught-up `brctl status` → the wedge warning appears; caught-up → no warn.
- read-only: no lock dir created, `$BRCTL_LOG` shows no `download`/`evict` (a `status` query is
  allowed), before/after find-snapshot of the fixture tree is byte-identical.

### 4.3 Download-gate asserts (I3, continued)

The **margin env override is the primary df seam** (deterministic on any machine, real `df`):

- `ICLOUD_DL_MARGIN_BYTES=4611686018427387904` (2^62) → dry-run AND `--apply` both rc 1,
  `assert_contains "refusing to download"`, zero `brctl download` recorded.
- `ICLOUD_DL_MARGIN_BYTES=0` → passes; dataless-only: fixture [1 dataless + 1 materialized] →
  exactly 1 `brctl download`, targeting the dataless file.
- plan header present in dry-run (`download plan:` + count + bytes); zero downloads in dry-run.
- nothing-dataless fixture → rc 0, "nothing to download".
- **df-failure fail-closed**: PATH-shim `df` that exits 1 → rc 1, "cannot determine free space".
  (The df PATH-shim is used ONLY for this case; everything else uses real df + margin override.)

### 4.4 I2 updates (devops-coder — existing tests the new behavior breaks)

- **stat shim** (I2k, ~L2346): now must answer the combined format. Replace the shim body with:

  ```sh
  #!/bin/bash
  for last; do :; done
  case "$last" in
    *DATALESS*)
      case "$*" in
        *"%z %Sf"*) echo "5 dataless"; exit 0 ;;
        *)          echo "dataless";   exit 0 ;;
      esac ;;
  esac
  exec /usr/bin/stat "$@"
  ```

- **I2 (l) download subtest** (~L2364): fixture files `g1`/`g2` are materialized, so the
  dataless-only filter now downloads **nothing**. Rewrite: name the fixtures `g1_DATALESS`/
  `g2_DATALESS`, run with the stat shim on PATH and `ICLOUD_DL_MARGIN_BYTES=0` (machine-
  independent: real df must not flake the gate on a nearly-full host), keep the two asserts
  (2 downloads, no evict).
- Evict subtests: unchanged (evict body untouched; resolver accepts the same real-dir fixtures).

### 4.5 `tests/tui/` (backend-coder)

No new files; two extensions:

- `test_plan.py`: argv matrix rows for `icloud-sync-status` mirroring the existing
  `icloud-status` coverage — `plan_action(path, "icloud-sync-status")` →
  `["--icloud-sync-status", path]`; `read_only` is True in `ACTIONS`; no consent flag ever
  appears for it (assert `--i-understand-data-loss-risk` absent for every non-evict op —
  the existing loop-style assert should pick the new op up automatically; verify it iterates
  `ACTIONS`).
- `test_model.py::test_ops_for_entry_classes` (~L116): update expected lists to the §3 orders
  (code: 7 ops with `icloud-sync-status` fourth; xdg: 4 ops with it first; local: `[]`).

Integration (SIGINT, round-trip) coverage is unchanged — the new op is read-only capture, the
already-tested path.

---

## 5. Footguns (binding)

**bash 3.2 / shellcheck (`enable=all` minus repo-wide disables):**

- **`local x="$(cmd)"` masks the command's exit status** — `local` is the command, rc always 0.
  Declare `local x` first, assign `x="$(…)" || die` separately (the §2 bodies already do this;
  do not "tidy" them into one line).
- **`cd` under `set -e` inside `$( )`**: the substitution's failure surfaces as the assignment's
  status — every `$(cd … && pwd -P)` assignment MUST carry `|| die` (or `|| var=""` where
  degrade is specified). Never bare.
- **All `cd` targets are absolute** (relative input is `$(pwd)`-joined first) — CDPATH can only
  intercept relative `cd`, so it can never redirect the resolver.
- **Aggregation in the parent shell only**: the find→classify loop and the helper-output loop
  read from TEMPFILES (`done < "$f"`), never `producer | while` — subshell counter writes are
  lost silently (repo invariant #4 / master-trap rule kin).
- **Empty-array expansion under `set -u`**: `${SYNC_CHUNK[@]+"${SYNC_CHUNK[@]}"}` on the helper
  call; `${#arr[@]}` is safe on declared-empty arrays and guards the early return.
- **Chunked helper rc is meaningless** — `|| true` on the exec, aggregate stdout lines; and
  count-mismatch lines are added to `SYNC_N_ERR` (fail-closed accounting).
- **Tab handling**: `tab="$(printf '\t')"` then `${line%%"$tab"*}` — no literal-tab source
  bytes (editor-fragile), no `$'\t'` reliance in strings that shellcheck's dialect flags.
- **`stat -f '%z %Sf'` size-FIRST**: `%Sf` can be empty; a trailing empty field is safe, a
  leading one shifts the parse. Numeric-validate size (`case … ''|*[!0-9]*`) before arithmetic.
- **df parsing**: locate Available relative to the `%` Capacity field (§2.3), never `$4`
  fixed — device/mount names can contain spaces. Numeric-validate; download **dies** on
  unparseable df (mutation gate), sync-status **warns** (read-only report).
- **`grep -m1` after a pipe, not `| head`** (SIGPIPE-141 under pipefail); every
  `$(… | grep …)` assignment carries `|| var=""` (no-match rc 1).
- **Trailing `[ cond ] && cmd`** as a function's last statement returns 1 on the false path
  (project memory) — the §2 bodies use `if` forms or end with explicit `return 0`; keep that.
- No backticks in quoted strings/heredocs; no `[[ ]]`, `mapfile`, `<()`, `readlink -f`;
  messages via `log/info/warn`; keep `run()` for `brctl download` only (queries like
  `brctl status`/`df`/`stat` are direct — the dry-run ledger is for mutations).
- shellcheck may flag the SYNC_* globals (SC2034-adjacent, assigned/used across functions) —
  if it does, a targeted `# shellcheck disable` with a comment, not a restructure.

**python (3.9 floor):**

- Dict + two list literals only. No new imports, no signature changes, no `match`/`|`-unions.
- Menu keys: `ops_for_entry` for code is now 7 entries — still within the `1-9` dispatch in
  `_action_menu`; do NOT grow past 9 without touching that loop (not this PR).

---

## 6. Reasoning chain

- **Resolve-then-confine, both sides** — *because* the TUI hands `$HOME/<localName>` and on a
  provisioned machine that is a symlink into CloudDocs, so the guard must compare physical
  paths; *which required* resolving the ROOT too (a physical target can never prefix-match a
  lexical root — `/tmp` vs `/private/tmp` — and a resolved-root compare is also what makes the
  env override safe), *which required* an existence check before the compare (you cannot `cd`
  into nothing), flipping the old check order — accepted as a message-level behavior delta.
- **Final-component file symlinks not followed** — *because* a bash-3.2 readlink loop adds
  complexity to a safety guard, and every consumer enumerates via `find -type f` (no `-H/-L`),
  so an admitted out-of-root file symlink is provably inert: no out-of-root path can reach
  `brctl`/`stat`/helper. Fail-closed in the other direction (in-root file via out-of-root
  parent is refused).
- **`ICLOUD_ROOT` override ratified** — *because* smoke needs a root it owns, and the override
  adds no authority an env-controlling caller lacks (`HOME`, `PATH`, `ICLOUD_HELPER` are already
  env); the resolved-root compare + die-on-unresolvable-root means an override can relocate the
  sandbox, never widen production confinement.
- **Distinct `--icloud-sync-status` flag** — *because* `set_mode` refuses two lanes per run, so
  a `--status` modifier on an `--icloud-sync` lane is structurally the bug `--porcelain`
  avoided; symmetry with the existing trio keeps the TUI's ACTIONS table uniform.
- **Chunk stdout, ignore rc** — *because* ARG_MAX bounds one exec, chunking breaks the helper's
  whole-set exit-code contract, so per-line stdout (parse-stable by design) is the only honest
  aggregate; *which required* fail-closed accounting for unanswered inputs and order-joined
  sizes (helper prints in argv order).
- **Helper only over materialized files** — *because* dataless ⇒ the content is in iCloud by
  construction, so stat alone classifies it; this cuts helper workload and keeps the lane
  usable (degraded) without the compiled helper — matching `--icloud-status`'s optional-helper
  posture for a read-only report.
- **Fixed 1 GiB margin, env-overridable** — *because* the verified incident is a nearly-full
  disk jamming fileproviderd, where percentage margins under-protect small downloads; the env
  knob doubles as the deterministic smoke seam (huge ⇒ refuse, 0 ⇒ pass, real df untouched),
  so the df PATH-shim is needed only for the df-failure fail-closed case.
- **Gate runs in dry-run too** — *because* a preview that hides a refusal invites `--apply`
  into the ENOSPC wedge; rc 1 rides the existing TUI `refused` pane with zero python change.
- **Evict body byte-untouched, resolver shared** — *because* the plan defers the evict-semantics
  change but names the resolver fix as the enabler for ALL TUI iCloud actions; widening evict's
  accept set to symlinked entries changes nothing downstream (helper gate, consent, and
  all-or-nothing are path-shape-independent).

---

## 7. Decisions — RESOLVED

- [x] **D1 — flag naming**: `--icloud-sync-status <path>`, a distinct read-only lane
  (mode `icloud-sync-status`, handler `cmd_icloud_sync_status`). Modifier form rejected
  (one-lane rule).
- [x] **D2 — `ICLOUD_ROOT` env override RATIFIED**: `: "${ICLOUD_ROOT:=…}"`. Test-only posture
  documented in the config comment; confinement preserved because the root itself is
  `cd && pwd -P`-resolved before every compare and an unresolvable root dies. No separate
  "production" switch — the override grants nothing beyond what `HOME`/`PATH`/`ICLOUD_HELPER`
  env control already grants.
- [x] **D3 — resolve-then-confine body** as §2.2: dir targets fully resolved; file targets
  dirname-resolved + basename re-joined; final-component file symlinks not followed (inert by
  the `find -type f` invariant); root resolved; existence-before-confinement ordering.
- [x] **D4 — download margin**: fixed 1 GiB (`ICLOUD_DL_MARGIN_BYTES`, env-overridable); gate
  enforced in dry-run and apply; unparseable df ⇒ die (download) / warn (sync-status).
- [x] **D5 — df test seam**: margin-env-override as the primary seam (real df, deterministic
  both directions); PATH-shimmed `df` only for the df-failure case. No new wrapper function
  beyond `icloud_avail_kb`.
- [x] **D6 — helper batching**: byte-budgeted chunks (128 KiB / 5000 args), stdout-line
  aggregation, rc ignored, order-joined sizes, unanswered inputs counted as errors.
- [x] **D7 — degrade posture (read-only lane)**: sync-status requires only macOS + resolve;
  missing helper ⇒ "upload split unknown" warn; missing brctl ⇒ health "unknown"; always rc 0
  on a completed report. Download keeps its full mutating gate set.
- [x] **D8 — TUI**: one ACTIONS row + `ops_for_entry` order per §3; sync-status leads the
  iCloud block; no porcelain, no consent-gate, no `plan_action`/`run_action` changes.
- [x] **D9 — S2 partition**: devops-coder = provision script + smoke.sh (incl. I2 repairs);
  backend-coder = `xdg_tui.py` + `tests/tui/`; lead = README/CHANGELOG. Zero shared files.

## 8. Known limitations / deferred (recorded, not built)

- A **file** symlinked into CloudDocs from outside (final component) is refused by the resolver
  — acceptable: TUI targets are directories; manual users can pass the real CloudDocs path.
- Bulk skip-and-report **evict** (the `.DS_Store` wedge fix) — deferred by user decision; needs
  its own diff-spec + adversarial review of the skip-vs-abort matrix.
- `brctl monitor --wait-uploaded` bounded-wait lane — possible future companion to the
  "waiting on iCloud" count; not shipped (no honest `sync-up` exists).
- Verb-taking Swift helper (`evict`-in-one-process, closes the check/evict TOCTOU) — recorded
  research option, rejected for now (keeps the compiled surface tiny).
- sync-status per-directory rollups / TUI dashboard badges — out of scope (verbatim pane only).
