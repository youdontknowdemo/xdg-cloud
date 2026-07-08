# Bulk Skip-and-Report Evict — ARCHITECT diff-spec

**Phase:** PACT Architect · **Status:** CODE gate — coders build exactly what this document specifies.
**Upstream:** approved plan `docs/plans/bulk-evict-plan.md` (safety design SETTLED: order-join +
path-echo + count-match; two-phase rc gate; per-file lstat guard; default change; rc taxonomy;
verbatim report) and PREPARE research `docs/preparation/research-bulk-evict.md` (exact lstat-guard
spec `stat -f '%HT|%Sf|%z|%Fm'` byte-compare; reuse `ICLOUD_CHUNK_MAX_*`; new `drift` skip reason;
skips-are-the-norm report framing; symlink-in-target fixture).
**Companion spec:** `docs/architecture/tui-icloud-sync-diff.md` — its contracts (resolver §2.2,
chunk-flush discipline §2.3, verbatim-pane ruling, consent gate) are binding and **unchanged** here.

---

## 0. What this PR is

`--icloud-evict` changes from all-or-nothing (any not-uploaded candidate ⇒ refuse the whole set —
the `.DS_Store` wedge) to **evict only the individually-proven-`uploaded` subset, skip-and-report
the rest**, as the **default** (user decision 2026-07-07, no opt-in flag). One hard invariant
governs everything below:

> **No file is ever passed to `brctl evict` without individual proof it is `uploaded` — and the
> evict target path always comes from `find`, never from helper stdout.**

Three destruction gates, in order:

1. **Phase 1 — classify + select** (dry-run AND apply): chunked helper exec; NUL records
   ORDER-JOINED back to the argv chunk with a **path-echo byte-equality assertion** and a
   **count-match (both directions)**; builds `EVICT_SET` (paths only ever from the `find`-derived
   candidates) + the mandatory skip report.
2. **Phase 2 — re-gate** (apply only, per phase-1 chunk): re-exec the helper over **exactly that
   chunk's evict subset** and require **rc == 0** — the audited all-or-nothing exit-code contract,
   relocated to the precise set being destroyed. rc≠0 ⇒ skip the whole chunk (`drift`), warn.
3. **Per-file lstat guard** (apply, immediately before each `run brctl evict`): re-confine +
   re-snapshot `stat -f '%HT|%Sf|%z|%Fm'` byte-compare against the selection-time snapshot; any
   mismatch ⇒ skip + warn + tally `drift`, never die mid-sweep.

Phase 1's parser is thereby **non-safety-critical**: a parse bug can only UNDER-select (skip),
never over-evict — only the helper's rc (phase 2) plus the lstat guard authorize destruction.

**Backward-incompatible:** a mixed set now exits **0 with a report** instead of exiting 1.
CHANGELOG must call this out loudly; the "is everything uploaded?" probe moves to
`--icloud-status` / `--icloud-sync-status`.

**Byte-preserved (out of scope to touch):** gates (1)–(5) including both consent surfaces
(`--i-understand-data-loss-risk` CLI flag + the TUI typed-path gate), the gate-(6) dataless
pre-filter and candidate build, `run brctl evict` via `run()`, the no-trap-flag decision,
`bin/icloud-uploaded.swift`, the resolver, the chunk-cap constants and their load guards.

---

## 1. Files touched + S2 partition (zero shared files)

| File | Change | Owner (CODE) |
|---|---|---|
| `bin/cloud-xdg-provision.sh` | EVICT_* globals + 2 new functions (§2.1–2.2); `cmd_icloud_evict` body replacement L2202–2261 (§2.3); `usage()` evict entry L416–420 (§2.4) | **devops-coder** |
| `tests/smoke.sh` | Rewrites: I1(d), I2(i), I2(j2), I3 newline-evict trailer assert (~L2746) (§4.1); new **I4** group (§4.2) | **devops-coder** |
| `bin/xdg_tui.py`, `tests/tui/` | **VERIFY ONLY** — no edits expected (§3) | **backend-coder** |
| `README.md`, `CHANGELOG.md` | behavior + exit-code change callout — **lead** commits | lead |
| `bin/icloud-uploaded.swift`, `Makefile`, `bin/lib/xdg-common.sh`, `bin/home-tree.sh`, `bin/xdg-tui` | **untouched** | — |

**S2 rule:** devops-coder owns all bash; backend-coder verifies (does not edit) all python; the only
cross-surface is the rc taxonomy (0 = completed sweep incl. all-skipped / 1 = gate failure or
structural abort), frozen by this document — it keeps the TUI `interpret_result` wiring at zero
change. Zero shared files.

---

## 2. Bash slice (exact bodies)

### 2.1 Evict-lane globals + skip-line printer (insert after `cmd_icloud_download`, before `cmd_icloud_evict`, ~L2201)

