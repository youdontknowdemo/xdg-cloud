# PREPARE research — TUI iCloud bulk-sync actions (`icloud-sync-*`)

**Feature**: add "sync the iCloud mirror" options to xdg-tui — bulk iCloud Drive actions per
dashboard entry, beyond today's per-path `--icloud-status/--icloud-download/--icloud-evict` trio.

**Scope of this doc**: research only. No implementation. Line citations against the working tree
at v0.3.0 (`bin/cloud-xdg-provision.sh`, `bin/xdg_tui.py`, `bin/icloud-uploaded.swift`,
`docs/architecture/tui-offload-manager-diff.md`).

**Probe environment (all VERIFIED claims below)**: macOS **15.7.8 Sequoia** (build 24G809),
`/usr/bin/brctl` present, `bin/icloud-uploaded` compiled (44 KB, current), live CloudDocs with
579 files, Data volume at **97% (2.7 GiB free)** — the disk-pressure context that motivates this
feature is live on the probe machine. All probes were read-only (no download, no evict, no
writes to user data).

---

## Executive summary

The surprise of the audit: **all three existing iCloud commands already recurse over
directories** — each does `find "$ICLOUD_TARGET" -type f` and loops. "Bulk" is not the missing
piece. What's missing for a TUI sync experience is:

1. **Symlink resolution** — the TUI passes `$HOME/<localName>`, but `icloud_resolve_under_root`
   is a lexical prefix match, so on a provisioned (cloud-as-live-home) machine every iCloud
   action on a symlinked entry is refused. Today's iCloud lanes are effectively unreachable from
   the TUI dashboard on the very machines the TUI targets.
2. **Summary output** — status prints one unbounded human-format line per file (no counts, no
   bytes); download's dry-run prints one `run` line per file with no total or free-space check.
3. **A working bulk evict** — the existing all-or-nothing upload gate wedges on any directory
   containing a `.DS_Store` (VERIFIED: reports `not-in-icloud` → helper rc 1 → evict refuses
   everything).
4. **Perf** — status spawns the helper once per file (~20 ms/spawn); batching is ~5× faster
   (~3.8 ms/file, VERIFIED timings).

Recommended PR scope (bias small): **`icloud-sync-status` (new read-only summary lane) +
byte-preview/free-space enhancement of `--icloud-download`**, plus the symlink-resolution fix
that both depend on. **Defer bulk skip-and-report evict** to a follow-up — it changes the evict
safety semantics and deserves its own review cycle. Estimated variety ~8 (medium) →
`/PACT:orchestrate` (skip-PREPARE, this doc is the PREPARE output).

---

## 1. Current lane audit (`bin/cloud-xdg-provision.sh`)

### Shared plumbing

| Item | Where | Behavior |
|---|---|---|
| `ICLOUD_ROOT` | L111 | `$HOME/Library/Mobile Documents/com~apple~CloudDocs`, fixed |
| `ICLOUD_HELPER` | L112 | compiled binary beside the script, overridable env |
| `ICLOUD_CONFIRM` | L113, L483 | set by `--i-understand-data-loss-risk` |
| Arg parsing | L480–482 | each mode takes exactly one path via `MODE_ARG` (`${1:?...}` — missing path is a hard usage die) |
| `icloud_guard_macos` | L1861 | dies unless `PLATFORM=macos` |
| `icloud_require_brctl` | L1863 | dies if no `brctl` |
| `icloud_resolve_under_root` | L1867–1874 | absolutizes `$1` (cwd-join for relative), then **lexical** `case` prefix match against `$ICLOUD_ROOT`; `-e` existence check. **No symlink resolution** (deliberately bash-3.2: no `readlink -f`, and no `cd && pwd -P` here either) |
| `icloud_is_dataless` | L1878–1883 | `stat -f '%Sf'` contains `dataless` |

