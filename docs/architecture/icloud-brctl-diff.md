# Slice 5 — iCloud `brctl` true-offload sub-mode + compiled upload-state helper

**Phase:** PACT Architect (apply-ready design) · **Branch:** `feature/icloud-brctl`
**Upstream:** PREPARE research `docs/preparation/research-icloud-brctl.md` (Task #82), teachback Task #83.
**Builds on merged slices 1–4.** home-tree.sh + lib FROZEN; offload/dotfiles lanes, rclone filter,
`HOMETREE_KEYS`, `XDG_DIR_REGISTRY`, `CLOUDXDG_KEYS`, existing smoke assertions — **UNTOUCHED**.

> **USER DECISION (accepted):** build `evict` WITH a compiled Swift helper that reads the only
> authoritative upload signal (`NSURLUbiquitousItemIsUploadedKey`). This deliberately breaks the
> "stock bash 3.2, no compiled deps" stance — **for the evict path only**. `--icloud-status` and
> `--icloud-download` stay stock and always work.
>
> **NOT the default space-freeing path.** Per the research, the **rclone-remote offload** (slice 2)
> already frees space *safely* (it verifies durable upload with `rclone check --download` before
> dropping local). iCloud evict is the strictly-riskier, **secondary** convenience for iCloud-native
> data that is already synced. The design keeps it heavily gated and clearly secondary.

---

## 0. Files touched / added

| File | Change |
|---|---|
| `bin/icloud-uploaded.swift` | **NEW** — the upload-state helper *source* (committed; compiled at `make` time, binary never checked in) |
| `Makefile` | **NEW `helper` target** — `swiftc bin/icloud-uploaded.swift → bin/icloud-uploaded` (graceful no-op when `swiftc` absent) |
| `.gitignore` | add `bin/icloud-uploaded` (the compiled binary) |
| `bin/cloud-xdg-provision.sh` | new lane: config consts + `--icloud-status/-download/-evict` + `--i-understand-data-loss-risk`; gates; dispatch (the bash path only *uses* the built binary — no `swiftc`) |
| `tests/smoke.sh` | NEW coverage via `brctl` PATH-shim + `ICLOUD_HELPER` helper-shim (real evict / live iCloud NOT testable) |
| lib / home-tree.sh / offload / dotfiles / rclone filter / registry | **UNTOUCHED** |

> **Build model (lead-FINAL, Task #84 review):** a **`make helper` target** compiles the Swift source
> to `bin/icloud-uploaded` (binary `.gitignore`d, never committed). The bash evict path only checks for
> and *runs* the built binary — **`swiftc` stays out of the bash path** (cleaner separation). `swiftc`
> absent at build ⇒ no binary ⇒ `--icloud-evict` refuses at runtime; `status`/`download` unaffected.
> *(This reverses the interim compile-on-demand call; make-target is the final model.)*

---

## 1. The compiled upload-state helper — `bin/icloud-uploaded.swift`

**Contract (load-bearing, FAIL CLOSED):**
- **argv:** one or more file paths.
- **stdout:** one line per path — `<state>\t<path>`, `state ∈ {uploaded, not-uploaded, not-in-icloud, error}`.
- **exit code:** `0` **iff every** argv path is `uploaded` (safe to evict); `1` if any path is
  not-uploaded / not-in-icloud / unreadable; `2` = usage error. Any read failure or nil/unknown
  resource value ⇒ treated as **not** uploaded (fail closed).

```swift
import Foundation
// icloud-uploaded — reports iCloud upload state per path. FAIL CLOSED.
// exit 0 = EVERY argv path is fully uploaded (safe to evict); 1 = at least one is not / error; 2 = usage.
let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty {
    FileHandle.standardError.write(Data("usage: icloud-uploaded <path>...\n".utf8)); exit(2)
}
let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
                                 .ubiquitousItemIsUploadingKey, .ubiquitousItemDownloadingStatusKey]
var allSafe = true
for path in args {
    let url = URL(fileURLWithPath: path)
    var state = "error"
    do {
        let v = try url.resourceValues(forKeys: keys)
        if v.isUbiquitousItem != true { state = "not-in-icloud"; allSafe = false }
        else if v.ubiquitousItemIsUploaded == true { state = "uploaded" }   // Optional<Bool>; nil ⇒ else
        else { state = "not-uploaded"; allSafe = false }
    } catch { state = "error"; allSafe = false }                            // FAIL CLOSED
    print("\(state)\t\(path)")
}
exit(allSafe ? 0 : 1)
```

Notes: the helper handles **files** only (the bash side enumerates a directory into files). A dataless
(already-evicted) file reports `uploaded` (that is why it could be evicted) — harmless; the bash side
skips it anyway. `.ubiquitousItemIsUploaded` is `Optional<Bool>`; `== true` makes `nil` ⇒ not-uploaded.

## 2. `Makefile` — `helper` target (build step; `swiftc` stays OUT of the bash path)

```make
.PHONY: lint test install version helper
...
## helper: compile the iCloud upload-state helper (macOS + Xcode CLT). OPTIONAL — only --icloud-evict
##         needs it. If swiftc is absent, the binary is NOT produced and evict refuses at runtime.
helper:
	@if command -v swiftc >/dev/null 2>&1; then \
	   swiftc -O -o bin/icloud-uploaded bin/icloud-uploaded.swift && chmod +x bin/icloud-uploaded && \
	   echo "built bin/icloud-uploaded"; \
	 else \
	   echo "swiftc not found (install Xcode Command Line Tools) — skipping helper; --icloud-evict will refuse until built." >&2; \
	 fi
```

- **Do NOT check in the binary.** `.gitignore` gains `bin/icloud-uploaded`.
- The target **exits 0 even when `swiftc` is absent** (graceful — never breaks `make` on Linux/CI).
- `make lint` is unaffected (`.swift` isn't shell; the recipe is POSIX `sh`, `command -v`-portable).
- `make helper` is **not** wired into `install`/default — evict is opt-in.
- **The bash side never invokes `swiftc`** — it only checks for and runs the built binary (§3, §7).
  This is the clean-separation rationale for choosing the make-target over compile-on-demand.

## 3. `bin/cloud-xdg-provision.sh` — config, arg-parse, usage, dispatch

Config consts (near the other lane configs). `ICLOUD_HELPER` is **env-overridable** so tests can shim it:

```sh
ICLOUD_ROOT="$HOME/Library/Mobile Documents/com~apple~CloudDocs"   # reuse existing iCloud recognition
: "${ICLOUD_HELPER:=$__self_dir/icloud-uploaded}"                  # built binary beside the script; env-overridable for tests
ICLOUD_CONFIRM=0                                                    # set by --i-understand-data-loss-risk
```

The bash path never compiles — it only checks `[ -x "$ICLOUD_HELPER" ]` and runs it. `make helper`
produces `bin/icloud-uploaded`; tests set `ICLOUD_HELPER` to a shim.

Arg-parse (beside the other value-taking flags):

```sh
    --icloud-status)               set_mode icloud-status;   shift; MODE_ARG="${1:?--icloud-status needs a path}" ;;
    --icloud-download)             set_mode icloud-download; shift; MODE_ARG="${1:?--icloud-download needs a path}" ;;
    --icloud-evict)                set_mode icloud-evict;    shift; MODE_ARG="${1:?--icloud-evict needs a path}" ;;
    --i-understand-data-loss-risk) ICLOUD_CONFIRM=1 ;;
```

`usage()` (new block; leads with the safer-alternative framing):

```
iCloud (macOS only; paths under ~/Library/Mobile Documents/com~apple~CloudDocs):
  --icloud-status <path>    Report in-iCloud / dataless / uploaded state (read-only).
  --icloud-download <path>  Materialize (hydrate) dataless files — only ADDS data, reversible.
  --icloud-evict <path>     Free local space by evicting FULLY-UPLOADED files to dataless
                            placeholders. Requires the compiled upload-state helper (make helper)
                            AND --i-understand-data-loss-risk. dry-run unless --apply.
                            NOTE: for guaranteed space-freeing prefer the rclone offload (--offload);
                            it verifies durable upload before dropping local.
```

Dispatch cases:

```sh
    icloud-status)    cmd_icloud_status   "$MODE_ARG" ;;
    icloud-download)  cmd_icloud_download "$MODE_ARG" ;;
    icloud-evict)     cmd_icloud_evict    "$MODE_ARG" ;;
```

## 4. Shared gates (cheap-first)

```sh
icloud_guard_macos() { [ "$PLATFORM" = "macos" ] || die "iCloud modes are macOS-only (this is $PLATFORM)."; }

# Normalize $1 to an absolute path and require it under $ICLOUD_ROOT. bash-3.2 (no readlink -f).
icloud_resolve_under_root() {          # sets global ICLOUD_TARGET
  case "$1" in /*) ICLOUD_TARGET="$1" ;; *) ICLOUD_TARGET="$(pwd)/$1" ;; esac
  case "$ICLOUD_TARGET" in
    "$ICLOUD_ROOT"|"$ICLOUD_ROOT"/*) : ;;
    *) die "path is not under iCloud Drive ($ICLOUD_ROOT): $ICLOUD_TARGET" ;;
  esac
  [ -e "$ICLOUD_TARGET" ] || die "no such path: $ICLOUD_TARGET"
}

# True (0) if already dataless (evicted / no local extents) — evict is a no-op; status reports it.
icloud_is_dataless() { case "$(stat -f '%Sf' "$1" 2>/dev/null)" in *dataless*) return 0 ;; *) return 1 ;; esac; }

icloud_require_brctl() { command -v brctl >/dev/null 2>&1 || die "brctl not found (macOS iCloud tool). Cannot proceed."; }
```

## 5. `cmd_icloud_status` (read-only — no helper required, no `begin_mutating_mode`)

```sh
cmd_icloud_status() {                    # $1 = path
  icloud_guard_macos
  icloud_resolve_under_root "$1"
  local have_helper=0; [ -x "$ICLOUD_HELPER" ] && have_helper=1   # read-only: use the built binary if present
  log "iCloud status under: $ICLOUD_TARGET (read-only)"
  # enumerate files (a file resolves to itself); temp file avoids process-substitution (3.2).
  local ftmp f ubi datal upl
  ftmp="$(mktemp "${TMPDIR:-/tmp}/xdg-icloud.XXXXXX")" || die "cannot create temp file"
  find "$ICLOUD_TARGET" -type f > "$ftmp" 2>/dev/null || true
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if icloud_is_dataless "$f"; then datal="dataless"; else datal="materialized"; fi
    case "$(mdls -name kMDItemFSIsUbiquitous -raw "$f" 2>/dev/null)" in 1|"(1)"|true) ubi="in-icloud" ;; *) ubi="local?" ;; esac
    if [ "$have_helper" -eq 1 ]; then
      if "$ICLOUD_HELPER" "$f" >/dev/null 2>&1; then upl="uploaded"; else upl="not-uploaded"; fi
    else upl="unknown(helper not built — run 'make helper', or install Xcode CLT)"; fi
    printf '  %-12s %-14s %-24s %s\n' "$ubi" "$datal" "$upl" "$f"
  done < "$ftmp"
  rm -f "$ftmp"
}
```

## 6. `cmd_icloud_download` (mutates by ADDING data — reversible, safe; no helper)

```sh
cmd_icloud_download() {                  # $1 = path
  begin_mutating_mode
  icloud_guard_macos; icloud_resolve_under_root "$1"; icloud_require_brctl
  local ftmp f
  ftmp="$(mktemp "${TMPDIR:-/tmp}/xdg-icloud.XXXXXX")" || die "cannot create temp file"
  find "$ICLOUD_TARGET" -type f > "$ftmp" 2>/dev/null || true
  [ -s "$ftmp" ] || { rm -f "$ftmp"; info "no files to download under: $ICLOUD_TARGET"; return 0; }
  while IFS= read -r f; do [ -z "$f" ] && continue; run brctl download "$f"; done < "$ftmp"
  rm -f "$ftmp"
  info "Download (hydrate) complete."
}
```

`run` prints `[dry-run]`/`[run]` and makes `brctl` mockable via PATH shim.

## 7. `cmd_icloud_evict` — THE fail-closed gate (load-bearing)

Gate order = cheapest → most expensive, all fail-closed. Evict NOTHING unless **every** gate passes.

```sh
cmd_icloud_evict() {                     # $1 = path
  begin_mutating_mode
  icloud_guard_macos                                   # (1) macOS only
  icloud_resolve_under_root "$1"                       # (2) path under CloudDocs (+ exists)
  icloud_require_brctl                                 # (3) brctl present
  [ -x "$ICLOUD_HELPER" ] || die "upload-state helper not built ($ICLOUD_HELPER).
  Run 'make helper' (needs Xcode Command Line Tools). Without it, upload state can't be verified, so
  evict is refused. For guaranteed space-freeing use the rclone offload: '$SELF --offload <dir>'."   # (4) GRACEFUL DEGRADE — no swiftc in the bash path; refuse if the binary is absent
  [ "$ICLOUD_CONFIRM" -eq 1 ] || die "evict can lose data if 'Optimize Mac Storage' is off or files
  aren't uploaded; that OS setting has no reliable programmatic check. Re-run with
  --i-understand-data-loss-risk to proceed. (Safer alternative: '$SELF --offload <dir>'.)"           # (5) explicit consent

  # Build the candidate list: every non-dataless file (dataless = already evicted, skip as no-op).
  # bash-3.2: temp file + while-read + indexed-array append (no mapfile / no process-substitution).
  local ftmp f; local candidates=()
  ftmp="$(mktemp "${TMPDIR:-/tmp}/xdg-icloud.XXXXXX")" || die "cannot create temp file"
  find "$ICLOUD_TARGET" -type f > "$ftmp" 2>/dev/null || true
  while IFS= read -r f; do [ -z "$f" ] && continue; icloud_is_dataless "$f" && continue; candidates+=("$f"); done < "$ftmp"
  rm -f "$ftmp"
  [ "${#candidates[@]}" -gt 0 ] || { info "nothing to evict (all already dataless or empty)."; return 0; }

  # (6) THE UPLOAD GATE — helper must confirm EVERY candidate uploaded (rc 0). Read-only; run in
  #     dry-run too for an accurate preview. Fail-closed: any not-uploaded/error ⇒ evict NOTHING.
  local hout; hout="$(mktemp "${TMPDIR:-/tmp}/xdg-icloud.XXXXXX")" || die "cannot create temp file"
  if ! "$ICLOUD_HELPER" "${candidates[@]}" > "$hout" 2>/dev/null; then
    warn "refusing to evict — NOT every target file is confirmed fully-uploaded (fail-closed):"
    grep -v '^uploaded	' "$hout" 2>/dev/null | sed 's/^/    /' >&2 || true
    rm -f "$hout"
    die "evict aborted. Wait for iCloud upload (check '$SELF --icloud-status <path>'), or use
  '$SELF --offload <dir>' for a verified space-free. Nothing was evicted."
  fi
  rm -f "$hout"

  # (7) EVICT (apply only; dry-run prints). Per-file (directory recursion is undocumented — research §1).
  local c
  for c in "${candidates[@]}"; do run brctl evict "$c"; done
  info "Evicted ${#candidates[@]} fully-uploaded file(s) to dataless placeholders. Re-download with
  '$SELF --icloud-download <path>' or by opening them."
}
```

**No `*_ACTIVE` trap flag** (unlike offload's rm window): each `brctl evict` is independently gated
(the file is proven uploaded) and **reversible** (re-download from iCloud), so an interrupt mid-batch
just leaves some files evicted — all safe. `begin_mutating_mode`'s lock still guards concurrency.

**ARG_MAX note:** passing all candidates in one helper exec matches the helper's multi-path contract
and avoids `xargs` empty-input / multi-batch-rc footguns. For a pathologically huge tree this could hit
`argument list too long`; batching the helper call is a future refinement (flagged §10). A manual
convenience op on a single dir is well within limits.

## 8. Testability (mockable; live iCloud is NOT testable)

- **`brctl` via `run()` + PATH shim:** a shim records `evict`/`download` invocations; smoke asserts
  evict is/ isn't called.
- **helper via `ICLOUD_HELPER` env override:** point it at a shim binary/script that exits 0 (all
  uploaded) or 1 (some not) to exercise the gate both ways — no `swiftc` needed in tests (the bash path
  only runs the binary). Separately, a `make helper` build test can assert the target no-ops cleanly
  when `swiftc` is absent.
- **Gate refusals to smoke** (all must die, and the `brctl` shim must record ZERO `evict` calls):
  not-macOS (PATH-shim `uname`), path outside CloudDocs, helper missing/non-exec, no consent flag,
  helper reports not-uploaded. Plus: dry-run performs no `evict`; happy path evicts only uploaded files;
  already-dataless files are skipped. `cmd_icloud_status`/`download` covered with the shims too.

## 9. Reasoning chain (helper contract + fail-closed gate)

- **A compiled helper is the ONLY way to gate evict safely** — *because* the research establishes the
  sole authoritative upload signal (`NSURLUbiquitousItemIsUploadedKey`) has **no stock CLI surface**,
  and `brctl evict` on an un-uploaded file is undocumented ⇒ assumed data-loss. So the user's accepted
  break (a tiny Swift reader) is exactly what unlocks a *safe* evict; nothing in stock shell can.
- **Helper fails closed (nil/error/not-in-icloud ⇒ not-uploaded, non-zero)** — *because* the whole
  point is to never evict a file whose cloud copy isn't proven; ambiguity must resolve to "don't evict."
- **Graceful degradation, not hard dependency** — *because* the repo's value (status/download) must
  survive on a stock Mac: only evict needs the helper, and its absence *refuses evict* (pointing at the
  safer rclone offload) rather than breaking the tool.
- **Gate order cheap→expensive, evict-nothing-on-any-fail** — macOS/path/brctl/helper-built/consent are
  O(1) refusals before the O(n) per-file upload read; and the upload gate covers the WHOLE candidate set
  before a single `evict`, so a partially-uploaded tree evicts nothing (no per-file interleave that could
  evict the uploaded ones and strand the rest half-done).
- **No trap half-state flag** — *because* each evict is pre-proven-uploaded and reversible; there is no
  "half-moved, unrecoverable" window like offload's `rm`-after-verify, so a mid-batch interrupt is safe.
- **Explicit consent stands in for the undetectable Optimize-Storage state** — *because* that setting
  (which even determines whether evict does anything) has no documented programmatic read; an honest
  `--i-understand-data-loss-risk` beats a fake check.
- **`make helper` build target, `swiftc` OUT of the bash path (lead-final)** — *because* keeping the
  compiler in a build step (not the runtime evict path) is the cleaner separation: the bash side only
  checks `[ -x "$ICLOUD_HELPER" ]` and runs the binary, so the data-loss-critical gate has no compile
  side effect, no `$XDG_CACHE_HOME` writes, and nothing to reason about re: stale caches. The binary is
  `.gitignore`d (never committed); `swiftc` absent at build ⇒ no binary ⇒ evict refuses at runtime
  (graceful), while `status`/`download` still work.

## 10. User-decisions (call-outs)

### Resolved (lead-final, Task #84 review)
- **Helper distribution** = **`make helper` target** → `bin/icloud-uploaded` (binary `.gitignore`d,
  never committed); the bash path only *uses* the built binary (`swiftc` stays out of the evict path).
  *Final call — the lead reversed the interim compile-on-demand decision back to this make-target model.*
- **Toolchain** = **Swift-only**; `swiftc` absent at build ⇒ no binary ⇒ `--icloud-evict` refuses
  (pointing at rclone offload); `--icloud-status`/`--icloud-download` unaffected. No PyObjC fallback.
- **Optimize-Storage confirm** = `--i-understand-data-loss-risk` flag (no reliable programmatic check).
- **Helper source path** = `bin/icloud-uploaded.swift`.

### Still open (minor / for the lead)
- **Ship evict now vs status/download-first** — evict degrades gracefully (refuses without the helper), so
  all three together is safe. If you prefer a smaller first PR, land `--icloud-status` + `--icloud-download`
  (zero new-risk, no helper) first and evict + helper second. **Recommend all-in-one.** Confirm.
- **Future:** batch the helper call for very large trees (ARG_MAX); per-file directory recursion only
  (no `brctl evict <dir>` — undocumented).