```sh
# --- evict-lane chunked-classify state (globals: bash 3.2 functions cannot return arrays, and
# the aggregation MUST run in the parent shell — the repo's invariant-#4 footgun). EVICT-LOCAL:
# deliberately NOT the SYNC_* globals — the two lanes must never share mutable join state.
# Initialized by cmd_icloud_evict before the walk; flushed by icloud_evict_classify_chunk.
EVICT_CHUNK=()        # pending phase-1 helper argv — a verbatim, lockstep slice of candidates[]
EVICT_CHUNK_BYTES=0   # accumulated argv bytes for the pending chunk
EVICT_SET=()          # proven-uploaded evict targets — paths copied from EVICT_CHUNK, NEVER from helper stdout
EVICT_SNAP=()         # lockstep with EVICT_SET: selection-time `stat -f '%HT|%Sf|%z|%Fm'` snapshot
EVICT_CHUNK_LEN=()    # per flushed phase-1 chunk: how many EVICT_SET entries it contributed (phase-2 partition)
EVICT_N_WAIT=0; EVICT_N_NOTIN=0; EVICT_N_ERR=0; EVICT_N_UNANS=0; EVICT_N_DRIFT=0
EVICT_BYTES=0         # sum of snapshot %z over EVICT_SET (potential-free display)
EVICT_SKIP_HDR=0      # lazy header flag for the skip listing

# Print one skip line (DISPLAY ONLY — no decision ever parses this output; unlike the pre-v0.4.1
# tr|grep diagnostic, a newline embedded in a skipped filename can at worst cosmetically forge an
# extra display line, and the evict decision never reads this surface). Capped at 20 lines per
# reason; the per-reason overflow pointer is printed after phase 1 by cmd_icloud_evict.
icloud_evict_report_skip() {             # $1 = reason  $2 = running count for that reason  $3 = path
  if [ "$EVICT_SKIP_HDR" -eq 0 ]; then
    log "  skipped (NEVER evicted — fail-closed):"
    EVICT_SKIP_HDR=1
  fi
  if [ "$2" -le 20 ]; then
    printf '    %-15s %s\n' "$1" "$3"
  fi
  return 0
}
```

### 2.2 `icloud_evict_classify_chunk` — phase-1 order-join + path-echo + count-match (SAFETY-CRITICAL)

```sh
# PHASE 1: flush the pending chunk through ONE helper exec; ORDER-JOIN each NUL record back to
# EVICT_CHUNK[i] with a PATH-ECHO byte-equality assertion and a COUNT-MATCH in BOTH directions.
# SAFETY MODEL (resolved plan conflict — security's ruling): the evict target is ALWAYS the
# find-derived EVICT_CHUNK[i] (a verbatim lockstep slice of candidates[]); helper stdout supplies
# STATE ONLY. The record's own path field is used exclusively as an ASSERTION (byte-equal or die):
# any desync, forgery, or truncation kills the run before anything is selected. The batch rc does
# not gate selection (mixed sets are NORMAL under subset semantics) — but an rc outside {0,1} is a
# structural failure (usage error / exec failure / signal) => die. Phase 2 re-applies the audited
# rc==0 whole-set contract over exactly the evict subset, so a bug HERE can only ever
# UNDER-select (skip), never over-evict.
icloud_evict_classify_chunk() {
  [ "${#EVICT_CHUNK[@]}" -gt 0 ] || return 0
  local hout rec state echo_path p snap sz rest i n_up hrc tab
  tab="$(printf '\t')"
  hout="$(mktemp "${TMPDIR:-/tmp}/xdg-icloud.XXXXXX")" || die "cannot create temp file"
  # </dev/null: the helper must NEVER read the script's stdin (same sever as icloud_sync_flush_chunk).
  hrc=0
  "$ICLOUD_HELPER" ${EVICT_CHUNK[@]+"${EVICT_CHUNK[@]}"} < /dev/null > "$hout" 2>/dev/null || hrc=$?
  case "$hrc" in
    0|1) : ;;   # 0 = all uploaded, 1 = mixed/none — both NORMAL; selection reads the records
    *) rm -f "$hout"
       die "upload-state helper failed structurally (exit $hrc) — refusing to evict blind. Nothing was evicted." ;;
  esac
  i=0; n_up=0
  while IFS= read -r -d '' rec; do
    [ -z "$rec" ] && continue
    if [ "$i" -ge "${#EVICT_CHUNK[@]}" ]; then
      rm -f "$hout"
      die "upload-state helper produced MORE records than argv paths (contract violation — wrong ICLOUD_HELPER?). Nothing was evicted."
    fi
    p="${EVICT_CHUNK[$i]}"                # the find-derived path — the ONLY evict-target source
    state="${rec%%"$tab"*}"
    echo_path="${rec#*"$tab"}"
    if [ "$echo_path" != "$p" ]; then     # PATH-ECHO: byte equality, or the join is broken
      rm -f "$hout"
      die "upload-state helper record #$((i + 1)) does not echo its argv path (join desync — refusing to trust ANY answer). Nothing was evicted."
    fi
    case "$state" in
      uploaded)
        snap="$(stat -f '%HT|%Sf|%z|%Fm' -- "$p" 2>/dev/null)" || snap=""
        EVICT_SET+=("$p"); EVICT_SNAP+=("$snap")
        rest="${snap#*|}"; rest="${rest#*|}"; sz="${rest%%|*}"
        case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
        EVICT_BYTES=$((EVICT_BYTES + sz))
        n_up=$((n_up + 1)) ;;
      not-uploaded)
        EVICT_N_WAIT=$((EVICT_N_WAIT + 1))
        icloud_evict_report_skip not-uploaded "$EVICT_N_WAIT" "$p" ;;
      not-in-icloud)
        EVICT_N_NOTIN=$((EVICT_N_NOTIN + 1))
        icloud_evict_report_skip not-in-icloud "$EVICT_N_NOTIN" "$p" ;;
      *)
        EVICT_N_ERR=$((EVICT_N_ERR + 1))
        icloud_evict_report_skip helper-error "$EVICT_N_ERR" "$p" ;;
    esac
    i=$((i + 1))
  done < "$hout"
  rm -f "$hout"
  if [ "$i" -eq 0 ]; then
    die "upload-state helper produced no output for ${#EVICT_CHUNK[@]} candidate(s) — refusing to evict blind. Nothing was evicted."
  fi
  if [ "$i" -ne "${#EVICT_CHUNK[@]}" ]; then
    die "upload-state helper answered $i of ${#EVICT_CHUNK[@]} candidate(s) (count mismatch — truncated output?). Nothing was evicted."
  fi
  EVICT_CHUNK_LEN+=("$n_up")
  EVICT_CHUNK=(); EVICT_CHUNK_BYTES=0
  return 0
}
```

