# Research: iCloud `brctl` evict/download safety (true-offload sub-mode)

> PACT Prepare-phase research for plan step 9 / Task #76 — the iCloud-native
> true-offload sub-mode. **Analysis only.** brctl is under-documented; every
> claim is cited and uncertainties are marked. References project memory
> `macos-icloud-offload-realities`.

## FEASIBILITY VERDICT (read this first) 🚩 BLOCKER on blind `evict`

**A safe, shell-script-only `brctl evict` sub-mode is NOT feasible as currently
scoped.** The load-bearing safety gate — *prove a file is FULLY UPLOADED to iCloud
before evicting it* — **cannot be reliably established from stock shell tools**
(`stat`, `mdls`, `brctl`). The only authoritative upload-state signal
(`NSURLUbiquitousItemIsUploadedKey`) is a Cocoa `URLResourceValues` API property with
**no stock command-line equivalent**, and there is **no authoritative documentation of
what `brctl evict` does to a not-yet-uploaded file** — so per the task's own rule,
evict-on-un-uploaded must be treated as **ASSUMED-DATA-LOSS-DANGEROUS**.

**Recommendation:** Do **not** ship blind `--evict`. Ship the **safe-direction**
operations only:
- `--icloud-status <path>` — report materialized vs **dataless** (via `stat -f %Sf` /
  `SF_DATALESS`) and in-iCloud (via `mdls`). Read-only, always safe.
- `--icloud-download <path>` — hydrate/materialize (`brctl download`). Only *adds*
  local data; reversible; cannot lose data.

Defer `evict` unless the architect accepts a **compiled helper** (tiny Swift/PyObjC
tool that reads `NSURLUbiquitousItemIsUploadedKey` per file and evicts only on `true`)
— which breaks the repo's "stock bash 3.2, no compiled deps" stance. Absent that
helper, evict cannot be made safe. Note also: the project **already has a reliable
space-freeing path** — the rclone-REMOTE offload from the #10 research — so the iCloud
brctl-evict path is the strictly riskier, inferior option and deferring it costs the
user nothing they can't get more safely elsewhere.

---

## Reasoning Chain

1. Offload's whole point is to **free local space**; on iCloud that requires
   eviction (dataless placeholder), because the CloudDocs dir is same-volume as `$HOME`
   (project memory) so a move frees nothing.
2. Eviction is only **safe if the canonical copy is already on Apple's servers** —
   evicting removes the local extents. If not uploaded, eviction *could* destroy the
   only copy.
3. Therefore the sub-mode **hinges entirely on a pre-evict "is fully uploaded?" gate.**
4. That gate needs a reliable, scriptable upload-state read. Research shows the only
   authoritative signal is a Cocoa API property with no stock CLI surface, and evict's
   behavior on un-uploaded files is undocumented.
5. → The gate cannot be built safely in shell → blind evict is unsafe → **blocker**;
   ship the safe read/hydrate directions and defer evict.

---

## 1. brctl subcommands (Sonoma / Sequoia)

`brctl` is the CLI control utility for `bird`/`fileproviderd`, the daemon managing
iCloud Drive. It is **under-documented and semi-legacy** — there is **no complete
official man page** with flags/exit codes; community man captures list only partial
subcommands. Treat its exit codes as **unreliable for a data-loss-critical gate.**

| Subcommand | Observed syntax | Purpose | Notes / uncertainty |
|------------|-----------------|---------|---------------------|
| `brctl evict <path>` | `brctl evict PATH` | Remove local data → **dataless** placeholder; keep in iCloud | **No documented behavior on un-uploaded files.** Directory arg: recursion behavior **undocumented** — batch via `find … -exec brctl evict {} \;` is the reliable pattern. |
| `brctl download <path>` | `brctl download PATH` | Force materialize / re-hydrate | Safe (adds data). Batch: `find . -type f -print0 \| xargs -0 brctl download`. |
| `brctl status [<path>]` | `brctl status` | Show daemon / sync state | Human-oriented text, **not a stable machine format** — fragile to parse. |
| `brctl quota` | `brctl quota` | Show iCloud quota | Project memory: quota can be a red herring (TBs free while sync wedged). |
| `brctl log [--wait]` | `brctl log --wait` | Stream live sync activity | Diagnostic only; not a reliable gate. |
| `brctl dump` | `brctl dump` | Dump internal state snapshot | Diagnostic; verbose; not a stable parse target. |
| `brctl monitor <bundleid>` | `brctl monitor com.apple.CloudDocs` | Watch sync status | Continuous; not a one-shot gate. |

