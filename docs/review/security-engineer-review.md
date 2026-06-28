# Security Review — cloud-xdg-provision.sh

**Reviewer:** pact-security-engineer
**Target:** PR #1 — `bin/cloud-xdg-provision.sh` (340 lines), `Makefile`, `hooks/pre-commit`
**Date:** 2026-06-28
**Threat model:** Single-user tool, run by the data owner with their own privileges, against
their own `$HOME` and a user-controlled `$CLOUD_ROOT`. Migrates real, potentially-PII user
data (Documents, Desktop, Pictures) by rsync → mv → symlink. No network input, no setuid,
no multi-tenant surface. **The dominant risk class is DATA LOSS, not classic injection.**

---

## Verdict

The injection/traversal surface is clean. The script is well-quoted and uses no `eval`.
**But the relocate path can silently destroy user data** under conditions that are *normal*
for cloud FUSE mounts, and there is **no verification that the destination is actually the
cloud** before the original is moved aside. For a tool whose entire premise is "the real data
now lives in the cloud," those gaps are blocking.

| Severity | Count |
|----------|-------|
| BLOCKING | 3 |
| MINOR    | 5 |
| FUTURE   | 3 |

---

## BLOCKING

### B1 — No destination verification before destructive `mv`; FUSE "success" → data loss
**`bin/cloud-xdg-provision.sh:253-258`**

```sh
run mkdir -p "$dst"
if [ "$copier" = "rsync -a" ]; then run rsync -a "$src/" "$dst/"
else run cp -a "$src/." "$dst/"; fi
run mv "$src" "$aside"          # original renamed aside
run ln -s "$dst" "$src"         # local path now points at cloud
```

The `mv` that moves the original out of the way happens **unconditionally** as soon as
`rsync`/`cp` returns 0. There is no post-copy verification (no `rsync --checksum` pass, no
file-count/byte comparison) that the data actually landed.

This is not a theoretical concern. The two supported Linux/Termux backends — `rclone mount`
and `google-drive-ocamlfuse` — perform **asynchronous, buffered uploads**. A local write into
the FUSE mount returns success immediately; the actual upload to the provider can fail later
(quota, token expiry, network drop) **after** `rsync` has already exited 0. Sequence:

1. `rsync` writes into the mount, sees local success, exits 0.
2. `mv "$src" "$aside"` — original is renamed aside (still on disk, good).
3. `ln -s` — `~/Documents` now points into the cloud folder.
4. Hours later the async upload silently fails. The cloud copy is incomplete or empty.
5. The script's own message (line 258) tells the user:
   *"Original preserved at: …  (delete once you've verified the cloud copy)."*
6. User glances at `~/Documents` (the symlink resolves to the local FUSE cache, looks fine),
   trusts the "verified" wording, deletes the `aside` backup → **data is gone.**

**Impact:** Permanent loss of PII directories (Documents, Pictures, Desktop).
**Fix:** After the copy, before `mv`, verify integrity against the real destination — e.g. a
second `rsync -ac --dry-run "$src/" "$dst/"` that must report zero differences, or an explicit
file-count + cumulative-byte comparison. Abort (leave the original in place) on any mismatch.
Do not advise deleting the `aside` backup in script output; deletion is the user's call after
*their own* verification, and the wording should say so.

---

### B2 — No mount-liveness check: migrates to local disk while claiming "cloud"
**`bin/cloud-xdg-provision.sh:137-147, 253-257`**

`resolve_cloud_root` accepts any `--cloud-root PATH` (or auto-globs a macOS GoogleDrive dir)
and only checks `[ -d "$d/My Drive" ]` on macOS. On Linux/Termux it accepts the path with **no
check that it is a live mount.**

When a FUSE cloud mount is **not mounted**, the mountpoint is an ordinary empty local
directory. If the user re-runs after a reboot (mount not yet up), or the mount silently
dropped, the script will:

1. `mkdir -p "$dst"` — succeeds on local disk.
2. `rsync -a` — copies gigabytes onto the **local root filesystem**, not the cloud.
3. `mv` + `ln -s` — originals moved aside, `~/Documents` → a *local* directory the user
   believes is cloud-backed.

Result: data is **not** in the cloud, **not** synced anywhere, possibly filling the root fs,
and the user's mental model ("my data is safe in Drive") is false. Combined with B1's "delete
the backup" guidance, this is a clean path to total loss with zero error output.

