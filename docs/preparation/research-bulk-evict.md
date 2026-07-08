# PREPARE Research: Bulk Skip-and-Report Evict — 3 Go/No-Go Items

> Feature: `--icloud-evict` subset semantics per `docs/plans/bulk-evict-plan.md`
> Host: macOS 15.7.8 (24G809), 2026-07-07. Method: knowledge + READ-ONLY probes only —
> **no live `brctl evict` was run on any real file** (dispatch data-safety constraint).
> Each claim is flagged **[verified]** (probed on this host) or **[knowledge]** (training
> knowledge / Apple docs recall, not re-verified live).

## Executive Summary

All three items resolve **GO**, none requires a live destructive test. (1) The
brctl-evict-on-dirty probe is **not load-bearing**: the design's per-file lstat guard means the
code never knowingly evicts a dirty file, and an edit-then-evict probe physically cannot test
the only unguarded case (a write inside the sub-millisecond lstat→evict window) — both possible
probe outcomes leave the design unchanged. The item downgrades to an exact guard specification,
given below. (2) The evict lane should **reuse** `ICLOUD_CHUNK_MAX_BYTES/_ARGS` — the
TOCTOU-window argument for a smaller separate default fails because the window it would shrink
is not the last line of defense; the per-file lstat guard is. (3) The perpetual-skip population
is real and larger than `.DS_Store` (Office `~$*` locks, `*.tmp`, `Icon\r`, atomic-save temps,
over-quota/oversize files, hot git/db files); every browsed real CloudDocs dir contains at
least one, so the report UX should frame skips as **the norm**, not an anomaly.

---

## 1. `brctl evict` on a dirty/not-fully-uploaded file — GO, no live test needed

### Finding

`brctl evict`'s behavior on a file with unsynced local changes is **undocumented**, and the
question does not need an empirical answer for this design: the design's own per-file lstat
guard makes the known-dirty case unreachable, and the probe cannot reach the unknown-dirty case.

### Evidence

- **[verified]** On macOS 15.7.8, `brctl help` does not document `evict` (or `download`) at
  all — the subcommand exists (repo lanes use it) but has no help entry; `brctl evict` with no
  args prints only the generic usage. There is no man page. The CLI contract is entirely
  undocumented — nothing to cite for dirty-file behavior.
- **[knowledge]** The underlying API is `FileManager.evictUbiquitousItem(at:)` (Foundation),
  documented only as "removes the local copy of the specified item that's stored in iCloud";
  it throws on failure but Apple documents no dirty-file contract. The eviction is performed by
  the CloudDocs daemon (bird/fileproviderd), which owns authoritative upload state
  (`NSURLUbiquitousItemIsUploadedKey` — "the current version is fully uploaded"). Community and
  API-shape evidence suggests the daemon refuses to evict an item whose current generation it
  knows is not uploaded, but this is **not** verified and the design must not rely on it.
- **[knowledge]** The daemon learns of a local write asynchronously (FSEvents/fseventsd →
  daemon marks item dirty), so daemon state can lag a write by an observable interval. By
  contrast, `lstat(2)`/`stat(1)` read kernel inode metadata **synchronously** — a completed
  `write()` is visible to the very next `stat` with zero daemon latency.

### Is the probe load-bearing? No.

The proposed probe (edit a sacrificial file, then evict it) measures the daemon's handling of a
**known-dirty** file — one it has had seconds-to-minutes to observe. Trace the design's pipeline
for that case:

1. **Phase-2 re-gate**: helper re-exec over the exact evict subset requires rc==0
   (`ubiquitousItemIsUploaded == true` for every file, daemon-authoritative) seconds before the
   chunk's evict loop. A daemon-known dirty file fails here → chunk refused.
2. **Per-file lstat guard** immediately before each `brctl evict`: any completed write since
   selection changes size and/or mtime → caught instantly (no daemon latency) → skip+warn.

So the code **never passes a detectably-dirty file to brctl** — the probe's scenario is
unreachable by construction. The only case the guards cannot catch is a write that lands inside
the lstat→`brctl` spawn window (sub-millisecond to low-millisecond). An edit-then-evict probe
**physically cannot test that window** — by the time evict runs, the edit is old and
daemon-known. Therefore:

| Probe outcome (if it were run) | Consequence for the design |
|---|---|
| brctl refuses dirty files | Belt-and-braces below our guards. Design unchanged — guards still required (daemon state can lag; `uploaded` staleness). |
| brctl destroys dirty bytes | The lstat guard **is** the defense, exactly as already specified. Design unchanged. |

Both branches leave the design identical ⇒ the probe is not load-bearing ⇒ **no live
destructive test is needed or justified**. (If TEST phase later wants empirical brctl-dirty
behavior for documentation, that is an optional user-authorized sacrificial-file experiment —
not a gate.)