Parse-edge behavior (all fail-closed, verified against the parameter-expansion semantics):

| Record shape | `state` | `echo_path` | Outcome |
|---|---|---|---|
| `uploaded\t<argv path>` | `uploaded` | argv path | selected |
| path contains a tab (`uploaded\t/a\tb`) | `uploaded` | `/a\tb` (strip through FIRST tab only) | correct join |
| path contains a newline | one NUL record; echo compares the whole field | | correct join |
| forged record (`not-uploaded\t<path>\nuploaded\t<victim>`) | `not-uploaded` | `<path>\nuploaded\t<victim>` ≠ argv path | **die** (path-echo) |
| no tab at all (garbage `G`) | `G` | `G` (`#*"$tab"` no-match returns rec unchanged) | echo ≠ path ⇒ die; if `G` byte-equals the path ⇒ `*` ⇒ helper-error skip |
| empty state (`\t<path>`) | `` | path | `*` ⇒ helper-error skip |
| truncated final record (no trailing NUL) | dropped by `read -d ''` | | count deficit ⇒ **die** |

### 2.3 `cmd_icloud_evict` — full replacement of L2202–2261

Gate lines marked **(unchanged bytes)** are copied verbatim from the current file — do not
re-word them (the smoke suite asserts their message text).

```sh
# --icloud-evict <path>: evict local copies of files INDIVIDUALLY PROVEN fully-uploaded to
# dataless placeholders; SKIP-AND-REPORT everything else (fail-closed PER FILE — the .DS_Store
# wedge fix). Gates (1)-(5) unchanged. Destruction is triple-gated:
#   phase 1 (dry-run + apply): chunked helper classify — order-join + path-echo + count-match
#            builds EVICT_SET (targets only ever from find) + the mandatory skip report;
#   phase 2 (apply only, per phase-1 chunk): re-exec the helper over EXACTLY that chunk's evict
#            subset and require rc==0 (the audited all-or-nothing exit-code contract, relocated
#            to the destroyed set) — rc!=0 => the whole chunk is skipped as drift, never evicted;
#   per-file (apply, immediately before each brctl evict): re-confine + lstat re-snapshot
#            byte-compare (type|flags|size|fractional-mtime) — any drift => skip+warn, never die.
# rc: 0 = completed sweep (INCLUDING all-skipped); 1 = gate failure / structural abort.
# No trap flag (unchanged decision): every evict is individually pre-proven uploaded AND
# reversible (re-download), so a mid-batch interrupt is safe.
cmd_icloud_evict() {                     # $1 = path
  begin_mutating_mode
  icloud_guard_macos                                   # (1) macOS only            (unchanged bytes)
  icloud_resolve_under_root "$1"                       # (2) under CloudDocs       (unchanged bytes)
  icloud_require_brctl                                 # (3) brctl present         (unchanged bytes)
  [ -x "$ICLOUD_HELPER" ] || die "upload-state helper not built ($ICLOUD_HELPER).
  Run 'make helper' (needs Xcode Command Line Tools). Without it, upload state can't be verified, so
  evict is refused. For guaranteed space-freeing use the rclone offload: '$SELF --offload <dir>'."   # (4) (unchanged bytes)
  [ "$ICLOUD_CONFIRM" -eq 1 ] || die "evict can lose data if 'Optimize Mac Storage' is off or files
  aren't uploaded; that OS setting has no reliable programmatic check. Re-run with
  --i-understand-data-loss-risk to proceed. (Safer alternative: '$SELF --offload <dir>'.)"           # (5) (unchanged bytes)

  # (6) candidate list = every NON-dataless file (dataless = already evicted, skip as a no-op).
  # bash 3.2: temp file + while-read + indexed-array append (no mapfile / no process-substitution).
  local ftmp f; local candidates=()
  ftmp="$(mktemp "${TMPDIR:-/tmp}/xdg-icloud.XXXXXX")" || die "cannot create temp file"
  # NUL-delimited: a newline-split path could never pass the upload gate, but must not
  # poison the candidate list either (read mechanism only — gate logic unchanged).
  find "$ICLOUD_TARGET" -type f -print0 > "$ftmp" 2>/dev/null || true
  while IFS= read -r -d '' f; do [ -z "$f" ] && continue; icloud_is_dataless "$f" && continue; candidates+=("$f"); done < "$ftmp"
  rm -f "$ftmp"
  [ "${#candidates[@]}" -gt 0 ] || { info "nothing to evict (all already dataless or empty)."; return 0; }

  # (7) PHASE 1 — classify + select (dry-run AND apply). The skip report is MANDATORY and prints
  # BEFORE any evict, both modes (operator-model safety: never destroy after a silent plan).
  log "iCloud evict under: $ICLOUD_TARGET (evicts ONLY individually-proven-uploaded files; others skipped)"
  EVICT_CHUNK=(); EVICT_CHUNK_BYTES=0
  EVICT_SET=(); EVICT_SNAP=(); EVICT_CHUNK_LEN=()
  EVICT_N_WAIT=0; EVICT_N_NOTIN=0; EVICT_N_ERR=0; EVICT_N_UNANS=0; EVICT_N_DRIFT=0
  EVICT_BYTES=0; EVICT_SKIP_HDR=0
  local idx=0
  while [ "$idx" -lt "${#candidates[@]}" ]; do
    f="${candidates[$idx]}"
    EVICT_CHUNK+=("$f")
    EVICT_CHUNK_BYTES=$((EVICT_CHUNK_BYTES + ${#f} + 1))
    idx=$((idx + 1))
    if [ "$EVICT_CHUNK_BYTES" -ge "$ICLOUD_CHUNK_MAX_BYTES" ] \
       || [ "${#EVICT_CHUNK[@]}" -ge "$ICLOUD_CHUNK_MAX_ARGS" ]; then
      icloud_evict_classify_chunk
    fi
  done
  icloud_evict_classify_chunk
  # per-reason overflow pointers (the listing above is capped at 20 lines per reason)
  if [ "$EVICT_N_WAIT" -gt 20 ]; then
    printf '    ... and %d more not-uploaded (see %s --icloud-status)\n' "$((EVICT_N_WAIT - 20))" "$SELF"
  fi
  if [ "$EVICT_N_NOTIN" -gt 20 ]; then
    printf '    ... and %d more not-in-icloud (see %s --icloud-status)\n' "$((EVICT_N_NOTIN - 20))" "$SELF"
  fi
  if [ "$EVICT_N_ERR" -gt 20 ]; then
    printf '    ... and %d more helper-error (see %s --icloud-status)\n' "$((EVICT_N_ERR - 20))" "$SELF"
  fi
  local n_up n_skip n_evicted=0
  n_up="${#EVICT_SET[@]}"
  info "evict plan: $n_up of ${#candidates[@]} candidate file(s) proven uploaded — $(icloud_fmt_bytes "$EVICT_BYTES") potential free*"
  info "*potential: with 'Optimize Mac Storage' OFF, evict frees nothing (no programmatic check)."

  # (8) EVICT. Dry-run: ledger only (run() prints, never executes — invariant #3); phase 2 and
  # the per-file guard are apply-only (they exist to protect the mutation, and re-stat'ing a
  # plan-only pass would just narrate a window nobody is about to use).
  if [ "$DRY_RUN" -eq 1 ]; then
    local c
    for c in ${EVICT_SET[@]+"${EVICT_SET[@]}"}; do run brctl evict "$c"; done
  else
    local base=0 k=0 len j sub c snap now
    while [ "$k" -lt "${#EVICT_CHUNK_LEN[@]}" ]; do
      len="${EVICT_CHUNK_LEN[$k]}"
      k=$((k + 1))
      if [ "$len" -gt 0 ]; then
        sub=(); j="$base"
        while [ "$j" -lt $((base + len)) ]; do sub+=("${EVICT_SET[$j]}"); j=$((j + 1)); done
        # PHASE 2 RE-GATE: the audited whole-set rc==0 contract, over EXACTLY this chunk's
        # subset, seconds before its evict loop. </dev/null: same stdin sever as phase 1.
        if "$ICLOUD_HELPER" ${sub[@]+"${sub[@]}"} < /dev/null > /dev/null 2>&1; then
          j="$base"
          while [ "$j" -lt $((base + len)) ]; do
            c="${EVICT_SET[$j]}"; snap="${EVICT_SNAP[$j]}"; j=$((j + 1))
            # PER-FILE GUARD (TOCTOU residue): re-confine, then one lstat carrying all four
            # checks — type (Regular File, not a symlink swap: stat(1) uses lstat(2) by
            # default), flags (not dataless), size, and FRACTIONAL mtime (%Fm, ns resolution:
            # a same-second same-size rewrite cannot slip past). Byte-compare to the
            # selection-time snapshot; the compare subsumes the type/flags checks on the
            # CURRENT stat when the snapshot itself is a regular, non-dataless one.
            case "$c" in
              "$ICLOUD_TARGET"|"$ICLOUD_TARGET"/*) : ;;
              *) EVICT_N_DRIFT=$((EVICT_N_DRIFT + 1))
                 warn "skipped (drift): no longer under $ICLOUD_TARGET: $c"
                 continue ;;
            esac
            case "$snap" in
              "Regular File|"*) : ;;
              *) EVICT_N_DRIFT=$((EVICT_N_DRIFT + 1))
                 warn "skipped (drift): selection snapshot unusable: $c"
                 continue ;;
            esac
            case "$snap" in
              *dataless*)
                 EVICT_N_DRIFT=$((EVICT_N_DRIFT + 1))
                 warn "skipped (drift): snapshot flags dataless: $c"
                 continue ;;
            esac
            now="$(stat -f '%HT|%Sf|%z|%Fm' -- "$c" 2>/dev/null)" || now=""
            if [ -z "$now" ] || [ "$now" != "$snap" ]; then
              EVICT_N_DRIFT=$((EVICT_N_DRIFT + 1))
              warn "skipped (drift): file changed since plan (type/flags/size/mtime): $c"
              continue
            fi
            run brctl evict "$c"
            n_evicted=$((n_evicted + 1))
          done
        else
          EVICT_N_DRIFT=$((EVICT_N_DRIFT + len))
          warn "skipped $len file(s): upload state changed since plan (phase-2 re-check failed for this chunk) — re-run to retry."
        fi
      fi
      base=$((base + len))
    done
  fi

  # Machine-stable summary line (smoke greps this exact shape). Printed AFTER the evict loop so
  # the drift count is real (drift is only knowable post-loop; in dry-run it is definitionally 0).
  # `unanswered` is reserved: under the die-on-count-mismatch design it is structurally 0, and it
  # stays in the line so the shape never changes if a future ruling downgrades deficit to skip.
  n_skip=$((EVICT_N_WAIT + EVICT_N_NOTIN + EVICT_N_ERR + EVICT_N_UNANS + EVICT_N_DRIFT))
  info "skipped: $n_skip file(s) — not-uploaded: $EVICT_N_WAIT, not-in-icloud: $EVICT_N_NOTIN, helper-error: $EVICT_N_ERR, unanswered: $EVICT_N_UNANS, drift: $EVICT_N_DRIFT"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would evict the $n_up proven-uploaded file(s) above ($n_skip skipped). Re-run with --apply."
  else
    info "Evicted $n_evicted of $n_up proven-uploaded file(s) to dataless placeholders ($n_skip skipped). Re-download with
  '$SELF --icloud-download <path>' or by opening them."
  fi
  return 0
}
```