**Prerequisites / entitlements:** runs as the user (no root). No documented FDA
requirement for evict/download, but behavior depends on the FileProvider mode (see §3).
**Path semantics:** operates on paths under
`~/Library/Mobile Documents/com~apple~CloudDocs/`; absolute paths are safest.

**Sonoma change (important):** iCloud Drive migrated to the **FileProvider** framework.
With **Optimize Mac Storage OFF**, iCloud Drive is a **replicated** provider and
**Sonoma will not let you evict** (evict is a no-op / disallowed). With it **ON**, it's
a **non-replicated** provider and eviction is available. (Sources: Eclectic Light Co;
MacRumors forum; project memory — "with Optimize Storage OFF, `brctl evict` is a no-op.")

## 2. LOAD-BEARING: verifying "fully uploaded" before evict

This is the crux, and the answer is **negative for a stock shell script.**

**Authoritative upload signal (API-only):** `NSURLUbiquitousItemIsUploadedKey` on
`NSURL`/`URLResourceValues` returns `true`/`1` when the item is fully uploaded to
iCloud. **This is the correct signal — but it is a Cocoa API property, not exposed by
any stock command-line tool.** Reading it requires compiled Swift/Obj-C or a scripting
bridge (PyObjC), neither guaranteed on a stock Mac.