**Fix:** Before any relocate, require positive evidence the destination is a real mount —
e.g. `mountpoint -q` on the mount root, a sentinel file written by a prior successful sync, or
at minimum a `--i-understand-this-is-not-a-mount` style override. Refuse to relocate into a
path that is an empty plain directory on the same filesystem as `$HOME` unless explicitly
forced.

---

### B3 — `rsync -a` merges into a pre-existing cloud dir and clobbers cloud-side files, no backup
**`bin/cloud-xdg-provision.sh:184-191, 253-254`**

`ensure_cloud_tree` unconditionally `mkdir -p`s every offload folder in the cloud root *before*
relocation. So at relocate time `$dst` frequently already contains data — e.g. the same folder
already populated by **another machine** that ran this tool earlier (the explicit multi-OS use
case in the header comment).

`rsync -a "$src/" "$dst/"` with no `--ignore-existing` and no `--backup`:
- For same-named files, the **local copy overwrites the cloud copy** (rsync replaces dst when
  size/mtime differ). If machine B had a newer `report.docx` in the cloud and machine A runs
  the tool, machine A's older local version **silently overwrites** machine B's newer cloud
  version.
- The `aside` backup only preserves machine A's **local** original. The **clobbered cloud-side
  file has no backup anywhere.**

**Impact:** Silent cross-machine data clobbering in exactly the multi-OS scenario the tool is
built for. This is data loss with no recovery artifact.
**Fix:** Detect a non-empty destination and stop (or require an explicit merge flag). For the
intended "real data lives in cloud" model, the safe default when `$dst` is already populated is
to *not* push local over it — surface a conflict and let the user reconcile.

---

## MINOR

### M1 — No refusal to run as root; sudo-by-mistake corrupts home ownership
**`bin/cloud-xdg-provision.sh:29, whole script`**

The script never needs elevation and never calls `sudo`, which is correct. But there is no
`EUID`/`id -u` guard. If a user runs `sudo ./cloud-xdg-provision.sh --apply --relocate`
(cargo-culting sudo, as people do for "system setup" scripts):
- All `mkdir`/`mv`/`ln -s` run as root → new symlinks and `aside` directories become
  **root-owned** inside the user's home, breaking the user's ability to manage `~/Documents`.
- Depending on sudo config, `$HOME` may resolve to `/root`, pointing the whole operation at the
  wrong tree.

**Fix:** Add an early `[ "$(id -u)" -eq 0 ] && die "Do not run as root; this operates on your own \$HOME."`

### M2 — `write_user_dirs` truncates existing `user-dirs.dirs` with no backup
**`bin/cloud-xdg-provision.sh:261-277`**

Apply mode does `… } > "$f"` (line 276), overwriting the entire existing
`$XDG_CONFIG_HOME/user-dirs.dirs`. Any user customizations, comments, or non-managed
`XDG_*_DIR` entries are discarded with no `aside`-style backup — inconsistent with the careful
preservation the relocate path applies to data. Loss of config, not data, but silent.
**Fix:** Back up the existing file (`.pre-offload-$stamp`) before overwriting, or merge keys.

### M3 — `--cloud-root` accepts relative / traversal paths unchecked
**`bin/cloud-xdg-provision.sh:117, 190, 208`**

`--cloud-root ../../foo` is accepted verbatim; `mkdir -p "$CLOUD_ROOT/$cn"` then creates trees
relative to CWD, and symlinks point at them. Because every expansion is **properly quoted**
(see "What's clean" below), this is *not* an injection or privilege-crossing bug — the user
already has their own privileges — but it is a sharp footgun: a relative root silently scatters
folders under whatever directory the script happened to be launched from.
**Fix:** Require an absolute path (reject if `"${CLOUD_ROOT#/}" = "$CLOUD_ROOT"`), and
canonicalize before use.

### M4 — `aside` collision when destination name already exists
**`bin/cloud-xdg-provision.sh:249, 256`**

`aside="${src}.pre-offload-${stamp}"` with `stamp` at one-second resolution. The common
double-run case is guarded (after relocate `$src` is a symlink and is skipped at line 212/221),
so same-second self-collision is unlikely. But if `$aside` already exists as a directory,
`mv "$src" "$aside"` moves `$src` *inside* it (mv-into-dir semantics) rather than failing,
nesting the backup unexpectedly.
**Fix:** Fail if `$aside` already exists, or append a counter / use a higher-resolution stamp.