Output contract (frozen for smoke — content substrings, `info`'s `  • ` prefix included by
convention, `warn` lines go to stderr):

| Line | Prints via | When |
|---|---|---|
| `iCloud evict under: <resolved> (evicts ONLY individually-proven-uploaded files; others skipped)` | `log` | always (past gates) |
| `  skipped (NEVER evicted — fail-closed):` | `log` | lazily, before the first skip line |
| `    <reason padded %-15s> <path>` | `printf` | per skip, ≤20/reason |
| `    ... and N more <reason> (see <SELF> --icloud-status)` | `printf` | per reason with >20 |
| `evict plan: X of Y candidate file(s) proven uploaded — <bytes> potential free*` | `info` | always |
| `*potential: with 'Optimize Mac Storage' OFF, evict frees nothing (no programmatic check).` | `info` | always |
| `skipped: N file(s) — not-uploaded: A, not-in-icloud: B, helper-error: C, unanswered: D, drift: E` | `info` | always, AFTER the evict loop |
| `[dry-run] would evict the X proven-uploaded file(s) above (N skipped). Re-run with --apply.` | `info` | dry-run trailer |
| `Evicted M of X proven-uploaded file(s) to dataless placeholders (N skipped). Re-download with …` | `info` | apply trailer |

Zero-uploaded sets flow through the same code uniformly (no special case): empty ledger/loop,
`evict plan: 0 of Y`, full summary line, trailer, **rc 0**.