**What shell tools *can* see (and why they're insufficient):**
- `stat -f %Sf <path>` / `stat.st_flags` → the **`SF_DATALESS`** (`dataless`) flag tells
  you a file is **already evicted / not materialized locally**. Useful for the
  **already-dataless no-op check** and for `--icloud-status`, but it says nothing about
  **upload** completion. (Eclectic Light Co: "tell whether a file is dataless by calling
  stat or getattrlist and examining if SF_DATALESS is present in stat.st_flags.")
- `mdls <path>` → `kMDItemFSIsUbiquitous` = is-in-iCloud (boolean-ish), **not** a
  reliable "fully uploaded" boolean. Spotlight metadata is also unreliable for evicted
  items (indexing is stripped).
- `ubiquitousItemDownloadingStatus` (`URLResourceValues`) → **download** state
  (`NotDownloaded` vs `Current`), the *opposite* axis from upload. API-only anyway.
- `brctl status`/`log` → human text; parsing it as a per-file upload gate is fragile
  and version-dependent.

**What `brctl evict` does to a not-yet-uploaded file:** **UNKNOWN — undocumented.**
The definitive sources (Howard Oakley's Sonoma FileProvider/eviction articles) describe
the eviction *mechanism* but **explicitly do not address the un-uploaded case.** Per the
task's rule and basic data-safety, treat it as **ASSUMED-DANGEROUS** and require a
positive upload confirmation that we cannot obtain from shell.

**Already-dataless file:** evict is expected to be a **no-op** (already has no local
extents) — detectable via `SF_DATALESS`, so the script can skip those cleanly.

**Directory evict:** recursion behavior is **undocumented**; do not assume. Use explicit
per-file `find … -exec` if evict were ever shipped.

## 3. Prerequisite detection

| Prereq | How to detect (script) | Reliability |
|--------|------------------------|-------------|
| macOS | `uname -s` = `Darwin`; min version via `sw_vers -productVersion` (FileProvider model is Sonoma 14+; evict semantics changed there) | Reliable |
| Path under iCloud Drive | prefix `"$HOME/Library/Mobile Documents/com~apple~CloudDocs"` (matches cloud-xdg's existing iCloud recognition in `cloud_root_is_live`) | Reliable |
| iCloud signed in / `bird` running | `pgrep -x bird` / `pgrep -x fileproviderd`; `brctl status` responds | Weak/heuristic |
| **"Optimize Mac Storage" ON** | **No documented stable `defaults`/plist key.** It's an account/FileProvider setting, not a public preference domain. | **Not reliably detectable** — must gate on explicit user confirmation |

Because Optimize-Storage state (which *determines whether evict even works*) has no
documented programmatic read, an evict sub-mode would have to **gate on an explicit
`--i-understand-data-loss-risk` confirmation** rather than a real check — another reason
it can't be made genuinely safe.

## 4. Failure modes & reversibility

- **Reversibility:** eviction is normally reversible — evicted (dataless) files
  re-download on access or via `brctl download`. **BUT** this assumes the cloud copy
  exists — which is exactly the un-uploaded case we can't verify. If not uploaded,
  there may be nothing to re-download → **irreversible loss.**
- **What breaks on evict:** **Spotlight can't index** dataless content; Finder previews
  blank; some metadata/xattrs are affected (a macOS 14.4 bug even *deleted saved
  versions* on eviction — fixed in 14.4.1, but illustrates the fragility). Finder tags
  live in xattrs which are retained while dataless, but behavior across versions is
  uncertain.
- **Stuck-sync wedge (project memory):** one item stuck *uploading/downloading* freezes
  the **entire** sync queue (a 30 GB `qemu` image wedged all sync for a session;
  `killall bird` insufficient — needed sign-out/in or reboot). A wedged queue means a
  file may *never* upload while appearing present → evicting it is precisely the
  data-loss trap. Detecting a wedge from a script is unreliable (`brctl status` showed a
  frozen `last-sync` that survived restarts).

## 5. Recommendation (what the architect should design around)

**Ship (safe):**
1. `--icloud-status <path>` — report per item: in-iCloud (`mdls kMDItemFSIsUbiquitous`),
   materialized-vs-**dataless** (`stat -f %Sf` contains `dataless` → SF_DATALESS), and
   size-if-downloaded. Pure read; no risk. Reuses cloud-xdg's iCloud-path recognition.
2. `--icloud-download <path>` — `brctl download` (hydrate). Only adds local data;
   reversible; safe. Batch via `find -print0 | xargs -0`.

**Defer / BLOCK (unsafe):**
3. `--icloud-evict` — **do not ship** without an accepted **compiled upload-state
   helper**. If the architect chooses to pursue it later, the *minimum* safe gate is:
   (a) macOS 14+; (b) path under CloudDocs; (c) a helper reading
   `NSURLUbiquitousItemIsUploadedKey == true` **per file**; (d) file is **not** already
   dataless; (e) sync not wedged (best-effort); (f) explicit
   `--i-understand-data-loss-risk`. Without (c), the gate is unsatisfiable → unsafe.

**Framing for the user:** point anyone wanting *guaranteed* space-freeing at the
**rclone-remote offload** (from the #10 research) — it verifies durable upload with
`rclone check --download` before dropping local, which is the exact guarantee iCloud
evict cannot give from a script.

---

## References

- Eclectic Light Co (Howard Oakley) — "iCloud Drive in Sonoma: FileProvider and eviction" — https://eclecticlight.co/2023/11/21/icloud-drive-in-sonoma-fileprovider-and-eviction/
- Eclectic Light Co — "macOS Sonoma has changed iCloud Drive radically" (SF_DATALESS; Optimize-Storage OFF blocks eviction) — https://eclecticlight.co/2023/10/25/macos-sonoma-has-changed-icloud-drive-radically/
- Eclectic Light Co — "How iCloud Drive works in macOS Sonoma" (14.4 eviction-deletes-versions bug, fixed 14.4.1) — https://eclecticlight.co/2024/03/18/how-icloud-drive-works-in-macos-sonoma/
- Apple Developer — `NSURLUbiquitousItemIsUploadedKey` / `ubiquitousItemDownloadingStatus` (URLResourceValues; API-only, no stock CLI) — https://developer.apple.com/documentation/foundation/urlresourcekey
- techgarden / alphasmanifesto — "Manually downloading or evicting iCloud files" (brctl evict/download usage; requires Optimize Storage; strips metadata/Spotlight) — https://techgarden.alphasmanifesto.com/mac/Manually-downloading-or-evicting-iCloud-files
- Ben Clews — "Reclaiming Disk Space from iCloud Drive on macOS" (`find … -exec brctl evict`) — https://clews.id.au/til/reclaiming-disk-space-from-icloud-drive-on-macos/
- brctl partial man capture — https://man.ilayk.com/man/brctl/
- Project memory: `macos-icloud-offload-realities` (Optimize-Storage-ON required for evict; same-volume non-gain; one stuck item wedges all sync; brctl strips metadata/Spotlight; quota red herring).

## Uncertainties (explicitly flagged)

- **[HIGH]** Behavior of `brctl evict` on a not-yet-uploaded file — **undocumented**; assumed dangerous.
- **[MED]** Whether a `swift -e`/PyObjC one-liner to read `NSURLUbiquitousItemIsUploadedKey` is acceptable (depends on Xcode CLT / PyObjC being present — not stock-guaranteed).
- **[MED]** Programmatic detection of "Optimize Mac Storage" state — no documented stable key found.
- **[LOW]** Exact directory/recursive semantics of `brctl evict`; exit-code stability across macOS versions.
