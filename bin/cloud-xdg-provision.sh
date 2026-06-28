#!/usr/bin/env bash
#
# cloud-xdg-provision.sh
#
# Provision a CANONICAL, cross-OS user-data ontology that LIVES in your cloud
# drive, and redirect the local user-facing dirs (macOS + Linux/XDG) at it.
#
# This is NOT a backup mirror. The real data lives in the cloud root; your
# local ~/Documents, ~/Music, etc. become symlinks pointing into it.
#
# Spec basis (synthesis — no single ratified standard unifies these):
#   * XDG Base Directory Specification      -> config / data / state / cache
#   * xdg-user-dirs                          -> desktop/documents/music/...
#   * FHS 3.0 + systemd file-hierarchy(7)    -> the Linux root model
#   * Apple File System Programming Guide    -> ~/Library, ~/Movies naming
#
# HARD RULES enforced by this design:
#   1. Only the USER-DATA layer offloads. FHS/macOS *system* root dirs
#      (/usr /etc /var /opt /Applications /System /Library) are machine-managed
#      and never go to a cloud drive. Offloading them is a category error.
#   2. XDG *base* dirs (config/data/state/cache) stay LOCAL. They are
#      machine-specific, high-churn, or lock-sensitive (SQLite). Live config
#      belongs in git, not blob cloud.
#   3. Only XDG *user* dirs + a projects area offload cleanly. That is the
#      genuine cross-OS portable set.
#
# Compatible with stock macOS bash 3.2 (no associative arrays / mapfile).
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config — override via environment.
# ---------------------------------------------------------------------------
# CLOUD_ROOT = the cloud-resident user-data home (the "~" inside your drive).
#   macOS: auto-detected as "~/Library/CloudStorage/GoogleDrive-*/My Drive" if unset.
#   Linux/Termux: you MUST set CLOUD_ROOT to wherever the drive is mounted
#                 (rclone mount, google-drive-ocamlfuse, insync, etc.).
: "${CLOUD_ROOT:=}"

# STYLE = naming convention for the cloud folders.
#   xdg = lowercase (documents, music, videos)   [modern/default]
#   mac = capitalized (Documents, Music, Movies)
: "${STYLE:=xdg}"

# Local XDG base dirs (stay LOCAL — listed so we can ensure + report them).
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_DATA_HOME:=$HOME/.local/share}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
: "${XDG_CACHE_HOME:=$HOME/.cache}"

DRY_RUN=1          # 1 = print only; --apply to act
DO_RELOCATE=0      # move existing populated dirs into the cloud, then symlink
REDIRECT_DOWNLOADS=0  # downloads is triage/ephemeral; off by default
ALLOW_LOCAL_ROOT=0 # 1 = skip the cloud-mount liveness check (B4 override)
FAST_VERIFY=0      # 1 = size/mtime post-copy verify instead of checksum (B3)

# State for the relocate recovery trap (see relocate_dir / relocate_recovery_msg).
RELOCATE_ACTIVE=0
RELOCATE_SRC=""
RELOCATE_ASIDE=""
RELOCATE_DST=""

SELF="$(basename "$0")"