### 2.4 `usage()` — replace the evict entry (L416–420)

```
  --icloud-evict <path>     Free local space by evicting files to dataless placeholders.
                            Evicts ONLY files INDIVIDUALLY proven fully-uploaded; skips and
                            reports the rest (.DS_Store, still-uploading, ...) — a mixed tree
                            no longer refuses (exit 0 + report; probe with --icloud-status).
                            Requires the compiled upload-state helper (make helper) AND
                            --i-understand-data-loss-risk. dry-run unless --apply.
                            NOTE: for guaranteed space-freeing prefer the rclone offload (--offload);
                            it verifies durable upload before dropping local.
```

The `--i-understand-data-loss-risk` entry (L421–422), arg-parse arm (L512–513), and dispatch
entry (L2569 area) are **unchanged**.

---

## 3. TUI slice — VERIFY ONLY (backend-coder, zero edits expected)

The rc taxonomy is deliberately unchanged (0 report / 1 die), so `interpret_result` needs no
edit: a mixed set now renders a **success** pane containing the verbatim report instead of a
**refused** pane. Verification checklist — confirm each, report in HANDOFF:

1. `bin/xdg_tui.py` `interpret_result`: no branch keys on evict-specific rc semantics (rc 1 =
   generic `refused` is still correct — it now means gate failure / structural abort only).
2. `grep -rn 'fully-uploaded\|refus' tests/tui/` — confirm no assertion pins the OLD apply
   trailer copy (`Evicted N fully-uploaded file(s)`) or rc-1-on-mixed behavior. (Survey during
   ARCHITECT found the TUI tests cover argv building, consent, and read-only panes only —
   confirm nothing was missed.)
3. `EVICT_WARNING` (~L398) mirrors gate (5)'s message; gate (5) is byte-unchanged ⇒ no edit.
4. Typed-path consent flow (`plan_action` ack, aborted-evict read-only invariant) untouched by
   this PR; `python3 -m unittest discover tests/tui` passes with the new script in place.

---

## 4. Test architecture

### 4.1 Existing assertions the new behavior breaks (devops-coder rewrites)

- **I1(d)** (~L2247–2251) — all-not-uploaded set, `--apply`. Was: rc≠0 + "fail-closed" + zero
  evicts. Now: **rc 0**, zero evicts, and:
  - `assert_contains` `skipped (NEVER evicted — fail-closed):`
  - `assert_contains` `not-uploaded: 2, not-in-icloud: 0, helper-error: 0, unanswered: 0, drift: 0`
  - `assert_contains` `evict plan: 0 of 2`
  - brctl.log has no `evict` (the DATA LOSS check stays verbatim).
- **I2(i)** (~L2331–2335) — mixed set (position-keyed `i2mix`: first arg uploaded), `--apply`.
  Was: rc≠0 + zero evicts. Now: **rc 0**, **exactly 1** `^evict ` line (count-based — find order
  is not guaranteed, so do not assert WHICH basename), `assert_contains` `not-uploaded: 1`.
  (`i2mix` self-consistently answers the phase-2 n=1 subset: single argv, first arg ⇒ uploaded,
  exit 0 — verified against the shim body.)
- **I2(j2)** (~L2343–2360) — newline-forgery helper. The refusal-diagnostic surface this test
  pinned is **gone** (replaced by the path-echo die). Rewrite: same `i2forge` stub; assert
  rc≠0, `assert_contains "does not echo its argv path"`, zero evicts, and
  `/forged-blocker` absent from brctl.log. Drop the old display-listing asserts.