### Decision — exact lstat-guard specification (this replaces the probe)

At **selection time** (phase-1 candidate build), capture one snapshot string per candidate in a
parallel array appended in lockstep with `candidates[]` (the `SYNC_SIZES` order-join idiom):

```
snap="$(stat -f '%HT|%Sf|%z|%Fm' -- "$f" 2>/dev/null)" || snap=""
```

Immediately before **each** `run brctl evict "$c"` (apply path), the guard must check, in order:

1. **Re-confine**: `$c` still lexically under the resolved `$ICLOUD_TARGET` (cheap `case`
   prefix check — candidates came from `find` on the physical root, so this is an assertion).
2. **Re-stat**: `now="$(stat -f '%HT|%Sf|%z|%Fm' -- "$c" 2>/dev/null)" || now=""` — a failed
   stat (deleted/renamed file) ⇒ skip+warn.
3. **Type**: snapshot AND re-stat both begin `Regular File|` — **[verified]** macOS `stat(1)`
   uses `lstat(2)` by default (a symlink probe prints `Symbolic Link`, it is not followed), so
   this rejects symlink swaps without a separate `-L` dance.
4. **Not dataless**: `%Sf` flags field does not contain `dataless` (already-evicted ⇒ skip as
   no-op, matching gate (6)'s semantics).
5. **Size AND mtime unchanged**: the **whole 4-field string byte-equals** the selection-time
   snapshot. `%Fm` is fractional mtime — **[verified]** nanosecond resolution on this host
   (`1783482484.030204788`), so a same-second, same-size rewrite cannot slip past the way it
   would with seconds-granularity `%m`. One `stat` call carries all four checks.

Any check fails ⇒ **skip + warn + count under a drift reason in the report** — never die
mid-sweep (other files' proofs are independent), never evict.

### Residual risk (accepted, documented)

- A write landing in the lstat→evict sub-ms window **and** the daemon then evicting despite its
  own state check — compound improbability; bounded by the consent flag
  (`--i-understand-data-loss-risk`) which exists precisely for unverifiable OS-side residuals.
- An adversarial local process doing a same-size in-place write then back-dating mtime via
  `utimes()` — out of scope: an attacker with local write access can destroy the data directly.
- These residuals are **identical whether or not the probe had been run** — running it would
  not have shrunk them.

---

## 2. Chunk-size default for the evict lane — REUSE `ICLOUD_CHUNK_MAX_BYTES/_ARGS`

### Finding

The evict lane's phase-1 classification chunking has the identical ARG_MAX problem the
sync-status lane already solved; the TOCTOU argument for a smaller evict-specific default does
not survive contact with the lstat guard.

### Evidence

- **[verified]** `bin/cloud-xdg-provision.sh:1996-2005`: `ICLOUD_CHUNK_MAX_BYTES=131072` /
  `ICLOUD_CHUNK_MAX_ARGS=5000`, load-time fail-closed validation (non-numeric and over-ceiling
  both die), env-overridable as the smoke seam. Rationale comments (ARG_MAX 1 MiB including
  envp; ≥7/8 headroom) apply verbatim to any batched helper exec, including evict phase-1.
- **TOCTOU window math**: phase-2 rc==0 covers a chunk's evict subset; the window from that
  check to the *last* evict in the chunk ≈ subset size × per-file `brctl` spawn latency
  (~10-20 ms **[knowledge]**, consistent with the measured ~20 ms/spawn figure in the
  sync-status comments **[verified]** at L2066-2067). Worst case at the 5000 cap ≈ 1-2 minutes.
- But the phase-2 gate is **defense-in-depth against upload-state regression**, not the
  content-drift guard — content drift (the data-loss vector) is caught per-file by the lstat
  guard with a sub-ms window **independent of chunk size**. Shrinking chunks tightens a window
  that is not the last line of defense, while the actual last line's window is unaffected.

### Decision

- **Reuse both knobs, no new knobs.** Phase-1 chunks by the existing byte+arg budgets (same
  accumulate/flush pattern as `icloud_sync_flush_chunk`, but evict-local accumulators per the
  plan). Phase-2 re-gates **per phase-1 chunk** (subset ≤ chunk size by construction, so it can
  never itself overflow ARG_MAX).
- A second knob pair would duplicate the 10-line validation block, add doc surface, and let the
  two lanes drift — for a window the lstat guard already caps. KISS.
- The existing env-override seam doubles as the I4 smoke seam: a tiny cap
  (e.g. `ICLOUD_CHUNK_MAX_ARGS=2`) drives the multi-chunk path — including the
  phase-2-per-chunk and chunk-boundary-desync cases — on a small fixture, exactly as the
  sync-status tests already do.

### Residual risk

Cloud-side upload-state regression mid-chunk after phase-2 with **unchanged local metadata**
(e.g. cloud copy rolled back from another device inside the window): lstat cannot see it. In
the common case the once-uploaded bytes equal the local bytes, so a re-download restores them;
the pathological cross-device race is accepted under the consent flag. Chunk size scales this
window linearly — worth one sentence in the diff-spec, not a knob.

---

## 3. Perpetual-skip population beyond `.DS_Store` — skips are the norm

### Finding

Every real CloudDocs directory contains at least one file that will *always* classify
`not-in-icloud` or *persistently* `not-uploaded`. The report UX should present skips as
expected steady-state, not as a warning condition.

### Evidence

- **[verified]** Read-only `ls -la` of this host's CloudDocs root, `git/`, and `ulfs-offline/`:
  a `.DS_Store` exists in **all three** browsed directories (Finder recreates them on browse).
  Any Finder-touched directory tree will carry one per dir → a directory evict will
  essentially never be skip-free.
- **[verified]** This host keeps **bare git repos** under `CloudDocs/git/` — during/shortly
  after a push, refs/objects/packfiles are freshly written ⇒ `not-uploaded` until sync catches
  up. Hot working files are a routine, recurring skip reason on this very machine.
- **[knowledge]** Population of always-or-persistently skipped files in real CloudDocs trees:

| Pattern | Class (helper state) | Why |
|---|---|---|
| `.DS_Store` | not-in-icloud | Finder metadata; iCloud Drive excludes it from sync (the existing sync-status text already uses it as the exemplar) |
| `Icon\r` (CR in name) | not-in-icloud (typically) | Custom folder-icon resource file; excluded/ignored by sync |
| `~$*` (e.g. `~$Report.docx`) | not-in-icloud | MS Office owner/lock temp files; excluded by iCloud per its temp-file rules |
| `*.tmp` | not-in-icloud | Apple documents iCloud Drive does not sync `.tmp` files |
| Atomic-save temps (`*.sb-*`) | not-in-icloud / transient | NSDocument safe-save intermediates; appear mid-save, vanish after |
| Over-quota files | not-uploaded (persistent) | Upload stalls until account quota is freed — can persist for months |
| Files > iCloud per-file max (~50 GB) | not-uploaded (persistent) | Will never finish uploading |
| Hot append/rewrite files (logs, SQLite `-wal`/`-shm`, live git index/packs) | not-uploaded (recurring) | Re-dirtied faster than sync settles |

- **[verified, incidental]** CloudDocs root contains `Desktop`/`Documents` **symlinks** into
  `$HOME` — the candidate walk (`find -type f`, no `-L`) does not follow them, and the lstat
  guard's `Regular File` check independently rejects symlinks. No action needed; worth an I4
  fixture note (a symlink inside the target dir must contribute zero candidates).

### Decision

- Knowledge-level documentation is sufficient (the plan explicitly allows it); no probe needed
  beyond the read-only listings above.
- Report copy should read as routine accounting — the plan's format already does this well
  (`skipped (NEVER evicted — fail-closed):` + capped listing + stable per-reason count line).
  Two small recommendations for the diff-spec: (a) fix the reason order in the summary line
  (`not-uploaded, not-in-icloud, helper-error, unanswered, drift`) so smoke can grep one stable
  shape; (b) the `… and N more` overflow line plus `--icloud-status <path>` pointer (already in
  the plan's target format) is the right escape hatch — keep it.
- The `drift` reason (new, from the lstat guard in §1) joins the taxonomy: files skipped
  because their state changed between selection and evict.

### Residual risk

None safety-side (skips are fail-closed by definition). UX-side: a user may interpret
persistent `not-uploaded` skips as a tool bug when the cause is quota exhaustion or a wedged
container — the existing `--icloud-sync-status` health line (`NOT-CAUGHT-UP` warning) is the
right cross-reference for the report's skip-footer.

---

## Sources

- **This host (verified)**: macOS 15.7.8 `brctl help` / `brctl evict` usage output;
  `stat -f '%HT|%Sf|%z|%Fm'` fractional-mtime + lstat-semantics probes; read-only `ls -la` of
  three real CloudDocs directories; `bin/cloud-xdg-provision.sh` (chunk constants L1996-2005,
  `icloud_sync_flush_chunk` L2014-2039, `cmd_icloud_evict` L2205-2261);
  `bin/icloud-uploaded.swift` (per-argv-order NUL record contract, rc 0-iff-all-uploaded).
- **Apple (knowledge — not re-fetched)**: Foundation `FileManager.evictUbiquitousItem(at:)`;
  `URLResourceValues.ubiquitousItemIsUploaded` / `NSURLUbiquitousItemIsUploadedKey`
  ("current version fully uploaded"); Apple support guidance that iCloud Drive does not sync
  `.tmp`/temporary files. Flagged knowledge-level throughout; nothing in the design depends on
  an unverified Apple-side behavior being true.