# ---------------------------------------------------------------------------
# The offload set.  Format:  canonical|macName|linuxName|xdgVar|redirect
#   canonical : folder name created in the cloud root (style applied)
#   macName   : the dir under $HOME on macOS (Apple naming, e.g. Movies)
#   linuxName : the dir under $HOME on Linux (XDG default naming)
#   xdgVar    : the user-dirs.dirs variable to write (empty = none)
#   redirect  : 1 = symlink local->cloud by default, 0 = create only
# ---------------------------------------------------------------------------
OFFLOAD_SET="
desktop|Desktop|Desktop|XDG_DESKTOP_DIR|1
documents|Documents|Documents|XDG_DOCUMENTS_DIR|1
downloads|Downloads|Downloads|XDG_DOWNLOAD_DIR|0
music|Music|Music|XDG_MUSIC_DIR|1
pictures|Pictures|Pictures|XDG_PICTURES_DIR|1
videos|Movies|Videos|XDG_VIDEOS_DIR|1
public|Public|Public|XDG_PUBLICSHARE_DIR|1
templates|Templates|Templates|XDG_TEMPLATES_DIR|1
projects|Projects|Projects||1
"

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
info() { printf '  • %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
run()  {
  # Print the command with each argument shell-quoted (printf %q, available in
  # bash 3.2) so a path containing spaces — e.g. the default macOS cloud root
  # ".../Mobile Documents/..." — renders as a copy-paste-safe command line rather
  # than ambiguous space-split words.
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    printf '  [run]    '; printf ' %q' "$@"; printf '\n'
    "$@"
  fi
}

# Recovery trap for the relocate mv->ln window. If the shell exits unexpectedly
# between renaming the original aside and creating the replacement symlink, the
# tree is in a recoverable-but-confusing half-state; print plainly where the data
# is so the user never panics or deletes the wrong thing. Armed only around that
# window (see relocate_dir); a no-op otherwise.
relocate_recovery_msg() {
  [ "${RELOCATE_ACTIVE:-0}" -eq 1 ] || return 0
  warn "INTERRUPTED mid-relocate — your data is SAFE, here is the state:"
  warn "  original:  moved to '$RELOCATE_ASIDE' if the rename finished, else still at '$RELOCATE_SRC'"
  warn "  cloud copy: '$RELOCATE_DST'"
  warn "  the symlink '$RELOCATE_SRC' may not exist yet. Re-run to finish. Delete NOTHING until verified."
}

usage() {
  cat <<EOF
$SELF — provision a cloud-resident, cross-OS user-data ontology and redirect
local user dirs into it. NOT a backup mirror; the data lives in the cloud root.

Usage: $SELF [options]
  --apply                Actually create folders / symlinks (default: dry-run).
  --relocate             Move existing populated local dirs INTO the cloud,
                         then replace them with symlinks. Original is renamed
                         aside (*.pre-offload-DATE), never deleted.
  --redirect-downloads   Also symlink Downloads (off by default; it's triage).
  --style xdg|mac        Cloud folder naming (default: xdg / lowercase).
  --cloud-root PATH      Cloud user-data home (auto-detected on macOS).
  --allow-local-root     Skip the cloud-mount liveness check. Needed for backends
                         that sync a PLAIN LOCAL folder on your home device rather
                         than a FUSE mount (insync, Dropbox CLI, Maestral) — these
                         are same-device and can't be auto-distinguished from a
                         dropped mount. Use deliberately: the check exists so a
                         dropped/unmounted cloud mount doesn't silently migrate
                         your data to local disk.
  --fast-verify          After a relocate copy, verify with size+mtime instead of
                         a full checksum read-back. Faster on huge libraries, but
                         will NOT catch a silent FUSE async-upload failure.
  -h, --help             This help.

Nothing is moved without --apply --relocate together.
EOF
}

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)              DRY_RUN=0 ;;
    --relocate)           DO_RELOCATE=1 ;;
    --redirect-downloads) REDIRECT_DOWNLOADS=1 ;;
    --allow-local-root)   ALLOW_LOCAL_ROOT=1 ;;
    --fast-verify)        FAST_VERIFY=1 ;;
    --style)              shift; STYLE="${1:?--style needs xdg|mac}" ;;
    --cloud-root)         shift; CLOUD_ROOT="${1:?--cloud-root needs a path}" ;;
    -h|--help)            usage; exit 0 ;;
    *)                    die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

case "$STYLE" in xdg|mac) ;; *) die "invalid --style: $STYLE" ;; esac

# ---------------------------------------------------------------------------
# Platform + cloud root resolution
# ---------------------------------------------------------------------------
case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  Linux)
    if [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux ]; then
      PLATFORM=termux; else PLATFORM=linux; fi ;;
  *) PLATFORM=unknown ;;
esac