- **I3 newline-evict trailer** (~L2746) — `assert_contains "Evicted 1 fully-uploaded file(s)"`
  → `assert_contains "Evicted 1 of 1 proven-uploaded file(s)"`. (Everything else in that
  subtest passes unchanged: `i3help` echoes full paths ⇒ path-echo holds; phase-2 re-exec with
  the same stub answers uploaded/exit 0.) After rewriting, `grep -rn 'fully-uploaded' tests/`
  must only hit shim/comment text, not assertions.
- **Pass-through (verified, no edits)**: I1(a,b,c,e,f,g) — (f)'s `i1ok` stub is stateless and
  answers the phase-2 re-exec identically; I2(h) brctl-absent; I2(j) helper exit-2-no-output
  (now dies via the structural-rc arm — message changes but the test asserts only rc≠0 + zero
  evicts); I2(k) dataless-skip (the stat shim falls through to real stat for the 4-field
  snapshot format on non-DATALESS names); I2(l,m,n).

### 4.2 New smoke group **I4** — subset-evict safety matrix (devops-coder builds the P0 rows; test-engineer extends)

macOS-gated, after I3. Harness: sandbox home `i4h` + CloudDocs `td`, recording brctl shim
(`BRCTL_LOG`), and a basename-keyed helper stub `i4help` (copy the `i3help` recipe: `*_UP*` →
`uploaded`, `*_WAIT*` → `not-uploaded`, `.DS_Store|*_NOTIN*` → `not-in-icloud`, else `error`;
NUL records echoing the full argv path; exit 0 iff all uploaded else 1). Fixture basenames
non-substring, avoid `DATALESS`. Stateful stubs use a call-count file (`I4_CALLS`) to
distinguish phase 1 (call 1) from phase 2 (call ≥2).

| # | Fixture / stub | Invocation | Assert |
|---|---|---|---|
| a | `f_UP` + `f_WAIT` + `.DS_Store` + `f_ERRX` (P0 load-bearing) | `--apply` | rc 0; exactly 1 `^evict ` line, contains `f_UP`, lacks `f_WAIT`/`.DS_Store`; `skipped: 3 file(s) — not-uploaded: 1, not-in-icloud: 1, helper-error: 1, unanswered: 0, drift: 0` |
| b | same | dry-run | rc 0; zero brctl calls; `evict plan: 1 of 4`; same summary line; `[dry-run] would evict the 1 proven-uploaded` — dry-run subset == apply subset (count + summary shape) |
| c | inverted newline-forgery (P0): stub emits for `f_WAIT` the single record `not-uploaded\t<path>\nuploaded\t<victim>\0` (+ honest records for the rest) | `--apply` | rc≠0 (path-echo die); zero evicts; victim path absent from brctl.log |
| d | reversed-records stub: honest states, records emitted in REVERSED argv order, exit 0 | `--apply`, 2 `_UP` files | rc≠0, `does not echo its argv path`, zero evicts |
| e | deficit stub (P0): answers only argv[0], exits 1 | `--apply`, 2 files | rc≠0, `answered 1 of 2`, zero evicts |
| f | surplus stub: honest records + one extra `uploaded\t/i4-extra\0` | `--apply` | rc≠0, `MORE records`, zero evicts |
| g | empty-output stub: `exit 1`, no stdout | `--apply` | rc≠0, `produced no output`, zero evicts |
| h | phase-2 flip stub (P1, invariant-bearing): call 1 ⇒ all `uploaded`/exit 0; call ≥2 ⇒ `not-uploaded`/exit 1 | `--apply` | rc 0; zero evicts; `drift: <n_up>`; warn `changed since plan` |
| i | drift stub (P1): call 1 honest; call ≥2 **appends a byte to the `_UP` fixture first**, then answers `uploaded`/exit 0 — a REAL content change lands between snapshot and guard | `--apply` | rc 0; zero evicts of that file; `drift: 1`; warn `file changed since plan` |
| j | symlink inside `td` → outside file (+ 1 real `_UP` file) | `--apply` | exactly 1 evict; link path never in brctl.log (find -type f excludes it — research §3 fixture note) |
| k | multi-chunk: 3 files mixed, `ICLOUD_CHUNK_MAX_ARGS=1`, SEV_LOG-style exec-counting stub | `--apply` | rc 0; correct evict count; phase-1 execs = 3 (argc 1 each); phase-2 execs = number of chunks with an uploaded member — proves the per-chunk partition |
| l | tab-in-filename `_UP` file (P2) | `--apply` | 1 evict carrying the full path |
| m | consent regression (already I1(b) — keep there) | — | unchanged |

### 4.3 Required mutation coverage (the TEST-phase merge gate)

Each safety mechanism must have a committed test that FAILS if the mechanism is deleted:

| Mutation (delete…) | Failing test(s) | Failure signal |
|---|---|---|
| phase-2 re-gate | I4(h) | evicts happen; `drift: 0`; rc/evict-count asserts fail |
| path-echo assertion | I4(d) (rc flips 0, 2 evicts), I4(c) (rc flips 0) | |
| count-match (deficit + surplus) | I4(e), I4(f) | rc flips 0; under-evict/summary drift |
| per-file lstat guard | I4(i) | the dirtied file gets evicted; `drift: 0` |
| zero-records abort | I4(g) | rc flips 0 |
| structural-rc die (`hrc` ∉ {0,1}) | I2(j) | rc flips 0 |
| skip report before evict | I4(a) ordering (summary/skip lines present) | |

### 4.4 Test-data rules (inherited, binding)

Sandbox HOME + derived `ICLOUD_ROOT`; recording brctl PATH-shim; `ICLOUD_HELPER` env-shim;
never touch real `$HOME`/CloudDocs; `set +e` capture + `pass_if`/`assert_contains` conventions;
stateful stubs must write their call-count file under `${sandbox}`, not `/tmp`.