**Finding — the TUI-path mismatch.** `xdg_tui.py` builds path targets as
`os.path.join(home, entry.local_name)` (L541–547) per the diff-spec action table
(`docs/architecture/tui-offload-manager-diff.md` L472–474: target = `$HOME/<localName>`).
On a provisioned machine `$HOME/Documents` is a **symlink into** CloudDocs; the string
`"$HOME/Documents"` does not match `"$ICLOUD_ROOT"/*`, so the script dies
`path is not under iCloud Drive` (VERIFIED on this machine, rc 1 → TUI renders it as a
verbatim "refused" pane per `interpret_result` L226–232). This was acceptable in the last cycle
(entries here aren't symlinked); it is fatal for a sync feature whose whole point is operating
on cloud-mirrored entries.

**Decision**: any sync work must first make `icloud_resolve_under_root` resolve symlinks
(`cd <dir> && pwd -P` for dirs; `dirname`-resolve + basename re-join for files — bash-3.2-safe),
then apply the same fail-closed prefix check to the **resolved** path.
**Open risk**: resolution must not weaken the confinement check (resolve first, *then* prefix-match;
never match the unresolved string).

### `cmd_icloud_status` (L1886–1904) — read-only

- **Recursion**: yes — `find "$ICLOUD_TARGET" -type f` (L1893). Works for a single file too
  (`find` on a file path emits it).
- **Gates**: macOS + under-root only. No `begin_mutating_mode`, no lock, no brctl required, helper
  optional (column shows `unknown(helper not built)` without it, L1889/L1900).
- **Per file** it reports three columns: ubiquity via `mdls kMDItemFSIsUbiquitous` (L1897),
  dataless via `stat` (L1896), uploaded via **one helper spawn per file** (L1898–1899).
- **Output** (VERIFIED, run against a real CloudDocs subtree):

  ```
  iCloud status under: .../ulfs-offline (read-only)
    local?       dataless       uploaded                 /Users/.../index.html
    local?       materialized   not-uploaded             /Users/.../.DS_Store
  ```

  One line per file, **no summary**, **not parse-stable** (`printf '%-12s %-14s %-24s %s'`
  human columns, L1901). 579 files → 579 lines in a TUI pane. Exit 0 regardless of states
  (it's a report); dies rc 1 only on gate failures.
- **VERIFIED defect (accuracy)**: the `mdls` ubiquity column reported `local?` for files the
  helper simultaneously proves `uploaded` — dataless/evicted files lose Spotlight metadata, so
  `kMDItemFSIsUbiquitous` is unreliable exactly where it matters. The helper's
  `isUbiquitousItem` (URLResourceValues) is the authoritative signal and already distinguishes
  `not-in-icloud`.
- **VERIFIED defect (conflation)**: the per-file helper spawn only checks rc (L1899), so
  `not-in-icloud` and `error` both print as `not-uploaded`. Stuck-item detection needs the
  distinct states, which the helper already prints on stdout (discarded here).
- **VERIFIED perf**: helper spawn ≈ 20 ms; batched exec ≈ 3.8 ms/file (50-file batch: 0.19 s
  total; 10 sequential spawns: 0.20 s). 579 files ≈ 12 s per-file vs ≈ 2 s batched; a 10k-file
  tree ≈ 3.5 min vs ≈ 40 s. Per-file spawn does not scale to bulk.

### `cmd_icloud_download` (L1907–1918) — mutating, reversible

- **Recursion**: yes (L1912). Per-file `run brctl download "$f"` (L1914) — already the
  "materialize everything dataless" bulk primitive.
- **Gates**: `begin_mutating_mode` (L1908 — trap + not-root + apply-only lock), macOS,
  under-root, brctl. Dry-run default; every `brctl download` goes through `run()` so the
  dry-run prints the exact commands (invariant #3).
- **Defects for bulk use**:
  - Downloads **every** file, not just dataless ones — no `icloud_is_dataless` filter (contrast
    evict's candidate filter at L1940). Harmless (`brctl download` of a materialized file is a
    no-op request) but noisy and it queues pointless fileproviderd work.
  - Dry-run preview = N `%q`-quoted command lines + a one-line trailer (L1916). **No count, no
    byte total, no free-space check.** On this 97%-full machine, hydrating `~/Movies` alone
    needs ~1.9 GB against 2.7 GiB free (VERIFIED below) — the preview gives the user no way to
    see that before `--apply`.
- **Exit**: 0 on success/dry-run; rc of a failing `brctl download` propagates through `run` under
  `set -e` (first failure aborts the loop mid-batch — no partial-failure summary).

### `cmd_icloud_evict` (L1923–1966) — mutating, gated

- **Recursion**: yes (L1939). Candidates = every **non-dataless** file (L1940).
- **Gates**, cheapest→dearest (L1925–1933): macOS → under-root → brctl → helper built (dies with
  `make helper` guidance, L1928–1930) → `ICLOUD_CONFIRM` consent (L1931–1933). Then the upload
  gate: **one batched helper exec over all candidates** (L1948); any non-`uploaded` line → print
  offenders, die, evict **nothing** (L1949–1953). Per-file `run brctl evict` (L1959 —
  deliberately per-file: "`brctl evict <dir>` is undocumented", L1957 comment).
- **VERIFIED defect (the `.DS_Store` wedge)**: `.DS_Store` files inside CloudDocs report
  `not-in-icloud` (probed: helper rc 1) — Finder metadata is excluded from sync. They are also
  materialized, so they always enter the candidate list. Consequence: **directory-level evict
  fails closed on essentially every real directory** (every browsed folder grows a `.DS_Store`).
  The all-or-nothing gate is correct engineering for an explicit path, but it makes the existing
  lane nearly unusable as a bulk "evict everything safely uploaded" action.
- The batched-exec pattern here (tempfile + single helper call + parse `hout`) is exactly the
  pattern bulk status needs.

### Helper — `bin/icloud-uploaded.swift` (44 lines)

- Reads `URLResourceValues` for `isUbiquitousItem`, `ubiquitousItemIsUploaded` (+`IsUploading`,
  `DownloadingStatus` requested but unused in the verdict) (L21–26).
- **Accepts many paths per exec** (argv loop, L29); stdout one line per path:
  `<state>\t<path>`, state ∈ {`uploaded`, `not-uploaded`, `not-in-icloud`, `error`} (L9).
- Exit 0 **iff every** path is `uploaded`; 1 otherwise; 2 usage (L10–12). FAIL CLOSED on any
  read error/nil (L14, L41–43).
- **Upload state is observed, never forced** — `ubiquitousItemIsUploadedKey` is read-only; there
  is no "push now" resource value (see §2).
- Batch note: stdout is already parse-stable (tab-separated, fixed enum) — bulk lanes should
  parse stdout per line instead of collapsing to rc, and chunk argv (`xargs`-style) for very
  large trees to stay under ARG_MAX; chunking breaks the "one exec covers the whole set" rc
  semantics, so bulk parsing must aggregate per-line states, not exit codes.

---

## 2. What macOS actually offers for "sync" (Sequoia 15.7.8)

### VERIFIED on this machine

| Fact | Evidence |
|---|---|
| `brctl help` documents: `diagnose`, `log`, `dump`, `status`, `accounts`, `quota`, `monitor`, `spotlight`. **`download` and `evict` are absent from help** (undocumented subcommands the script relies on) | probe: `brctl help` full dump |
| `brctl download <missing-args>` / `brctl evict <missing-args>` print the generic usage; exit codes not meaningful signal (memory + observed usage-fallback) | probe |
| `brctl status` (no args) prints one line per container incl. a **`caught-up`** token and `last-sync` timestamp — a cheap container-level stuck/health probe. Help text: "Prints items which haven't been completely synced up" (when not caught up it lists pending items) | probe: `<com.apple.CloudDocs[1] ... sync:oob-sync-ack last-sync:2026-07-02 ... caught-up ...>` |
| `brctl monitor --wait-uploaded` / `--wait-start-uploading` exist — a **wait-for-upload** primitive (blocks until items upload), not a force | `brctl help` |
| `brctl quota` prints a clean single parseable line (`6546785123652 bytes of quota remaining in personal account`) | probe |
| **Dataless files keep their full logical size in `stat -f %z` with `blocks=0`** — e.g. a 1,251,363,508-byte movie, `flags=compressed,dataless size=1251363508 blocks=0`. Byte-exact "to download" estimation = sum of `%z` over dataless files; "evictable bytes" = sum over materialized+uploaded. No brctl needed for estimation | probe: `stat -f 'flags=%Sf size=%z blocks=%b'` |
| `mdls kMDItemFSIsUbiquitous` is unreliable for synced-but-dataless files (reports non-ubiquitous while the helper proves `uploaded`) — evict/dataless strips Spotlight metadata | probe: status output discrepancy |
| `.DS_Store` inside CloudDocs = `not-in-icloud` per URLResourceValues | probe: helper run |
| Helper timing: ~20 ms/spawn, ~3.8 ms/file batched | probe: `time` runs |
| Free-space check is trivially scriptable: `df -k <path>` (POSIX columns) | probe |

### Knowledge-based (NOT machine-verified — flag for architect)

- **Upload cannot be forced.** There is no public CLI or Cocoa call to "upload this file now";
  upload scheduling belongs to `bird`/`fileproviderd`. Options are observe
  (`ubiquitousItemIsUploadedKey`, the helper) or wait (`brctl monitor --wait-uploaded`). A
  "sync-up" action is therefore **out of scope by platform limitation** — the honest primitive
  is "report what's not yet uploaded" (+optionally a bounded wait).
- **`brctl download` on a directory**: behavior on dirs is undocumented; anecdotal reports say it
  recurses on modern macOS, but the current script's per-file loop is the defensible choice
  (mirrors the L1957 comment about `evict <dir>` being undocumented). Keep per-file.
- **`NSFileManager.evictUbiquitousItem(at:)`** is the *supported* API equivalent of
  `brctl evict`; `startDownloadingUbiquitousItem(at:)` the equivalent of `brctl download`. A
  future option is extending `icloud-uploaded.swift` into a small verb-taking helper
  (`icloud-uploaded evict <paths>`) that checks-then-evicts atomically in one process —
  eliminates the check/evict TOCTOU window and 2×N spawns. **Not recommended for this PR**
  (grows the compiled surface; the Swift helper is deliberately tiny), but record as an
  architect option.
- **"Optimize Mac Storage" OFF ⇒ evict is a no-op** (replicated FileProvider keeps everything
  local); the setting has **no documented programmatic check**. This is already why
  `--i-understand-data-loss-risk` exists (L1931–1933 wording). Applies unchanged to bulk evict.
- **macOS version notes**: FileProvider-based iCloud Drive since Sonoma (replicated/non-replicated
  distinction above); a 14.4 bug deleted saved document versions on evict (fixed 14.4.1) —
  historical, Sequoia unaffected as far as public reporting goes. `SF_DATALESS`/`%Sf` and the
  URLResource keys are stable across Sonoma→Sequoia. No Sequoia-specific brctl changes found
  worth gating on; the help-dump above is the 15.7.8 ground truth.

---

## 3. Candidate action set

Naming below is provisional (architect owns final flag spelling; `--icloud-sync <path> --status`
conflicts with `set_mode`'s one-lane-per-invocation rule — three distinct flags parallel to the
existing trio is the pattern-consistent choice).

### `icloud-sync-status` — read-only bulk report ✅ recommend for this PR

- **Safety class**: read-only (no lock, no `begin_mutating_mode` — same class as
  `--icloud-status`/`--classify`).
- **What it adds over `--icloud-status`**: a **summary**, not a per-file dump:
  - N files scanned; A dataless (X bytes to download), B materialized+uploaded (Y bytes
    evictable), C materialized+not-uploaded ("waiting on iCloud"), D not-in-icloud (excluded,
    e.g. `.DS_Store`), E error.
  - Volume free space (`df -k`) alongside X → "download would use X of Z free".
  - Container health line from `brctl status` (`caught-up` vs pending + `last-sync` age) —
    the cheap stuck-sync detector (§5).
- **Mechanics**: one `find`, one `stat` pass, **one batched helper exec** (chunked for
  ARG_MAX; parse stdout lines, not rc). ~2 s for 579 files.
- Per-file listing can remain available (existing `--icloud-status` unchanged) — sync-status is
  additive, no breaking change.

### `icloud-sync-down` — bulk materialize ✅ recommend for this PR (as enhancement)

- **Safety class**: mutating but reversible; only ADDS local data. Keeps `begin_mutating_mode`,
  dry-run default, `y/N` confirm in the TUI (same class as today's `icloud-download`).
- **Honest framing**: `cmd_icloud_download` already *is* bulk down. The PR work is:
  1. filter to dataless files only (skip materialized — mirrors evict's L1940 filter),
  2. dry-run preview header: count + total bytes (stat `%z` sum) + free-space comparison, with a
     **warning (or refusal) when bytes-to-download ≥ free space** — ENOSPC jams `fileproviderd`
     (project memory: a 100%-full disk froze all sync), so this is a safety gate, not cosmetics,
  3. keep per-file `run brctl download` lines (invariant #3: `run()` prints every command).
- **Decision point for architect**: new flag vs. enhancing `--icloud-download` in place. Bias:
  enhance in place (preview header + dataless filter are strict improvements; no TUI table
  change needed beyond none at all). A distinct `icloud-sync-down` op only earns its keep if the
  TUI wants different menu labeling.

### `icloud-sync-evict` — bulk evict, skip-and-report ⏸ recommend DEFER

- **Safety class**: highest — inherits `--i-understand-data-loss-risk` + the TUI's typed-path
  ack (diff-spec L500–513, `plan_action` ConsentError gate `xdg_tui.py` L207–213).
- **Why it can't just reuse the existing lane**: the all-or-nothing gate wedges on `.DS_Store`
  (§1). Bulk semantics must be **per-file classify → evict only the `uploaded` subset → report
  skipped** (skip `not-in-icloud` and `not-uploaded`; abort on `error` states — fail closed
  where it's ambiguous, skip where the helper gives a definite non-evictable answer).
- **Perf is a non-issue**: one batched helper exec (~3.8 ms/file) + per-file `brctl evict` for
  the admitted subset. No per-file helper spawns needed.
- **Why defer**: this *changes the safety semantics* of eviction (from "prove everything or do
  nothing" to "do the proven subset") and is exactly the kind of change that deserves its own
  diff-spec + review cycle with fresh eyes on the fail-closed matrix. status+down deliver the
  user-visible value ("what's dataless / not uploaded" + "materialize it") without touching the
  data-loss lane. Counter-pressure, stated honestly: the `.DS_Store` wedge means bulk evict is
  the only way the evict lane becomes *usable* on real directories — if the user wants
  space-freeing this cycle, pull it in and accept the bigger review.

### Rejected: `icloud-sync-up`

No platform primitive to force upload (§2). The honest substitute is sync-status's
"C not-uploaded" count plus, optionally later, a bounded `brctl monitor --wait-uploaded` wait
lane. Do not ship an action named "sync up" that can only wait.

---

## 4. Script-vs-TUI split (wrap-don't-bypass)

**Script side** (all logic):
- `icloud_resolve_under_root` symlink resolution (`cd && pwd -P`; resolve-then-confine) — the
  enabling fix for every TUI iCloud action on provisioned machines.
- New `cmd_icloud_sync_status` (summary computation, batched helper parse, `df -k`, `brctl
  status` health line) + flag parsing + `set_mode` registration + help text (~L385–392, L480–482,
  L2271–2273 dispatch table).
- `cmd_icloud_download` dataless filter + preview header + free-space gate.
- (If pulled in) bulk-evict skip-and-report lane.

**TUI side** (wiring only, per diff-spec §5 pattern):
- `ACTIONS` table entry: `"icloud-sync-status": {"flag": ..., "target": "path", "read_only": True}`
  (`xdg_tui.py` L87–94); add to `ops_for_entry` for `code` and `xdg` classes (L242–252).
- If download is enhanced in place: **zero TUI change** for sync-down.
- No `plan_action` gate changes (read-only op; no `--apply`, no typed ack).
- **Porcelain contract: no change needed.** Verbatim panes were explicitly ruled fine for iCloud
  lanes (diff-spec L732 "no reclaim/icloud porcelain in v1"). A summary lane makes the verbatim
  pane *better* (bounded lines), which removes the main pressure for porcelain. Revisit only if
  the TUI later wants to render per-entry iCloud badges in the dashboard table (out of scope).
- `interpret_result` (L221–232) already maps rc 1 → refused-verbatim; new lanes must keep the
  die-rc-1 convention.

**Tests** (smoke, sandboxed): brctl is invoked via `run()` and the helper via `$ICLOUD_HELPER`
(both PATH/env-shimmable per the L1858 comment) — sandbox fixtures can fake `brctl`, a stub
helper emitting chosen `<state>\t<path>` lines, and a fixture tree; symlink-resolution tests need
a sandbox `ICLOUD_ROOT`. `ICLOUD_ROOT` is currently hardcoded (L111) — making it env-overridable
(like `ICLOUD_HELPER`) is likely a prerequisite for smoke coverage; architect to confirm.

---

## 5. Known hazards applied to bulk ops

| Hazard (project memory, verified history on this machine) | Bulk impact | What the script should surface |
|---|---|---|
| **One stuck item wedges the entire container queue** (30 GB stuck download froze ALL sync; survived `killall bird`; needed reboot/sign-out) | Bulk down of thousands of files queues massive fileproviderd work; one stuck item stalls everything and the rest silently never arrive | `icloud-sync-status` prints the `brctl status` health line (`caught-up` + `last-sync` age); warn when not caught up **before** a bulk download; suggest re-running status after |
| **ENOSPC jams `fileproviderd`** (100%-full disk froze sync) | Bulk down can *cause* the wedge it should warn about | The free-space gate in sync-down's preview (refuse or loudly warn when estimated bytes ≥ available) |
| **Same-volume: moving into iCloud frees nothing until upload+evict** | Sets user expectations: sync-status's "Y bytes evictable" is the only true space-freeing number, and only with Optimize Mac Storage ON | sync-status wording: label evictable bytes as "potential", cite the Optimize-Mac-Storage caveat (no programmatic check) |
| **Deny-delete ACLs on special folders** (Desktop/Documents/etc.) | Mostly N/A — `brctl download`/`evict` don't rename/delete the folder. Relevant only to future move/relocate features | Nothing new; note for architect that sync lanes never `mv`/`rm` |
| **`brctl evict` cancels a stuck download** (side-effect discovered the hard way) | A targeted unwedge trick, not a bulk concern | Optional: mention in sync-status's "not caught up" hint text |

---

## 6. Effort + variety estimate

Scored per pact-variety dimensions, for the recommended scope (sync-status + down-enhancement +
symlink fix; evict deferred):

| Dimension | Score | Why |
|---|---|---|
| Novelty | 2 | Extends an existing, well-understood lane; batched-helper pattern already exists in evict (L1948) |
| Scope | 2 | One new lane + one enhanced lane + resolver fix + TUI table row + smoke fixtures; two files of substance |
| Uncertainty | 2 | brctl/dataless behaviors probed and verified above; residual unknowns are cosmetic (output wording) — except the ICLOUD_ROOT-overridability test question |
| Risk | 2 | No deletion path in scope (evict deferred); worst mutation is downloading too much, gated by the free-space check |

**Total ≈ 8 → medium → `/PACT:orchestrate`** (ARCHITECT diff-spec per repo convention, then
CODE + TEST). This PREPARE doc stands in for the PREPARE phase. It is *close* to comPACT-able,
but three things push it to orchestrate: the symlink-resolution change touches a shared
confinement guard (security-adjacent, wants a diff-spec), the smoke-test strategy needs a
decision (`ICLOUD_ROOT` override), and repo convention gives each substantial provision-script
feature an ARCHITECT diff-spec.

If bulk-evict is pulled into scope: Risk → 3, Scope → 3, total ≈ 10 — still orchestrate, but
budget a dedicated review pass on the skip-vs-abort fail-closed matrix.

---

## References

- `bin/cloud-xdg-provision.sh` L111–114, L385–392, L480–483, L1853–1966, L2271–2273
- `bin/icloud-uploaded.swift` (entire, 46 lines)
- `bin/xdg_tui.py` L84–94, L189–252, L541–554
- `docs/architecture/tui-offload-manager-diff.md` L346–351, L472–513, L732
- Probes (this doc, 2026-07-03, macOS 15.7.8/24G809): `brctl help`, `brctl status`,
  `brctl quota`, `stat -f '%Sf %z %b'` on dataless/materialized CloudDocs files, timed
  `icloud-uploaded` batch-vs-spawn runs, `--icloud-status` live runs (read-only)
- Project memory: macOS iCloud offload realities (stuck-item wedge, ENOSPC jam, same-volume,
  deny-delete ACLs, Optimize-Mac-Storage evict no-op)
- Knowledge-based (unverified, flagged in §2): no force-upload primitive;
  `evictUbiquitousItem(at:)`/`startDownloadingUbiquitousItem(at:)` equivalences;
  `brctl download <dir>` recursion behavior; Sonoma 14.4 versions-on-evict bug (fixed 14.4.1)