### M5 — Partial-relocate state on mid-sequence failure; no lock against concurrent runs
**`bin/cloud-xdg-provision.sh:246-259, 319-322`**

`relocate_dir` runs inside the `printf … | while read` subshell. `set -e` will abort on a
failed step, but the relocate sequence is not atomic: if it aborts after `mv` but before
`ln -s` (line 256→257), the original is at `$aside` (recoverable) and the local path is simply
missing — acceptable. However there is **no lock file**; two concurrent invocations (second
terminal, or cron + manual) can interleave the check-then-act on the same dir and produce
inconsistent state. **Fix:** Take a `flock`-based lock (or a mkdir-based lock for portability)
for the duration of the run.

---

## FUTURE

### F1 — TOCTOU windows in the redirect state machine (low risk under normal home perms)
**`bin/cloud-xdg-provision.sh:212-243`**

Between `[ ! -e "$localpath" ]` (227) and `ln -s` (228), and between `rmdir` (242) and `ln -s`
(243), another process could recreate the path. Exploitation requires write access to `$HOME`
(or to `$CLOUD_ROOT`), so under correct `0700` home permissions this is not a cross-user
attack — it degrades to a robustness issue (`ln -s` fails "File exists" → `set -e` abort).
Worth hardening (`ln -sfn` where intended, or `ln` into a temp name + atomic rename) but not a
vulnerability in the stated single-user model.

### F2 — `$dst` is not checked for being a symlink before rsync writes into it
**`bin/cloud-xdg-provision.sh:253-254`**

If `$CLOUD_ROOT/$cn` is itself a symlink (e.g. a pre-existing link pointing elsewhere),
`rsync -a "$src/" "$dst/"` follows it and writes into the link target. Same home/cloud
ownership boundary as F1, so low risk, but a defensive `[ -L "$dst" ] && die` would prevent a
surprising redirect of the migrated data.

### F3 — Emptiness check misreads unreadable directories as empty
**`bin/cloud-xdg-provision.sh:232, 242`**

`[ -n "$(ls -A "$localpath" 2>/dev/null)" ]` swallows errors: a directory that is non-empty but
unreadable (perms) evaluates as empty, falling through to the `rmdir` branch (242), which then
fails on the non-empty dir and aborts under `set -e`. Cosmetic/robustness; flagging for
completeness.

---

## What's clean (verified, not assumed)

- **No shell injection.** Every expansion of user-controlled data (`$CLOUD_ROOT`, `$STYLE`,
  `$src`, `$dst`, `$localpath`, `$target`) is double-quoted. No `eval`, no backticks on user
  input, nothing user-supplied reaches a command position unquoted. `--style` is whitelisted
  (`xdg|mac`, line 124). Confirmed by reading every command in the relocate/redirect/write
  paths.
- **No privilege escalation in the tool itself.** No `sudo`, no setuid, no writes outside
  `$HOME` and the user-named `$CLOUD_ROOT`. Runs entirely within the invoker's authority.
  (The exposure is the *absence* of a root-refusal guard — see M1 — not an escalation.)
- **Makefile / pre-commit are benign.** `make install` (`Makefile:19-23`) only `chmod +x`s repo
  scripts and symlinks the in-repo `hooks/pre-commit` into `.git/hooks/`. The hook
  (`hooks/pre-commit`) runs `make lint` (shellcheck). Standard git-hook behavior for a repo the
  user chose to clone and install; no privileged step, no remote fetch, no escalation.
- **Dry-run is the default** (`DRY_RUN=1`, line 51) and relocation requires the explicit
  `--apply --relocate` combination — good blast-radius hygiene.
- **The dangling-symlink ordering fix** (lines 216-224) is correct and well-reasoned: checking
  `[ -L ]` before `[ ! -e ]` avoids the `-e`-dereferences-dangling-link trap.

---

## Recommended gate

**Do not ship the relocate path (`--relocate`) as-is.** B1, B2, and B3 are independent routes
to silent, unrecoverable loss of PII data, and they compound: a dropped mount (B2) + async FUSE
false-success (B1) + "delete your backup" guidance = total loss with no error shown. The
dry-run and create-only paths are safe to ship. Recommend: add destination verification (B1),
mount-liveness check (B2), and populated-destination conflict handling (B3) before `--relocate`
is enabled by default in any release.