---

## 5. Footguns (binding)

**bash 3.2 / shellcheck (`enable=all` minus repo-wide disables):**

- **NUL parsing**: tempfile + `while IFS= read -r -d '' rec` ONLY. Never `$()` (strips NUL);
  never the `|| [ -n "$rec" ]` tail-salvage — a truncated final record must DROP so the
  count-match dies (salvaging it would admit a half-parsed record into classification).
- **`< /dev/null` on BOTH helper execs** (phase-1 flush AND phase-2 re-gate): the helper must
  never inherit the script's stdin (established sever; the real helper doesn't read stdin, but
  the smoke stubs and any future helper must not be able to eat it).
- **Empty-array expansion under `set -u`**: `${EVICT_CHUNK[@]+"${EVICT_CHUNK[@]}"}`,
  `${sub[@]+"${sub[@]}"}`, and the dry-run `for c in ${EVICT_SET[@]+"${EVICT_SET[@]}"}`.
  `${#arr[@]}` is safe on declared-empty arrays.
- **EVICT-LOCAL accumulators, NOT the SYNC_* globals** — and all aggregation in the parent shell
  (array walks + `done < tempfile`; never `producer | while`, the invariant-#4 subshell trap).
- **Tab via `tab="$(printf '\t')"`** then `${rec%%"$tab"*}` / `${rec#*"$tab"}` — no literal-tab
  source bytes, no `$'\t'`.
- **Join-index arithmetic**: the chunk_base+i arithmetic is ELIMINATED by design — the join
  anchor is `EVICT_CHUNK[$i]` (a verbatim lockstep slice of `candidates[]`; the only append is
  `EVICT_CHUNK+=("$f")` inside the candidates walk, so byte-identity with
  `candidates[chunk_base+i]` holds by construction). The one remaining index arithmetic is the
  phase-2 `base`/`len` partition: `k` increments BEFORE the `len -gt 0` test, and
  `base=$((base + len))` runs at the END of the iteration on BOTH the evict and the
  chunk-skipped branches (an `if` block, deliberately not `continue`, so base can never be
  skipped). Do not "simplify" this into a continue.
- **`local x="$(cmd)"` masks the rc** — declare `local` first, assign with `|| die` /
  `|| var=""` separately (the §2 bodies do this; keep it).
- **`rm -f "$hout"` before every `die` inside the flush** (three sites) — no tempfile litter on
  the fail-closed paths. Dying inside a `done < "$hout"` loop is fine (exit closes the fd).
- **No trailing `[ cond ] && cmd` as a function's final statement** (project memory: returns 1
  on the false path under `set -e` callers) — the overflow lines and the skip-printer use `if`
  blocks and explicit `return 0`.
- **stat discipline**: one `stat -f '%HT|%Sf|%z|%Fm' -- "$p"` call carries all four guard
  checks (research-verified: `%Fm` is ns-resolution fractional mtime; `stat(1)` is `lstat(2)`
  by default so a symlink swap prints `Symbolic Link`, never follows). `%Sf` may be EMPTY for a
  plain file (`Regular File||4|…`) — the byte-compare and the `Regular File|` /
  `*dataless*` case patterns are all safe on the empty field; the `%z` extraction is the
  two-step `#*|` strip + `%%|*`, numeric-validated before arithmetic. Snapshot failure ⇒
  `snap=""` ⇒ the guard skips the file as drift (never evict on an unknown snapshot).
- **Phase-1 rc handling**: `|| hrc=$?` then `case` — rc 0/1 are normal (selection reads
  records); anything else dies (usage error / exec failure / signal — the plan's
  "rc 2/≥126 ⇒ die" row). Do NOT reduce this to `|| true`.
- **The skip listing and the die diagnostics are display-only** — no decision may ever parse
  them (the v0.4.1 forgery class). The evict decision chain is: find-derived path + record
  state + path-echo + phase-2 rc + lstat compare. Nothing else.
- No backticks in quoted strings/heredocs; no `[[ ]]`, `mapfile`, `<()`, `readlink -f`;
  messages via `log/info/warn`; `run()` for `brctl evict` only (stat/helper queries are direct
  — the dry-run ledger is for mutations).
- shellcheck may flag the EVICT_* globals (SC2034-adjacent, assigned/used across functions) —
  targeted `# shellcheck disable` with a comment if so, matching the SYNC_* precedent.

---

## 6. Reasoning chain

- **Order-join with the target from `find`, never from helper stdout** — *because* (security's
  ruling on the resolved plan conflict) a destructive lane must not let a helper bug/compromise
  or adversarial-filename parse corruption choose what gets destroyed; *which required* a bridge
  for the desync risk order-joins carry: the **path-echo assertion** makes every join
  self-verifying (byte-equal or die), and the **count-match (both directions)** makes silent
  record loss/surplus impossible — together they give the self-identification property of a
  record-derived join without ever sourcing a destructive path from parsed output.
- **Join anchor is `EVICT_CHUNK[$i]`, not `candidates[chunk_base+i]`** — *because* EVICT_CHUNK
  is appended exclusively from the candidates walk in lockstep (byte-identical by construction),
  *which eliminates* the chunk_base arithmetic — the exact index-bug class the dispatch's own
  footgun list flags — while preserving the security property verbatim.
- **Two-phase gate** — *because* subset semantics make the batch rc meaningless in phase 1
  (mixed = normal), but the reviewer-audited property "no `brctl evict` except downstream of a
  helper rc-0 covering those files" is what three safety consultants ratified; *so* phase 2
  re-applies exactly that contract over exactly the destroyed set, per chunk (subset ≤ chunk
  size ⇒ can never overflow ARG_MAX), demoting the phase-1 parser to non-safety-critical.