resolve_cloud_root() {
  if [ -n "$CLOUD_ROOT" ]; then return 0; fi
  if [ "$PLATFORM" = "macos" ]; then
    local d
    for d in "$HOME"/Library/CloudStorage/GoogleDrive-*; do
      if [ -d "$d/My Drive" ]; then CLOUD_ROOT="$d/My Drive"; return 0; fi
    done
    die "No Google Drive mount found. Pass --cloud-root PATH."
  fi
  die "CLOUD_ROOT unset. On $PLATFORM, set it to your mounted drive path (e.g. an rclone mount). Pass --cloud-root PATH."
}

# Normalize CLOUD_ROOT to an absolute, trailing-slash-free path.
#   Why: a RELATIVE --cloud-root is a silent footgun. `mkdir -p "$CLOUD_ROOT/$cn"`
#   resolves the relative part against the CWD, but `ln -s "$target" "$localpath"`
#   stores the target VERBATIM and the kernel resolves it against the symlink's
#   own dir ($HOME) on access — so the link points somewhere that was never
#   created: a DANGLING link. A trailing slash separately breaks the idempotency
#   check (readlink output never carries it, so "$target" != stored link → the
#   script thinks the link is wrong every re-run). Stock macOS has no realpath/
#   `readlink -f`, so we normalize in pure bash 3.2.
normalize_cloud_root() {
  case "$CLOUD_ROOT" in
    /*) : ;;                                    # already absolute
    *)  CLOUD_ROOT="$(pwd)/$CLOUD_ROOT" ;;      # absolutize against CWD
  esac
  # Strip trailing slash(es), but never reduce a bare "/" to the empty string.
  while [ "$CLOUD_ROOT" != "/" ] && [ "${CLOUD_ROOT%/}" != "$CLOUD_ROOT" ]; do
    CLOUD_ROOT="${CLOUD_ROOT%/}"
  done
}

# B4: is CLOUD_ROOT a LIVE cloud location, or a dead/empty local directory?
#   An unmounted FUSE mountpoint is just an empty dir on the local filesystem, so
#   without this check an apply/relocate would silently copy gigabytes to local
#   disk and move the originals aside — the user believing it's cloud-backed.
#   Detection MUST branch on platform (per security review):
#     * macOS: iCloud + Google-Drive File-Provider roots live on the SAME APFS
#       volume as $HOME, so a device-id test gives false negatives. Recognise the
#       known provider roots by path instead.
#     * Linux/Termux: require the backing filesystem TYPE to be FUSE. A live
#       rclone / google-drive-ocamlfuse mount reports fuse; a dropped mountpoint
#       or a non-cloud mount (ext4 USB, tmpfs, a second partition) reports its
#       real type and is refused — closing the device-only false-PASS. The bare
#       device-id test is kept only as a fallback when fstype is undeterminable.
#       Note: this does NOT regress insync/Dropbox-CLI/Maestral — those sync a
#       same-device, non-FUSE local folder, so they were already refused by the
#       device test too and still need --allow-local-root (friction, not danger).
#   Returns 0 = positive evidence of a live cloud root; 1 = not (or unknown).
cloud_root_is_live() {
  case "$PLATFORM" in
    macos)
      case "$CLOUD_ROOT" in
        "$HOME"/Library/CloudStorage/*)       return 0 ;;  # Google Drive / OneDrive / Dropbox / Box (File Provider)
        "$HOME"/Library/Mobile\ Documents/*)  return 0 ;;  # iCloud Drive
        *)                                    return 1 ;;
      esac ;;
    linux|termux)
      local probe fstype dev_root dev_home
      probe="$CLOUD_ROOT"
      while [ ! -e "$probe" ] && [ "$probe" != "/" ]; do probe="$(dirname "$probe")"; done
      # `stat -f -c %T` names the fstype. Only a KNOWN-concrete-local filesystem
      # returns "not cloud" — anything unrecognised (empty, or an old coreutils
      # printing the raw fuse magic as "UNKNOWN (0x65735546)") FALLS THROUGH to the
      # device heuristic rather than over-refusing a possibly-live mount. This is
      # fail-safe: refuse only what we're sure is local.
      fstype="$(stat -f -c %T "$probe" 2>/dev/null || true)"
      case "$fstype" in
        fuse|fuseblk|fuse.*) return 0 ;;                                  # live FUSE cloud mount
        ext2|ext3|ext4|xfs|btrfs|tmpfs|vfat|exfat|ntfs|zfs|f2fs) return 1 ;;  # known local FS, not cloud
        *) : ;;                                                           # empty / UNKNOWN (0x…) → fall through to st_dev
      esac
      # Device fallback (fstype undeterminable): a different device than $HOME is
      # weak evidence of a separate mount. RESIDUAL (acceptable — retained aside
      # backup is the net, --allow-local-root is the escape hatch): a non-cloud
      # mount like /mnt/usb on a host where fstype is unreadable would false-PASS.
      dev_root="$(stat -c %d "$probe" 2>/dev/null || true)"
      dev_home="$(stat -c %d "$HOME"  2>/dev/null || true)"
      if [ -n "$dev_root" ] && [ -n "$dev_home" ] && [ "$dev_root" != "$dev_home" ]; then
        return 0
      fi
      return 1 ;;
    *) return 1 ;;
  esac
}

# Gate apply/relocate on cloud-root liveness (B4). Dry-run only warns so users can
# still preview a plan before the mount is up.
check_cloud_liveness() {
  [ "$ALLOW_LOCAL_ROOT" -eq 1 ] && return 0
  cloud_root_is_live && return 0
  if [ "$DRY_RUN" -eq 0 ]; then
    die "CLOUD_ROOT does not look like a live cloud mount:
    $CLOUD_ROOT
  On macOS it should be under ~/Library/CloudStorage/ (Google Drive etc.) or
  ~/Library/Mobile Documents/ (iCloud). On Linux/Termux it must be a mounted
  FUSE filesystem (a different device than \$HOME) — an unmounted mountpoint is
  an empty local dir, and migrating into it would copy your data to local disk
  while the originals are moved aside. Bring the mount up, or pass
  --allow-local-root if you really mean a plain local directory."
  fi
  warn "CLOUD_ROOT does not look like a live cloud mount; --apply will refuse it without --allow-local-root."
}

# style-applied cloud folder name.  $1 = canonical (xdg/lowercase name), $2 = the
# Apple name (the OFFLOAD_SET macName column).  mac style returns the documented
# Apple name verbatim — NOT a naive capitalize of the canonical, because those
# disagree for videos (Apple "Movies" vs capitalized "Videos") and a mismatch
# would make the cloud folder and the symlink target diverge.
cloud_name() {
  if [ "$STYLE" = "mac" ]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

# local home dir name for current platform
local_name() {
  if [ "$PLATFORM" = "macos" ]; then printf '%s' "$2"; else printf '%s' "$3"; fi
}

# ---------------------------------------------------------------------------
# Field splitter (3.2-safe; no here-strings on assoc arrays)
# ---------------------------------------------------------------------------
field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
ensure_local_base() {
  log "XDG base dirs — kept LOCAL (config/data/state/cache):"
  local d
  for d in "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"; do
    run mkdir -p "$d"
  done
  info "These never offload: machine-specific, high-churn, or SQLite-locked."
}

ensure_cloud_tree() {
  log "Cloud user-data ontology under: $CLOUD_ROOT"
  local line cn
  printf '%s\n' "$OFFLOAD_SET" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    cn="$(cloud_name "$(field "$line" 1)" "$(field "$line" 2)")"
    run mkdir -p "$CLOUD_ROOT/$cn"
  done
}

redirect_one() {
  local line="$1"
  local canon mac lin xdgvar wantredir cn ln localpath target
  canon="$(field "$line" 1)"; mac="$(field "$line" 2)"
  lin="$(field "$line" 3)"; xdgvar="$(field "$line" 4)"
  wantredir="$(field "$line" 5)"

  [ "$wantredir" = "1" ] || return 0
  if [ "$canon" = "downloads" ] && [ "$REDIRECT_DOWNLOADS" -ne 1 ]; then
    info "skip redirect: downloads (use --redirect-downloads to enable)"; return 0
  fi

  cn="$(cloud_name "$canon" "$mac")"
  ln="$(local_name "$canon" "$mac" "$lin")"
  target="$CLOUD_ROOT/$cn"
  localpath="$HOME/$ln"

  # already correctly symlinked?
  if [ -L "$localpath" ] && [ "$(readlink "$localpath")" = "$target" ]; then
    info "ok: $ln -> $target"; return 0
  fi

  # any other symlink (dangling, or pointing elsewhere): leave it untouched.
  # NOTE: this must precede the `[ ! -e ]` check below — `-e` dereferences a
  # symlink, so a DANGLING link (target gone) reports "missing" and would fall
  # into the `ln -s` branch, which then fails ("File exists") on the still-present
  # link inode and, under `set -e`, aborts the whole --apply run.
  if [ -L "$localpath" ]; then
    warn "$ln is a symlink to '$(readlink "$localpath")'; leaving it. Remove manually if you want it repointed."
    return 0
  fi

  # truly missing (not a file, not a symlink): just symlink
  if [ ! -e "$localpath" ]; then
    run ln -s "$target" "$localpath"; return 0
  fi

  # populated real directory
  if [ -d "$localpath" ] && [ -n "$(ls -A "$localpath" 2>/dev/null)" ]; then
    if [ "$DO_RELOCATE" -ne 1 ]; then
      warn "$ln has contents and is NOT a symlink. Run with --relocate to migrate it."
      return 0
    fi
    relocate_dir "$localpath" "$target"
    return 0
  fi

  # empty real dir: replace with symlink
  run rmdir "$localpath"
  run ln -s "$target" "$localpath"
}

# Verify a relocate copy before the original is moved aside (B3).
#   IMPORTANT (per security review): this proves INTEGRITY, not DURABILITY. The
#   -c checksum read-back is served from the FUSE mount's local VFS cache — the
#   same cache that may not have uploaded to the provider yet — so it confirms the
#   bytes are correctly present in the mount's *view*, NOT that they are safely on
#   the provider. Async upload failure (quota/token/network, hours later) is NOT
#   caught here. The thing that actually protects against that is the RETAINED
#   `aside` backup (see relocate_dir) — never gate keeping that backup on verify.
#   What -c DOES catch: a truncated/corrupt copy AT VERIFY TIME (read-back through
#   the cache); it does NOT prove the async cloud upload will complete — that's
#   precisely why the aside backup is retained. --fast-verify drops -c to
#   size+mtime; the aside covers the rest. cp-fallback (no rsync) compares file
#   count + exact byte totals.
#   Returns 0 = verified identical; 1 = mismatch (caller must NOT move the original).
verify_copy() {
  local vsrc="$1" vdst="$2" vcopier="$3" diff n_src n_dst b_src b_dst
  if [ "$vcopier" = "rsync -a" ]; then
    # -n dry-run; print the name of anything that still differs. A non-empty,
    # non-directory line means a file is missing or mismatched at the destination.
    # Default adds -c (checksum read-back); --fast-verify drops it to size+mtime.
    if [ "$FAST_VERIFY" -eq 1 ]; then
      diff="$(rsync -a -n --out-format='%n' "$vsrc/" "$vdst/" 2>/dev/null)" || diff="__RSYNC_ERR__"
    else
      diff="$(rsync -ac -n --out-format='%n' "$vsrc/" "$vdst/" 2>/dev/null)" || diff="__RSYNC_ERR__"
    fi
    if [ "$diff" = "__RSYNC_ERR__" ]; then
      warn "verification rsync could not read the destination ($vdst)."
      return 1
    fi
    diff="$(printf '%s\n' "$diff" | grep -v '/$' | grep -v '^$' || true)"
    [ -z "$diff" ] && return 0
    warn "post-copy verification found unsynced/changed files:"; printf '%s\n' "$diff" | sed 's/^/      /' >&2
    return 1
  fi
  # cp fallback: compare file count and total bytes (best effort without rsync).
  n_src="$(find "$vsrc" -type f 2>/dev/null | wc -l | tr -d ' ')"
  n_dst="$(find "$vdst" -type f 2>/dev/null | wc -l | tr -d ' ')"
  b_src="$(find "$vsrc" -type f -exec wc -c {} + 2>/dev/null | awk '{s+=$1} END{print s+0}')"
  b_dst="$(find "$vdst" -type f -exec wc -c {} + 2>/dev/null | awk '{s+=$1} END{print s+0}')"
  if [ "$n_src" = "$n_dst" ] && [ "$b_src" = "$b_dst" ]; then return 0; fi
  warn "post-copy verification (count/bytes) mismatch: src=$n_src files/$b_src B  dst=$n_dst files/$b_dst B"
  return 1
}

relocate_dir() {
  local src="$1" dst="$2" stamp aside copier probe n acl_listing

  # B6 (issue #9): macOS 'group:everyone deny delete' ACL on standard special
  # folders. macOS stamps Desktop/Documents/Downloads/Music/Movies/Pictures/Public
  # with a deny-delete ACL. Renaming a dir needs the `delete` right, so `mv` fails —
  # and NO macOS layer can rescue it: a deny ACE always wins, so Full Disk Access
  # CANNOT override it (verified on a real Mac: FDA granted + effective + rebooted,
  # still blocked). This is NOT a TCC problem, so the old "grant Full Disk Access
  # and retry" advice was wrong and could never work. Detect the ACL on the ACTUAL
  # dir (not by hardcoded name) so this naturally covers the standard folders AND
  # any other ACL-protected dir, while unprotected custom dirs (Projects, Templates,
  # …) relocate normally. macOS only — `ls -lde` is a BSD/macOS extension. Caught
  # BEFORE the B5 cloud guard and the B2 rename-probe so the accurate message wins
  # and nothing is copied or moved. `ls -lde` is the documented way to read a dir's
  # ACL on macOS; we capture it and case-match (no `ls | grep`) for the deny ACE.
  if [ "$PLATFORM" = "macos" ]; then
    acl_listing="$(ls -lde "$src" 2>/dev/null || true)"
    case "$acl_listing" in
      *"deny delete"*)
        warn "cannot relocate $src — macOS protects it with a 'group:everyone deny delete' ACL."
        warn "  This is the ACL, NOT TCC: Full Disk Access CANNOT override a deny ACE."
        case "$(basename "$src")" in
          Desktop|Documents)
            warn "  Use Apple's native feature instead: System Settings > [Apple ID] > iCloud >"
            warn "  iCloud Drive > 'Desktop & Documents Folders'. Skipping — nothing copied." ;;
          Music|Movies|Pictures|Public)
            warn "  There is no folder-level iCloud option for this dir (use the Photos app or"
            warn "  Apple Music where applicable; otherwise leave it local). Skipping — nothing copied." ;;
          *)
            warn "  This dir cannot be relocated while the deny-delete ACL is present."
            warn "  Skipping — nothing copied." ;;
        esac
        return 0 ;;
    esac
  fi

  stamp="$(date +%Y%m%d-%H%M%S)"
  # Guarantee a UNIQUE aside name. The stamp is second-resolution, so a
  # same-second re-run (or a leftover stale aside) could collide — and
  # `mv "$src" "$aside"` onto an existing directory moves src INSIDE it (nesting),
  # which would also make the "Original kept at: $aside" message point at the
  # wrong place. Append a counter until the name is free.
  aside="${src}.pre-offload-${stamp}"
  n=1
  while [ -e "$aside" ] || [ -L "$aside" ]; do
    aside="${src}.pre-offload-${stamp}.${n}"; n=$((n + 1))
  done
  if command -v rsync >/dev/null 2>&1; then copier="rsync -a"; else copier="cp -a"; fi

  # B5: refuse to migrate INTO a cloud folder that already has content. It may be
  # data synced from ANOTHER machine (the multi-OS use case); `rsync -a` would
  # overwrite newer cloud files with our older local ones, and the aside backup
  # only preserves the LOCAL original — the clobbered cloud file would be lost.
  if [ -d "$dst" ] && [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
    warn "cloud destination is not empty: $dst"
    warn "  It may hold data synced from another machine. Refusing to migrate"
    warn "  $src into it (would risk clobbering newer cloud files with no backup)."
    warn "  Reconcile manually — merge or rename the existing cloud folder — then retry."
    return 0
  fi

  # B2: macOS TCC pre-flight, for a GENUINE permission block that is NOT the
  # deny-delete ACL (that case was caught and skipped above with accurate guidance).
  # A terminal without Full Disk Access can still be blocked from renaming some dirs,
  # and the failure otherwise lands at `mv` AFTER rsync has already copied
  # everything. Probe up-front so we fail fast having copied NOTHING.
  # We probe with the EXACT operation relocate performs — renaming the dir — which
  # is a faithful TCC test. The rename is immediately reverted, AND an
  # EXIT/INT/TERM trap guarantees the revert if the process is killed at ANY point
  # during the probe — armed BEFORE the first rename so even the sub-millisecond
  # window can't strand the dir (the revert is a harmless no-op if the rename
  # never happened). macOS only; dry-run never touches anything.
  if [ "$DRY_RUN" -eq 0 ] && [ "$PLATFORM" = "macos" ]; then
    probe="${src}.tcc-probe.$$"
    trap 'mv "$probe" "$src" 2>/dev/null || true' EXIT INT TERM
    if ! mv "$src" "$probe" 2>/dev/null; then
      trap - EXIT INT TERM
      warn "cannot rename $src — macOS is blocking the rename (not the deny-delete ACL)."
      warn "  If your terminal lacks Full Disk Access, grant it: System Settings >"
      warn "  Privacy & Security > Full Disk Access → add your terminal, then retry."
      warn "  Skipping this dir — nothing copied."
      return 0
    fi
    mv "$probe" "$src"
    trap - EXIT INT TERM
  fi

  log "RELOCATE  $src  ->  $dst   (copier: $copier)"
  warn "Large dirs (e.g. a 100k-track Music library) can take a long time and a lot of cloud quota."
  run mkdir -p "$dst"
  if [ "$copier" = "rsync -a" ]; then run rsync -a "$src/" "$dst/"
  else run cp -a "$src/." "$dst/"; fi

  # B3: verify the copy before the destructive mv. Apply mode only (dry-run copied
  # nothing). On mismatch, abort WITHOUT moving the original — data stays put.
  if [ "$DRY_RUN" -eq 0 ]; then
    verify_copy "$src" "$dst" "$copier" \
      || die "post-copy verification FAILED for $src -> $dst.
  The copy is incomplete in the cloud mount's view. The original was left
  untouched and nothing was moved. Check the mount (quota, token, network),
  then retry. Delete nothing."
  fi

  # Recovery net for the mv -> ln window: if the shell exits unexpectedly here
  # (set -e abort, SIGINT, crash), print plainly where everything is. Armed only
  # in apply mode — in dry-run the run-lines are no-op prints, so a Ctrl-C there
  # must not print a spurious "INTERRUPTED mid-relocate" message.
  if [ "$DRY_RUN" -eq 0 ]; then
    RELOCATE_ACTIVE=1; RELOCATE_SRC="$src"; RELOCATE_ASIDE="$aside"; RELOCATE_DST="$dst"
    trap relocate_recovery_msg EXIT INT TERM
  fi
  run mv "$src" "$aside"
  run ln -s "$dst" "$src"
  if [ "$DRY_RUN" -eq 0 ]; then trap - EXIT INT TERM; RELOCATE_ACTIVE=0; fi

  info "Original kept at: $aside"
  info "The script CANNOT confirm the cloud upload is durable — providers upload"
  info "asynchronously. Treat '$aside' as your safety copy and delete it ONLY after"
  info "you've independently confirmed the provider shows every file."
}

write_user_dirs() {
  [ "$PLATFORM" = "macos" ] && { info "macOS: user-dirs.dirs not used (symlinks handle it)."; return 0; }
  local f="$XDG_CONFIG_HOME/user-dirs.dirs"
  log "Writing XDG user-dirs: $f"
  if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] would write $f"; return 0; fi
  mkdir -p "$XDG_CONFIG_HOME"
  {
    printf '# Generated by %s — points XDG user dirs at the cloud ontology.\n' "$SELF"
    local line canon xdgvar cn
    printf '%s\n' "$OFFLOAD_SET" | while IFS= read -r line; do
      [ -z "$line" ] && continue
      xdgvar="$(field "$line" 4)"; [ -z "$xdgvar" ] && continue
      cn="$(cloud_name "$(field "$line" 1)" "$(field "$line" 2)")"
      printf '%s="%s"\n' "$xdgvar" "$CLOUD_ROOT/$cn"
    done
  } > "$f"
  info "Wrote $f"
}

print_mapping() {
  cat <<EOF

Canonical mapping (FHS / XDG / macOS -> cloud folder)
  config    XDG_CONFIG_HOME   ~/.config            -> LOCAL ONLY (git for dotfiles)
  data      XDG_DATA_HOME     ~/.local/share       -> LOCAL ONLY (curate ports by hand)
  state     XDG_STATE_HOME    ~/.local/state       -> LOCAL ONLY (logs/history)
  cache     XDG_CACHE_HOME    ~/.cache             -> LOCAL ONLY (never cloud)
  desktop   XDG_DESKTOP_DIR   ~/Desktop            -> $CLOUD_ROOT/$(cloud_name desktop Desktop)
  documents XDG_DOCUMENTS_DIR ~/Documents          -> $CLOUD_ROOT/$(cloud_name documents Documents)
  downloads XDG_DOWNLOAD_DIR  ~/Downloads          -> create-only (triage)
  music     XDG_MUSIC_DIR     ~/Music              -> $CLOUD_ROOT/$(cloud_name music Music)
  pictures  XDG_PICTURES_DIR  ~/Pictures           -> $CLOUD_ROOT/$(cloud_name pictures Pictures)
  videos    XDG_VIDEOS_DIR    ~/Movies (mac)       -> $CLOUD_ROOT/$(cloud_name videos Movies)
  public    XDG_PUBLICSHARE   ~/Public             -> $CLOUD_ROOT/$(cloud_name public Public)
  templates XDG_TEMPLATES_DIR ~/Templates          -> $CLOUD_ROOT/$(cloud_name templates Templates)
  projects  (convention)      ~/Projects           -> $CLOUD_ROOT/$(cloud_name projects Projects)

System root dirs (/ /usr /etc /var /opt /Applications /System /Library):
  machine-managed — NOT offloadable. Excluded by design.
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  resolve_cloud_root
  normalize_cloud_root
  check_cloud_liveness
  log "============================================================="
  log " cloud-xdg-provision  platform=$PLATFORM  style=$STYLE  mode=$([ "$DRY_RUN" -eq 1 ] && echo DRY-RUN || echo APPLY)"
  log " cloud root: $CLOUD_ROOT"
  log "============================================================="

  ensure_local_base
  log ""
  ensure_cloud_tree
  log ""
  log "Redirecting local user dirs -> cloud:"
  local line
  printf '%s\n' "$OFFLOAD_SET" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    redirect_one "$line"
  done
  log ""
  write_user_dirs
  print_mapping

  cat <<'EOF'

Notes
  * macOS ships bash 3.2; this script is 3.2-safe. Run it with /bin/bash.
  * Real data lives in the cloud root; local dirs are pointers. On macOS the
    cloud folder is inside "My Drive", so Google's client syncs it natively —
    the symlink is just a local convenience.
  * Config/state/cache deliberately stay local. Put dotfiles in git (chezmoi/
    yadm/bare repo) for merge semantics and host-conditional logic.
  * Re-run with --apply to act; add --relocate to migrate populated dirs.
EOF
}

main