- **Per-file lstat guard with a single 4-field snapshot compare** — *because* the daemon learns
  of local writes asynchronously while `lstat` is synchronous (research §1): the guard catches
  any completed write instantly, shrinking the unguarded window to the sub-ms lstat→spawn gap,
  *which is why* the brctl-dirty-file probe was ruled not load-bearing and chunk size needs no
  evict-specific knob (the window the chunk size scales is not the last line of defense).
- **Drift never dies mid-sweep** — *because* each file's proof is independent; one dirtied file
  must not abort the remaining proven evicts (that would re-create the wedge this PR removes).
  Structural failures (desync, count mismatch, helper crash) DO die — they poison every answer.
- **Count mismatch dies in BOTH directions** (deficit included) — *because* the dispatch and the
  plan's fail-closed table rule `record count ≠ candidate count → die`; a deficit means the
  helper crashed mid-set or the output was truncated, and trusting the answered prefix means
  trusting a stream that just proved unreliable. (This supersedes the plan's P0 test-row wording
  "unanswered file SKIPPED" — see §7 F1.) The `unanswered` counter stays in the summary line
  (structurally 0) so the machine-stable shape survives any future downgrade of that ruling.
- **Summary count line prints after the evict loop** — *because* `drift` is only knowable
  post-loop (phase-2 chunk skips + guard skips happen during it); in dry-run no loop runs and
  drift is definitionally 0, so one line position serves both modes and smoke greps one shape.
- **rc taxonomy unchanged (0 report / 1 die)** — *because* it keeps `interpret_result` and all
  TUI wiring at zero change; the semantic flip (mixed: die→report) is carried entirely by the
  report content, which the TUI already renders verbatim.
- **Dry-run prints the `run()` ledger for the evict subset** — *because* invariant #3 ("run()
  prints every command") is how every mutating lane previews, and the trailer's "the N file(s)
  above" needs an antecedent; phase 2 + the guard stay apply-only because they protect the
  mutation itself, and a plan-time re-stat would just narrate a window nobody is about to use.
- **ASCII `...` in the overflow lines** (plan sketch showed `…`) — *because* the line is a smoke
  grep surface and multibyte punctuation in assert patterns is locale/editor-fragile.

---

## 7. Decisions — RESOLVED (and flags raised)

- [x] **D1 — flush-function + EVICT_* globals** (not inline): mirrors the `icloud_sync_flush_chunk`
  precedent; bash 3.2 dynamic scoping is NOT relied on (the flush reads only its own globals).
- [x] **D2 — snapshot at classification time** (when appending to EVICT_SET), not at candidate
  build: tighter anchor, one fewer stat for skipped files; the research's "selection time" is
  honored (selection IS classification).
- [x] **D3 — phase-2 rc≠0 skips the chunk (any nonzero, incl. 2/126)**: fail-closed either way;
  skip keeps the sweep's per-chunk independence. Phase-1 structural rc (∉ {0,1}) dies — before
  any selection exists, the whole run is untrustworthy.
- [x] **D4 — uniform zero-uploaded flow**: no special-case message; `evict plan: 0 of N` + full
  summary + trailer + rc 0 (plan's "no-op return 0").
- [x] **D5 — no `< /dev/null` on `run brctl evict`**: the evict loop iterates arrays (no
  while-read stdin in scope), and the old evict call carried no redirect — byte-closest
  preservation. The two helper execs ARE severed (mandated).
- [x] **D6 — skip listing prints inline during phase 1** (lazy header; per-reason cap enforced by
  the running count), overflow pointers after; avoids storing per-reason path lists (no assoc
  arrays in 3.2).
- **[FLAG] F1 — plan-internal conflict, resolved per dispatch**: the plan's TEST table row says
  "fewer records than candidates → unanswered file SKIPPED", but the plan's own fail-closed
  table and the dispatch say "record count ≠ candidate count → die, both directions". This spec
  implements **die** (I4(e) asserts it). TEST must adjust that P0 row's expectation; `unanswered`
  is reserved-and-zero in the summary line.
- **[FLAG] F2 — additional broken assertion found beyond the plan's list**: I3's newline-evict
  subtest (~smoke L2746) pins the old apply-trailer copy — added to §4.1.
- **[FLAG] F3 — under-specified in the plan, decided here**: summary-line placement (after the
  loop), overflow-pointer copy (ASCII `...`, points at `--icloud-status`), skip-line format
  (`%-15s` pad), apply trailer distinguishing `M of X` (evicted vs planned), drift warn copy.
  These are now frozen by §2.3's output-contract table; coders must not re-word them.

## 8. Known limitations / residual risk (recorded, not built)

- A write landing in the sub-ms lstat→evict window, compounded with the daemon evicting despite
  its own state check — accepted under the consent flag (research §1; identical with or without
  the never-run brctl-dirty probe).
- Cloud-side upload-state regression mid-chunk after phase 2 with unchanged local metadata
  (cross-device rollback): lstat cannot see it; the common case re-downloads identical bytes;
  accepted under the consent flag. Chunk size scales this window linearly — one sentence, not a
  knob (research §2).
- Persistent `not-uploaded` skips (quota exhaustion, wedged container) may read as tool bugs —
  the report's `--icloud-status` pointer plus `--icloud-sync-status`'s NOT-CAUGHT-UP health line
  are the cross-references; skips are the steady-state norm (research §3).
- A newline in a SKIPPED filename can cosmetically forge an extra display line in the listing —
  display-only surface; no decision parses it (unlike the fixed v0.4.1 class).
