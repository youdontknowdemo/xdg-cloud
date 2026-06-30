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
#   3. Only XDG *user* dirs are auto-symlinked into the cloud here — the genuine
#      cross-OS portable set. (A projects area is CODE-class, not symlinked; it is
#      offloaded on demand in a later slice, not via this lane.)
#
# Compatible with stock macOS bash 3.2 (no associative arrays / mapfile).
#
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
xdg_init_base_defaults   # populate XDG_{CONFIG,DATA,STATE,CACHE}_HOME from env/defaults

# ---------------------------------------------------------------------------
# Config — override via environment.
# ---------------------------------------------------------------------------
# CLOUD_ROOT = the cloud-resident user-data home (the "~" inside your drive).
#   macOS: auto-detected as "~/Library/CloudStorage/GoogleDrive-*/My Drive" if unset,
#          falling back to iCloud Drive ("~/Library/Mobile Documents/com~apple~CloudDocs")
#          when no Google Drive mount is present.
#   Linux/Termux: you MUST set CLOUD_ROOT to wherever the drive is mounted
#                 (rclone mount, google-drive-ocamlfuse, insync, etc.).
: "${CLOUD_ROOT:=}"

# STYLE = naming convention for the cloud folders.
#   xdg = lowercase (documents, music, videos)   [modern/default]
#   mac = capitalized (Documents, Music, Movies)
: "${STYLE:=xdg}"

# Local XDG base dirs (stay LOCAL — listed so we can ensure + report them) are
# populated by xdg_init_base_defaults() from the shared lib, called above.

DRY_RUN=1          # 1 = print only; --apply to act
DO_RELOCATE=0      # move existing populated dirs into the cloud, then symlink
REDIRECT_DOWNLOADS=0  # downloads is triage/ephemeral; off by default
ALLOW_LOCAL_ROOT=0 # 1 = skip the cloud-mount liveness check (B4 override)
FAST_VERIFY=0      # 1 = size/mtime post-copy verify instead of checksum (B3)

# Mode dispatch (slice 1). Empty MODE = the default provision/symlink lane (main,
# unchanged). A non-empty MODE selects a subcommand handled by dispatch_mode at the
# very bottom of the file. Exactly one lane runs per invocation (set_mode enforces it).
MODE=""            # "" = provision lane (main). Else a subcommand mode.
MODE_ARG=""        # argument for value-taking modes (--offload <dir>, --hydrate <dir>)

# Code offload-on-demand (slice 2) — the rclone REMOTE lane (NOT the cloud mount;
# only a real remote frees local space). CODE-class dirs use this lane and NEVER
# enter OFFLOAD_SET / the symlink-into-mount lane.
: "${CODE_REMOTE:=gdrive}"            # rclone remote name (create via 'rclone config')
: "${CODE_DEST:=xdg-offload/code}"    # path inside the remote; per-container <canonical> appended
OFFLOAD_ASIDE=0                       # 1 = move aside + re-verify before rm (opt-in, --aside)

# Dotfiles bare-repo lane (slice 3, step 8) — purely LOCAL (no cloud mount/remote). A bare
# git repo at $HOME/.dotfiles with $HOME as the work tree, plus a sourced alias file and a
# guarded rc-source block. Fixed paths are literal; only DOTFILES_RC takes the env idiom.
DOTFILES_DIR="$HOME/.dotfiles"                            # the bare repo (work-tree = $HOME)
DOTFILES_ALIASES="$XDG_CONFIG_HOME/xdg-cloud/aliases.sh"  # dedicated sourced alias file
DOTFILES_SENTINEL="# >>> xdg-cloud dotfiles >>>"          # rc-block start marker (idempotency key)
DOTFILES_SENTINEL_END="# <<< xdg-cloud dotfiles <<<"      # rc-block end marker
: "${DOTFILES_RC:=}"                                      # explicit rc path (--dotfiles-rc); else $SHELL-derived
RC_TARGET=""                                              # resolved rc (set by dotfiles_resolve_rc)

# State for the single master cleanup trap (cleanup_handler). bash 3.2 allows only
# ONE handler per signal and has no trap-stacking, so the concurrency lock (#5c),
# the macOS TCC-probe revert (B2), and the mid-relocate recovery message (B3) must
# all be served by ONE handler driven by these flags — NOT by separate `trap`
# install/clear pairs that would clobber each other. relocate_dir toggles the
# PROBE_*/RELOCATE_* flags around its critical windows; main() owns the LOCK_* flags.
RELOCATE_ACTIVE=0
RELOCATE_SRC=""
RELOCATE_ASIDE=""
RELOCATE_DST=""

# Offload drop-window state (slice 2). Set ACTIVE around the local rm so an interrupt
# leaves a clear recovery message. Unlike relocate, the cloud copy is already
# read-back-verified AND (for git content) the remote is a second net, so recovery =
# re-run --offload (idempotent) or --hydrate. Straight-line drop in the PARENT shell,
# so the flag the handler reads is always in scope (no pipe/subshell — R2 ADR rule).
OFFLOAD_ACTIVE=0
OFFLOAD_SRC=""
OFFLOAD_REMOTE=""

# Projects un-symlink migration window (slice 2, cmd_migrate_projects). Non-destructive
# (rm NOTHING — the cloud copy and the moved-aside link are always retained), but it has
# a mv+rsync window, so it gets the same single-handler discipline as relocate: an
# interrupt between moving the symlink aside and finishing the local copy leaves a
# recoverable, clearly-reported state.
MIGRATE_ACTIVE=0
MIGRATE_SRC=""
MIGRATE_ASIDE=""
MIGRATE_CLOUD=""

# macOS TCC rename-probe state (B2): set ACTIVE before the rename so an interrupt in
# the sub-millisecond window is always reverted by the master handler.
PROBE_ACTIVE=0
PROBE_PATH=""
PROBE_SRC=""

# Concurrency lock state (#5c). LOCK_OWNED guards release so we never rmdir a lock
# we did not create (e.g. the die path when another run already holds it).
LOCK_DIR=""
LOCK_OWNED=0

# SELF is set by the shared lib (basename of the executed script — unchanged by sourcing).

# ---------------------------------------------------------------------------
# The offload set.  Format:  canonical|macName|linuxName|xdgVar|redirect
#   canonical : folder name created in the cloud root (style applied)
#   macName   : the dir under $HOME on macOS (Apple naming, e.g. Movies)
#   linuxName : the dir under $HOME on Linux (XDG default naming)
#   xdgVar    : the user-dirs.dirs variable to write (empty = none)
#   redirect  : 1 = eligible to symlink local->cloud, 0 = create only
#               (downloads is redirect=1 but EXCEPTIONALLY off by default — its
#               extra REDIRECT_DOWNLOADS gate in redirect_one keeps it create-only
#               until --redirect-downloads is passed. See should_redirect().)
# Derived from the canonical registry in the shared lib (xdg_offload_set emits the
# CLOUDXDG_KEYS rows in order — identical to the old literal, sans the blank lines
# every consumer already skips with `[ -z "$line" ] && continue`).
# ---------------------------------------------------------------------------
OFFLOAD_SET="$(xdg_offload_set)"

# ---------------------------------------------------------------------------
# Plumbing
#   log/info/warn/die come from the shared lib (bin/lib/xdg-common.sh).
#   run() STAYS here (per-script): cloud-xdg shell-quotes each arg with `printf %q`
#   — a tested contract (smoke M6) that home-tree's `%s` run() must NOT share.
# ---------------------------------------------------------------------------
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

# Single master cleanup handler — installed in the PARENT shell (see
# install_cleanup_trap, called from main()/begin_mutating_mode BEFORE the lock is
# acquired). It serves FIVE independent responsibilities, each gated on its own flag,
# so they never clobber one another the way separate `trap`/`trap -` pairs would
# under bash 3.2:
#   1. PROBE_ACTIVE  — revert an interrupted macOS TCC rename-probe (B2).
#   2. RELOCATE_ACTIVE — print the mid-relocate recovery message (B3): if the shell
#      exits between renaming the original aside and creating the replacement
#      symlink, the tree is in a recoverable-but-confusing half-state; show plainly
#      where the data is so the user never panics or deletes the wrong thing.
#   3. OFFLOAD_ACTIVE — print the mid-offload-drop recovery message (slice 2): the
#      cloud copy is already read-back-verified, so recovery = re-run --offload or
#      --hydrate; the local container may be partially removed.
#   4. MIGRATE_ACTIVE — print the mid-Projects-migration recovery message (slice 2):
#      the cloud copy is untouched and the original symlink is moved aside, so the
#      half-finished local copy is fully recoverable.
#   5. LOCK_OWNED — release the concurrency lock (#5c) on EVERY exit path (success,
#      die/error, INT/TERM) so a crash never strands a stale lock.
# All these windows are apply-mode-only (the probe/recovery code and the lock are
# only armed when DRY_RUN=0), so a dry-run Ctrl-C prints nothing spurious.
#
# CRITICAL (PR #11 remediation): the flags this reads are raised inside relocate_dir,
# which MUST run in the same shell as this handler. main()'s redirect loop is fed by
# a here-doc (NOT a `... | while`) precisely so relocate_dir runs in the PARENT shell
# — a pipe would run it in a subshell whose flag writes never reach here (and whose
# traps are reset to default), silently disabling probe-revert + recovery on signal.
#
# IDEMPOTENT: each branch resets its own flag after acting, so the EXIT trap firing
# again right after on_signal's `exit 130` is a harmless no-op (no double-print, no
# double-revert).
cleanup_handler() {
  if [ "${PROBE_ACTIVE:-0}" -eq 1 ]; then
    mv "$PROBE_PATH" "$PROBE_SRC" 2>/dev/null || true
    PROBE_ACTIVE=0
  fi
  if [ "${RELOCATE_ACTIVE:-0}" -eq 1 ]; then
    warn "INTERRUPTED mid-relocate — your data is SAFE, here is the state:"
    warn "  original:  moved to '$RELOCATE_ASIDE' if the rename finished, else still at '$RELOCATE_SRC'"
    warn "  cloud copy: '$RELOCATE_DST'"
    warn "  the symlink '$RELOCATE_SRC' may not exist yet. Re-run to finish. Delete NOTHING until verified."
    RELOCATE_ACTIVE=0
  fi
  if [ "${OFFLOAD_ACTIVE:-0}" -eq 1 ]; then
    warn "INTERRUPTED mid-offload-drop — your data is SAFE:"
    warn "  cloud copy (read-back-verified): '$OFFLOAD_REMOTE'"
    warn "  local '$OFFLOAD_SRC' may be partially removed. Re-run --offload to finish,"
    warn "  or --hydrate to restore it. Delete NOTHING by hand until verified."
    OFFLOAD_ACTIVE=0
  fi
  if [ "${MIGRATE_ACTIVE:-0}" -eq 1 ]; then
    warn "INTERRUPTED mid-Projects-migration — your data is SAFE:"
    warn "  cloud copy (untouched): '$MIGRATE_CLOUD'"
    warn "  original symlink moved aside to '$MIGRATE_ASIDE' (restore it to undo)."
    warn "  local '$MIGRATE_SRC' may be a partial copy. Re-run --migrate-projects to finish."
    warn "  Delete NOTHING by hand until verified."
    MIGRATE_ACTIVE=0
  fi
  if [ "${LOCK_OWNED:-0}" -eq 1 ] && [ -n "${LOCK_DIR:-}" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_OWNED=0
  fi
}

# Signal handler (PR #11 remediation, B2): a bare trap handler does NOT terminate the
# script — bash runs it and then RESUMES the interrupted code, which would finish the
# mv+ln unprotected, print a false "data SAFE" line, and exit 0 on a Ctrl-C. So on
# INT/TERM we run the cleanup actions and then EXIT non-zero (130 = 128+SIGINT). The
# EXIT trap fires once more on the way out, but cleanup_handler is idempotent so that
# second pass is a no-op.
on_signal() {
  cleanup_handler
  exit 130
}

# Arm EXIT (normal/error path) and INT/TERM (signal path) with their distinct
# handlers. Installed early in main(), before acquire_lock, so a signal in the
# acquire->arm gap can't strand the lock; the handlers are flag/LOCK_OWNED-gated, so
# arming before any work is a safe no-op.
install_cleanup_trap() {
  trap cleanup_handler EXIT
  trap on_signal INT TERM
}

# #5a: refuse to run as root. This tool creates dirs and symlinks under the
# invoking user's $HOME; as root those entries would be root-owned (and, via sudo,
# $HOME may not even be the intended user's), leaving a home the user can't manage.
# Cheapest possible refusal — called first in main(), before any filesystem work.
guard_not_root() {
  if [ "$(id -u)" = "0" ]; then
    die "refuse to run as root — it would create root-owned entries in your home. Run as your normal user."
  fi
}

# #5c: atomic concurrency lock. Two simultaneous runs against the same home could
# race on the same dirs/symlinks (and on the relocate mv->ln window). Stock macOS
# bash 3.2 has no flock, so we use `mkdir` as the atomic primitive: it succeeds for
# exactly one racer and fails for the rest. Apply-mode only (a dry-run mutates
# nothing, so it needs no lock). The lock is released by the master cleanup_handler
# (LOCK_OWNED-gated) on every exit path. Keyed per-home under $XDG_CACHE_HOME.
acquire_lock() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  LOCK_DIR="$XDG_CACHE_HOME/cloud-xdg-provision.lock"
  # The atomic `mkdir "$LOCK_DIR"` needs its parent to exist; ensure_local_base
  # creates $XDG_CACHE_HOME later, so make it here first (idempotent, -p). M-d: guard
  # it so an unwritable/unset cache yields an accurate message, not a raw `set -e` abort.
  mkdir -p "$XDG_CACHE_HOME" 2>/dev/null || die "cannot create cache dir for the lock: $XDG_CACHE_HOME
  Check that it (or its parent) is writable, or set XDG_CACHE_HOME to a writable path."
  # M-d: a failed `mkdir "$LOCK_DIR"` has TWO distinct causes — don't conflate them.
  # If the lock dir already EXISTS, another run genuinely holds it. If mkdir failed for
  # any OTHER reason (e.g. $XDG_CACHE_HOME exists but is unwritable), say so accurately.
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_OWNED=1
  elif [ -d "$LOCK_DIR" ]; then
    die "another run is in progress (lock: $LOCK_DIR).
  If no other run is active, the lock is stale — remove it and retry: rmdir '$LOCK_DIR'"
  else
    die "cannot create lock dir under $XDG_CACHE_HOME — check that the directory is writable: $LOCK_DIR"
  fi
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

Modes (default with no mode flag = the provision/symlink lane above; exactly one
lane per run — combining a mode with the default flags is refused):
  --classify             Report the class of every known ~/ entry (read-only).
  --offload-status       Report which code dirs are offloaded vs local (read-only).
  --offload <dir>        Push a CODE dir to the rclone remote, verify, then free local
                         space (dry-run unless --apply). git = source of truth.
  --hydrate <dir>        Restore a previously offloaded CODE dir from the remote.
  --migrate-projects     Restore a previously cloud-symlinked ~/Projects to a real
                         local dir (non-destructive; dry-run unless --apply).
  --code-remote NAME     rclone remote for offload (default: gdrive).
  --code-dest PATH       Path inside the remote (default: xdg-offload/code).
  --aside                Offload: move local aside + re-verify before rm (extra safety).
  --dotfiles-init        Create a bare ~/.dotfiles repo + install the 'dotfiles' alias
                         (dry-run unless --apply). Idempotent; backs up your rc first.
  --dotfiles-track <p>   Track a dotfile/dir into the bare repo (refuses cloud-xdg-managed
                         paths). --apply to commit.
  --dotfiles-status      Show tracked-file status + whether the alias/rc block are installed.
  --dotfiles-rc PATH     Shell rc to edit (default: ~/.zshrc for zsh, ~/.bashrc for bash).
                         macOS bash login shells usually want --dotfiles-rc ~/.bash_profile.

Nothing is moved without --apply --relocate together.
EOF
}

# Select a subcommand mode; refuse two lanes in one invocation.
set_mode() {
  [ -z "$MODE" ] || die "choose ONE mode per run (already set: --$MODE, then --$1)."
  MODE="$1"
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
    --code-remote)        shift; CODE_REMOTE="${1:?--code-remote needs a name}" ;;
    --code-dest)          shift; CODE_DEST="${1:?--code-dest needs a path}" ;;
    --aside)              OFFLOAD_ASIDE=1 ;;
    --dotfiles-rc)        shift; DOTFILES_RC="${1:?--dotfiles-rc needs a path}" ;;
    # --- read-only report modes (slice 1, implemented) ---
    --classify)           set_mode classify ;;
    --offload-status)     set_mode offload-status ;;
    # --- mutating lanes (live: offload round-trip + Projects migration + dotfiles) ---
    --migrate-projects)   set_mode migrate-projects ;;
    --offload)            set_mode offload;  shift; MODE_ARG="${1:?--offload needs a dir}" ;;
    --hydrate)            set_mode hydrate;  shift; MODE_ARG="${1:?--hydrate needs a dir}" ;;
    --dotfiles-init)      set_mode dotfiles-init ;;
    --dotfiles-track)     set_mode dotfiles-track; shift; MODE_ARG="${1:?--dotfiles-track needs a path}" ;;
    --dotfiles-status)    set_mode dotfiles-status ;;
    -h|--help)            usage; exit 0 ;;
    *)                    die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

case "$STYLE" in xdg|mac) ;; *) die "invalid --style: $STYLE" ;; esac

# ---------------------------------------------------------------------------
# Platform + cloud root resolution
# ---------------------------------------------------------------------------
# detect_platform (shared lib) sets the global PLATFORM. Called here — top level,
# after arg parsing, before main — the same point the old inline case ran, so
# PLATFORM holds the identical value at every use site.
detect_platform

resolve_cloud_root() {
  if [ -n "$CLOUD_ROOT" ]; then return 0; fi
  if [ "$PLATFORM" = "macos" ]; then
    # Issue #4: with several Google accounts mounted there are multiple
    # ~/Library/CloudStorage/GoogleDrive-* dirs. The old code took the FIRST match
    # silently — so the wrong account could be chosen with no warning. Collect ALL
    # candidates (dirs that actually contain "My Drive"); use the one only if it is
    # unambiguous, otherwise refuse and make the user disambiguate with --cloud-root.
    # bash 3.2: count via a loop + accumulate a newline-listed string (no arrays).
    local d count first candidates gd_dir_seen
    count=0; first=""; candidates=""; gd_dir_seen=0
    for d in "$HOME"/Library/CloudStorage/GoogleDrive-*; do
      # An unmatched glob stays literal (no nullglob in bash 3.2), so [ -d "$d" ]
      # is false when nothing matched. A real GoogleDrive-* dir WITHOUT a "My Drive"
      # inside is a half-set-up Drive: note it so the iCloud fallback below can warn.
      [ -d "$d" ] && gd_dir_seen=1
      [ -d "$d/My Drive" ] || continue          # also skips the literal glob when nothing matches
      count=$((count + 1))
      if [ -z "$first" ]; then first="$d/My Drive"; fi
      candidates="${candidates}    $d/My Drive
"
    done
    if [ "$count" -gt 1 ]; then
      die "Multiple Google Drive mounts found — refusing to guess which one you mean:
${candidates}  Pass --cloud-root PATH to choose one explicitly."
    fi
    if [ "$count" -eq 0 ]; then
      # Issue #20: no Google Drive mount — fall back to iCloud Drive. This is a
      # FALLBACK only; whenever a Google Drive mount exists (count>=1 above) it
      # wins and we never reach here, so behaviour with GD present is unchanged.
      # The literal below MUST match the iCloud prefix that cloud_root_is_live()
      # recognises at the B4 liveness check ("$HOME"/Library/Mobile Documents/*),
      # so an auto-detected iCloud root passes B4 without --allow-local-root.
      local icloud_root="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
      if [ -d "$icloud_root" ]; then
        # A GoogleDrive-* folder exists but has no "My Drive" inside (half-set-up
        # Drive). Pre-#20 this case died; now it silently fell to iCloud. Make the
        # fallback visible so the user isn't surprised by the chosen root.
        if [ "$gd_dir_seen" -eq 1 ]; then
          warn "Found a Google Drive folder but no 'My Drive' inside; falling back to iCloud Drive. Pass --cloud-root to override."
        fi
        CLOUD_ROOT="$icloud_root"
        return 0
      fi
      die "No Google Drive or iCloud Drive found. Pass --cloud-root PATH."
    fi
    CLOUD_ROOT="$first"
    return 0
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

# local home dir name for current platform.  $1 = the Apple/macOS name, $2 = the
# Linux/XDG name.  (Issue #7: the canonical name is not needed here — local naming
# only ever differs between macOS and Linux — so it is no longer a parameter.)
local_name() {
  if [ "$PLATFORM" = "macos" ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# Issue #6 / M-h: single source of truth for the POLICY question "SHOULD this
# OFFLOAD_SET entry be redirected (symlinked into the cloud) per config?" — it is a
# policy predicate, NOT a filesystem-state query (redirect_one separately inspects
# the actual on-disk symlink). Used by BOTH redirect_one (the symlink layer) and
# write_user_dirs (the user-dirs.dirs layer) so the two can never disagree about
# whether a dir lives in the cloud. Args: $1 = canonical name, $2 = the redirect
# field. Returns 0 = should be redirected, 1 = not. downloads is the sole exception:
# even with redirect=1 it stays create-only until --redirect-downloads
# (REDIRECT_DOWNLOADS=1).
should_redirect() {
  [ "$2" = "1" ] || return 1
  if [ "$1" = "downloads" ] && [ "$REDIRECT_DOWNLOADS" -ne 1 ]; then return 1; fi
  return 0
}

# ---------------------------------------------------------------------------
# Steps
#   field() (the '|'-row splitter) comes from the shared lib.
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

  # Symlink layer gate (shared with write_user_dirs via should_redirect). downloads is
  # the only entry that can be eligible (redirect=1) yet not redirected by default —
  # surface that with the actionable info line; any genuine create-only entry just
  # returns silently.
  if ! should_redirect "$canon" "$wantredir"; then
    [ "$canon" = "downloads" ] && info "skip redirect: downloads (use --redirect-downloads to enable)"
    return 0
  fi

  cn="$(cloud_name "$canon" "$mac")"
  ln="$(local_name "$mac" "$lin")"
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

# M-g: does the `ls -lde` listing ($1) carry a deny-delete ACE? Match `deny` AND
# `delete` on the SAME line, so a compound/re-ordered ACE (e.g. 'deny write,delete'
# or 'deny delete,write') is still caught — a single "deny delete" substring would
# assume that exact token ordering and miss those. Anchoring both tokens to one line
# also avoids a cross-line false positive (a stray 'deny' on one ACE + 'delete' on
# another).
#
# bash 3.2 NOTE: the listing is fed to the loop via a here-doc (`done <<EOF`), NOT
# `printf … | while`, and the nested `case` is therefore NOT inside a `$( … )`. Stock
# bash 3.2's command-substitution parser miscounts a case-pattern `)` as the closing
# paren of `$(`, so a `case` inside `$( … )` fails to parse AT RUNTIME (and `bash -n`
# does NOT catch it). The here-doc form keeps the loop in this function's own shell so
# `return` works directly and the 3.2 quirk is avoided entirely. Do NOT refactor this
# into a `$(printf | while … case … )`.
#
# FAIL-SAFE: even if this ever misses, the B2 rename-probe below still blocks the
# relocate (a deny-delete ACL fails the probe `mv`) — so a miss degrades to the
# less-specific TCC message, never to a false relocate.
acl_denies_delete() {
  local __aclline
  while IFS= read -r __aclline; do
    case "$__aclline" in
      *deny*) case "$__aclline" in *delete*) return 0 ;; esac ;;
    esac
  done <<EOF
$1
EOF
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
  # ACL on macOS; we capture it and parse it (no `ls | grep`) for the deny ACE via
  # acl_denies_delete (deny+delete on the same ACE line — see its comment).
  if [ "$PLATFORM" = "macos" ]; then
    acl_listing="$(ls -lde "$src" 2>/dev/null || true)"
    if acl_denies_delete "$acl_listing"; then
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
      return 0
    fi
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
  # is a faithful TCC test. The rename is immediately reverted, AND the master
  # cleanup_handler (already installed by main()) guarantees the revert if the
  # process is killed at ANY point during the probe: we set PROBE_ACTIVE=1 BEFORE
  # the first rename so even the sub-millisecond window can't strand the dir (the
  # revert is a harmless no-op if the rename never happened). macOS only; dry-run
  # never touches anything.
  if [ "$DRY_RUN" -eq 0 ] && [ "$PLATFORM" = "macos" ]; then
    probe="${src}.tcc-probe.$$"
    PROBE_SRC="$src"; PROBE_PATH="$probe"; PROBE_ACTIVE=1
    if ! mv "$src" "$probe" 2>/dev/null; then
      PROBE_ACTIVE=0
      warn "cannot rename $src — macOS is blocking the rename (not the deny-delete ACL)."
      warn "  If your terminal lacks Full Disk Access, grant it: System Settings >"
      warn "  Privacy & Security > Full Disk Access → add your terminal, then retry."
      warn "  Skipping this dir — nothing copied."
      return 0
    fi
    mv "$probe" "$src"
    PROBE_ACTIVE=0
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
  # (set -e abort, SIGINT, crash), the master cleanup_handler prints plainly where
  # everything is. Armed only in apply mode by raising RELOCATE_ACTIVE — in dry-run
  # the run-lines are no-op prints, so a Ctrl-C there must not print a spurious
  # "INTERRUPTED mid-relocate" message (the handler stays silent while the flag is 0).
  if [ "$DRY_RUN" -eq 0 ]; then
    RELOCATE_ACTIVE=1; RELOCATE_SRC="$src"; RELOCATE_ASIDE="$aside"; RELOCATE_DST="$dst"
  fi
  run mv "$src" "$aside"
  run ln -s "$dst" "$src"
  # Window closed: lower the flag so the master handler no longer treats a later
  # exit as mid-relocate. The trap itself stays installed (it still owns the lock).
  if [ "$DRY_RUN" -eq 0 ]; then RELOCATE_ACTIVE=0; fi

  info "Original kept at: $aside"
  info "The script CANNOT confirm the cloud upload is durable — providers upload"
  info "asynchronously. Treat '$aside' as your safety copy and delete it ONLY after"
  info "you've independently confirmed the provider shows every file."
}

write_user_dirs() {
  [ "$PLATFORM" = "macos" ] && { info "macOS: user-dirs.dirs not used (symlinks handle it)."; return 0; }
  local f="$XDG_CONFIG_HOME/user-dirs.dirs" bak stamp n
  log "Writing XDG user-dirs: $f"
  if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] would write $f"; return 0; fi
  mkdir -p "$XDG_CONFIG_HOME"
  # #5b: never overwrite an existing user-dirs.dirs without a backup — the user may
  # have hand-tuned it. Copy it aside to a timestamped .bak first. A counter keeps
  # the name unique if two runs land in the same second (second-resolution stamp).
  if [ -e "$f" ]; then
    stamp="$(date +%Y%m%d-%H%M%S)"
    bak="${f}.bak-${stamp}"
    n=1
    # M-e: test -e OR -L (matching relocate_dir's aside loop) so a DANGLING symlink
    # at the backup path is detected — `[ -e ]` alone reports a dangling link as
    # missing, so `cp` would then follow/clobber it. Advance the uniquifier instead.
    while [ -e "$bak" ] || [ -L "$bak" ]; do bak="${f}.bak-${stamp}.${n}"; n=$((n + 1)); done
    cp "$f" "$bak"
    info "Backed up existing user-dirs.dirs -> $bak"
  fi
  {
    printf '# Generated by %s — points XDG user dirs at the cloud ontology.\n' "$SELF"
    local line canon xdgvar cn
    printf '%s\n' "$OFFLOAD_SET" | while IFS= read -r line; do
      [ -z "$line" ] && continue
      xdgvar="$(field "$line" 4)"; [ -z "$xdgvar" ] && continue
      # Issue #6: only point an XDG var at the cloud for a dir that is GENUINELY
      # redirected by the symlink layer — otherwise user-dirs.dirs would claim a dir
      # lives in the cloud while ~/<dir> is still a plain local dir. Same should_redirect
      # gate redirect_one uses, so the two layers always agree (notably: downloads is
      # left at its local default unless --redirect-downloads is passed).
      should_redirect "$(field "$line" 1)" "$(field "$line" 5)" || continue
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
  downloads XDG_DOWNLOAD_DIR  ~/Downloads          -> local by default (triage); --redirect-downloads to offload
  music     XDG_MUSIC_DIR     ~/Music              -> $CLOUD_ROOT/$(cloud_name music Music)
  pictures  XDG_PICTURES_DIR  ~/Pictures           -> $CLOUD_ROOT/$(cloud_name pictures Pictures)
  videos    XDG_VIDEOS_DIR    ~/Movies (mac)       -> $CLOUD_ROOT/$(cloud_name videos Movies)
  public    XDG_PUBLICSHARE   ~/Public             -> $CLOUD_ROOT/$(cloud_name public Public)
  templates XDG_TEMPLATES_DIR ~/Templates          -> $CLOUD_ROOT/$(cloud_name templates Templates)

System root dirs (/ /usr /etc /var /opt /Applications /System /Library):
  machine-managed — NOT offloadable. Excluded by design.
EOF
}

# ---------------------------------------------------------------------------
# Read-only report modes (slice 1) — ZERO mutation: no mkdir/ln/rm, no run(),
# no cloud-root resolution, no lock. They only inspect and print.
# ---------------------------------------------------------------------------

# Print one classification line for a canonical's registry-style row.
#   $1 = class label (xdg|code|local), $2 = a 'canonical|mac|lin|…' row.
# Inspects $HOME/<localName> and reports symlink target / local dir / absent.
classify_one() {
  local class row mac lin name target state
  class="$1"; row="$2"
  [ -n "$row" ] || return 0                 # unknown key — nothing to print
  mac="$(field "$row" 2)"
  lin="$(field "$row" 3)"
  name="$(local_name "$mac" "$lin")"
  target="$HOME/$name"
  if [ -L "$target" ]; then
    state="symlink -> $(readlink "$target")"   # readlink (no -f) on a known symlink
  elif [ -d "$target" ]; then
    state="local dir"
  else
    state="absent"
  fi
  printf '%-6s %-22s %s\n' "$class" "$name" "$state"
  # A code dir that is currently a cloud symlink is the P2 case the (reserved)
  # --migrate-projects mode will later restore to a real local dir.
  if [ "$class" = "code" ] && [ -L "$target" ]; then
    printf '%-6s %-22s %s\n' "" "" "(cloud-symlinked; restore to a local dir with --migrate-projects)"
  fi
}

# --classify: classify every known top-level ~/ entry. Read-only.
cmd_classify() {
  local k
  log "Home-dir classification (read-only — no changes made):"
  # shellcheck disable=SC2086   # intentional word-split of the space-separated key lists
  for k in $CLOUDXDG_KEYS; do classify_one xdg   "$(registry_row "$k")"; done
  # shellcheck disable=SC2086
  for k in $CODE_KEYS;     do classify_one code  "$(code_row "$k")"; done
  # shellcheck disable=SC2086
  for k in $LOCAL_KEYS;    do classify_one local "$(code_row "$k")"; done
  cat <<'EOF'

Notes:
  * Dotfiles (~/.config, ~/.local, ~/.cache, …) are handled by the reserved
    dotfiles mode; they are deliberately not classified here.
  * Entries under ~/ not listed above are unclassified.
EOF
}

# --offload-status: for each code dir, report offloaded-vs-local. Read-only.
#   The offload lane (later slice) WRITES state files under
#   $XDG_STATE_HOME/xdg-cloud/offloaded/<canonical>; slice 1 only READS them, so
#   with no such file every code dir reports `local` (validating the read path).
cmd_offload_status() {
  local k state_dir name target sf remote gitout githint
  state_dir="$XDG_STATE_HOME/xdg-cloud/offloaded"
  log "Code-dir offload status (read-only — no changes made):"
  # shellcheck disable=SC2086   # intentional word-split of the space-separated key list
  for k in $CODE_KEYS; do
    name="$(local_name "$(field "$(code_row "$k")" 2)" "$(field "$(code_row "$k")" 3)")"
    target="$HOME/$name"
    sf="$state_dir/$k"
    if [ -f "$sf" ]; then
      # state file present -> offloaded. Parse the remote line (same 3.2 idiom as
      # elsewhere); tolerate a malformed/empty file.
      remote="$(grep '^remote=' "$sf" 2>/dev/null | cut -d= -f2- || true)"
      printf '%-6s %-22s %s\n' "code" "$name" "offloaded -> ${remote:-<unknown remote>}"
    else
      # local: add a read-only git cleanliness hint when it's a git work tree.
      githint=""
      if [ -d "$target" ] && git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        gitout="$(git -C "$target" status --porcelain 2>/dev/null || true)"
        if [ -n "$gitout" ]; then githint=" (git: dirty)"; else githint=" (git: clean)"; fi
      elif [ ! -e "$target" ]; then
        githint=" (absent)"
      fi
      printf '%-6s %-22s %s\n' "code" "$name" "local${githint}"
    fi
  done
}

# ---------------------------------------------------------------------------
# Offload-on-demand (slice 2) — the rclone REMOTE lane. Push a CODE container to a
# remote, read-back-verify it, then free local space. git is the source of truth, so
# the local drop is gated on per-repo git guards + an INDEPENDENT read-back. CRITICAL
# data-loss surface: the rm is reachable ONLY after every guard AND the read-back pass.
# ---------------------------------------------------------------------------

# Arm the shared safety machinery for a mutating subcommand mode (offload/hydrate/
# migrate). guard_not_root always; trap before lock (PR#11 order); acquire_lock is
# apply-only (dry-run no-op), so dry-run previews need no lock.
begin_mutating_mode() { guard_not_root; install_cleanup_trap; acquire_lock; }

# Resolve MODE_ARG (a canonical CODE key OR its platform local name) to (canonical,
# container path). REFUSE anything not CODE-class — the venv/machine-local data-loss
# guard: offloading a venv or an abs-path dir would re-hydrate broken.
resolve_code_target() {        # sets caller-scoped: canonical, container
  local arg="$1" k nm
  canonical=""; container=""
  # shellcheck disable=SC2086   # intentional word-split of the space-separated key list
  for k in $CODE_KEYS; do
    nm="$(local_name "$(field "$(code_row "$k")" 2)" "$(field "$(code_row "$k")" 3)")"
    if [ "$arg" = "$k" ] || [ "$arg" = "$nm" ]; then canonical="$k"; container="$HOME/$nm"; return 0; fi
  done
  is_machine_local "$arg" && die "$arg is machine-local (never offloads — venvs/abs-paths break)."
  die "$arg is not a known CODE dir (offload-eligible: $CODE_KEYS). Refusing."
}

# cloud-xdg's rclone precondition. Wraps the lib's parameterized rclone_remote_exists()
# with cloud-xdg's CODE_REMOTE + its own message (home-tree keeps its own require_rclone;
# do NOT byte-copy — message + config var diverge, per the dedup rule).
require_code_rclone() {
  rclone_remote_exists "$CODE_REMOTE" && return 0
  die "rclone remote '$CODE_REMOTE:' not available. Install rclone + 'rclone config' to create
  it, or pass --code-remote NAME. Code offload uses an rclone REMOTE (only a remote frees space)."
}

# Echo the git work tree(s) for a CODE container. If the container is itself a git repo,
# it is the sole unit; else its immediate subdirs (depth 1) that are git work trees.
# bash 3.2: an unmatched glob stays literal, guarded by [ -d ].
offload_repos_in() {
  local base="$1" d
  if git -C "$base" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s\n' "$base"; return 0
  fi
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 && printf '%s\n' "$d"
  done
}

# G2: clean working tree (no staged/unstaged/untracked).
g2_clean()    { [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ]; }
# G4: no stashes (a clean tree can still hide them; stashes are never pushed).
g4_no_stash() { [ -z "$(git -C "$1" stash list 2>/dev/null)" ]; }

# G3: emit a human line per branch that BLOCKS offload (no upstream, or ahead of it).
# Empty output => every local branch is fully pushed. bash 3.2: for-each-ref + while read;
# @{u} resolved with an rc check so a missing upstream is a REFUSAL line, never a set -e
# abort. Pipe->subshell is fine here (read-only; we consume the echoed lines, not a flag).
g3_unpushed() {
  local d="$1" up n
  git -C "$d" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null \
  | while IFS= read -r b; do
      up="$(git -C "$d" rev-parse --abbrev-ref "${b}@{u}" 2>/dev/null || true)"
      if [ -z "$up" ]; then printf '    branch %s has no upstream\n' "$b"; continue; fi
      n="$(git -C "$d" rev-list --count "${b}@{u}..${b}" 2>/dev/null || printf '?')"
      [ "$n" = "0" ] || printf '    branch %s is ahead of %s by %s commit(s)\n' "$b" "$up" "$n"
    done
}

# Aggregate G2/G3/G4 for one repo. Echo blocker lines; empty => safe (after G5 verify).
# (G1 is implied: offload_repos_in only yields git work trees.)
repo_offload_blockers() {
  local d="$1" out=""
  g2_clean    "$d" || out="${out}    uncommitted or untracked changes (git status not clean)
"
  out="${out}$(g3_unpushed "$d")"
  g4_no_stash "$d" || out="${out}
    stashes present (git stash list non-empty)"
  printf '%s' "$out"
}

# Warn if the container holds content outside any discovered git repo — that content has
# only the (verified) cloud copy as a net, no git fallback. Recommend --aside.
warn_loose_content() {
  local base="$1" e
  git -C "$base" rev-parse --is-inside-work-tree >/dev/null 2>&1 && return 0  # whole dir is one repo
  for e in "$base"/* "$base"/.[!.]*; do
    [ -e "$e" ] || continue
    if [ -d "$e" ] && git -C "$e" rev-parse --is-inside-work-tree >/dev/null 2>&1; then continue; fi
    warn "$base holds content outside any git repo — only the (verified) cloud copy"
    warn "  will back it up. Consider --aside for a local safety copy first."
    return 0
  done
}

# Detect large regenerable build dirs in the push (v1 copies them faithfully — an rclone
# exclude-filter is DEFERRED to v2). Warn loudly so the user understands the upload SIZE.
warn_regenerable() {
  local base="$1" hit
  hit="$(find "$base" \( -name node_modules -o -name .gradle -o -name build -o -name __pycache__ \) \
          -type d -prune -print 2>/dev/null | head -n 20)"
  [ -z "$hit" ] && return 0
  warn "large regenerable dirs are INCLUDED in this push (v1 copies them faithfully — no filter yet):"
  printf '%s\n' "$hit" | sed 's/^/    /' >&2
  warn "  This inflates upload size/quota, but offload STILL frees the local space. A v2 rclone"
  warn "  exclude-filter will skip these. Use --aside if you want a local safety copy first."
}

# Write the per-container offload record. key=value lines (parseable via grep+cut — matches
# cmd_offload_status's `remote=` reader). Built with printf, NO backticks anywhere (team
# footgun: backticks inside a quoted/heredoc string can execute at parse time).
write_offload_state() {
  local key="$1" remote="$2" src="$3" sf stamp
  sf="$XDG_STATE_HOME/xdg-cloud/offloaded/$key"
  stamp="$(date +%Y-%m-%dT%H:%M:%S)"
  mkdir -p "$XDG_STATE_HOME/xdg-cloud/offloaded"
  { printf 'remote=%s\n' "$remote"
    printf 'source=%s\n' "$src"
    printf 'offloaded_at=%s\n' "$stamp"; } > "$sf"
}

# --offload <dir>: push a CODE container to the remote, read-back-verify, then free local.
cmd_offload() {                # $1 = MODE_ARG (canonical or local name)
  begin_mutating_mode
  local canonical container dest repos repo b any_block blockers
  resolve_code_target "$1"     # sets canonical, container (refuses non-CODE)
  require_code_rclone
  [ -d "$container" ] || die "$container does not exist (nothing to offload)."
  dest="$CODE_REMOTE:$CODE_DEST/$canonical"

  warn_regenerable "$container"
  warn_loose_content "$container"

  repos="$(offload_repos_in "$container")"
  [ -n "$repos" ] || warn "no git repos found under $container — only the verified cloud copy backs it up."

  # Per-repo fail-closed guard scan. Collect blockers; name them (here-doc, parent shell).
  any_block=0; blockers=""
  while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    b="$(repo_offload_blockers "$repo")"
    [ -n "$b" ] && { any_block=1; blockers="${blockers}  BLOCK: ${repo}
${b}
"; }
  done <<EOF
$repos
EOF

  if [ "$DRY_RUN" -eq 1 ]; then
    log "Offload plan for $container -> $dest (dry-run — touches nothing):"
    while IFS= read -r repo; do
      [ -z "$repo" ] && continue
      b="$(repo_offload_blockers "$repo")"
      if [ -n "$b" ]; then printf '  WOULD BLOCK: %s\n%s\n' "$repo" "$b"
      else printf '  would offload: %s\n' "$repo"; fi
    done <<EOF
$repos
EOF
    if [ "$any_block" -eq 1 ]; then
      warn "one or more repos block offload (commit/push/clear stashes), then re-run."
    else
      info "would rclone copy $container -> $dest"
      info "would free local $container (re-run with --apply to act)"
    fi
    return 0
  fi

  # --- apply mode (mutating) ---
  [ "$any_block" -eq 0 ] || die "refusing to offload $container — blocking repos:
${blockers}Fix them (commit/push/clear stashes), then re-run."

  run rclone copy --immutable "$container" "$dest" --progress
  # G5 GATE: an INDEPENDENT read-back (not the copy rc) proves DURABLE upload before any rm.
  rclone check --download --one-way "$container" "$dest" \
    || die "post-copy read-back verify FAILED for $container -> $dest. Nothing dropped. Retry."
  write_offload_state "$canonical" "$dest" "$container"

  # DATA-LOSS GUARD (SC2115): never rm a degenerate path.
  case "$container" in
    ""|"/"|"$HOME") die "internal: refusing rm of unsafe path '$container'" ;;
  esac
  [ -n "$(ls -A "$container" 2>/dev/null)" ] || { warn "$container already empty; nothing to drop."; return 0; }

  # The drop window: straight-line in the PARENT shell so OFFLOAD_ACTIVE reaches the
  # master cleanup_handler (no pipe/subshell — R2 ADR rule).
  OFFLOAD_ACTIVE=1; OFFLOAD_SRC="$container"; OFFLOAD_REMOTE="$dest"
  if [ "$OFFLOAD_ASIDE" -eq 1 ]; then
    local stamp aside n
    stamp="$(date +%Y%m%d-%H%M%S)"; aside="${container}.pre-offload-${stamp}"
    n=1; while [ -e "$aside" ] || [ -L "$aside" ]; do aside="${container}.pre-offload-${stamp}.${n}"; n=$((n + 1)); done
    mv "$container" "$aside"
    rclone check --download --one-way "$aside" "$dest" \
      || die "re-verify of aside vs remote FAILED — kept '$aside', dropped nothing else."
    rm -rf "$aside"
  else
    rm -rf "$container"
  fi
  OFFLOAD_ACTIVE=0
  info "Offloaded $container -> $dest. Restore with: $SELF --hydrate $canonical --apply"
}

# --hydrate <dir>: restore a previously offloaded CODE container from the remote.
cmd_hydrate() {                # $1 = MODE_ARG (canonical or local name)
  begin_mutating_mode
  local canonical container sf sentinel remote
  resolve_code_target "$1"     # refuses non-CODE
  require_code_rclone
  sf="$XDG_STATE_HOME/xdg-cloud/offloaded/$canonical"
  [ -f "$sf" ] || die "$container is not recorded as offloaded (no $sf)."
  sentinel="$sf.hydrating"
  [ -f "$sentinel" ] && warn "a previous hydrate of $canonical was interrupted; re-running."
  remote="$(grep '^remote=' "$sf" 2>/dev/null | cut -d= -f2- || true)"
  [ -n "$remote" ] || die "state file $sf has no remote= line; refusing."
  # refuse to clobber an existing non-empty local dir:
  if [ -e "$container" ] && [ -n "$(ls -A "$container" 2>/dev/null)" ]; then
    die "$container exists and is non-empty; refusing to overwrite. Move it aside first."
  fi
  [ "$DRY_RUN" -eq 0 ] || { info "[dry-run] would hydrate $container from $remote"; return 0; }
  : > "$sentinel"                                   # mark BEFORE pull (self-detect a crash)
  run rclone copy --checksum "$remote" "$container" --progress
  rclone check --download --one-way "$remote" "$container" \
    || die "post-pull verify FAILED — left sentinel '$sentinel'; re-run --hydrate."
  rm -f "$sentinel"; rm -f "$sf"                    # clear ONLY on verified success
  info "Hydrated $container from $remote."
  info "Alt for fully-pushed repos: 'git clone <remote-url>' is the canonical, self-verifying restore."
}

# --migrate-projects: restore a previously cloud-symlinked ~/Projects to a real local
# dir (slice-1 §3 algorithm). NON-DESTRUCTIVE: the cloud copy and the moved-aside symlink
# are ALWAYS retained — this command removes NOTHING. Dry-run default; --apply to act.
cmd_migrate_projects() {
  begin_mutating_mode
  resolve_cloud_root
  normalize_cloud_root
  local localpath target copier stamp aside n
  localpath="$HOME/Projects"   # local_name(Projects,Projects) = Projects on both OSes
  # (a) absent
  if [ ! -e "$localpath" ] && [ ! -L "$localpath" ]; then
    info "no $localpath to migrate."; return 0
  fi
  # (b) already a real local dir
  if [ -d "$localpath" ] && [ ! -L "$localpath" ]; then
    info "$localpath is already a local dir."; return 0
  fi
  # (c) a symlink — the P2 case
  if [ -L "$localpath" ]; then
    target="$(readlink "$localpath")"
    if [ ! -d "$target" ]; then
      warn "$localpath -> '$target' is dangling; leaving it untouched."; return 0
    fi
    case "$target" in
      "$CLOUD_ROOT"/*|"$HOME"/Library/CloudStorage/*|"$HOME"/Library/Mobile\ Documents/*) : ;;
      *) warn "$localpath -> '$target' is not under the cloud mount; leaving it untouched."; return 0 ;;
    esac
    if command -v rsync >/dev/null 2>&1; then copier="rsync -a"; else copier="cp -a"; fi
    if [ "$DRY_RUN" -eq 1 ]; then
      info "[dry-run] would move the $localpath symlink aside, mkdir a real local dir there,"
      info "[dry-run]   copy '$target' -> $localpath ($copier), verify, and RETAIN the cloud copy + aside link."
      return 0
    fi
    stamp="$(date +%Y%m%d-%H%M%S)"
    aside="${localpath}.cloud-symlink.${stamp}"
    n=1; while [ -e "$aside" ] || [ -L "$aside" ]; do aside="${localpath}.cloud-symlink.${stamp}.${n}"; n=$((n + 1)); done
    # Mutating window: flag BEFORE the mv so an interrupt leaves a recoverable state.
    MIGRATE_ACTIVE=1; MIGRATE_SRC="$localpath"; MIGRATE_ASIDE="$aside"; MIGRATE_CLOUD="$target"
    run mv "$localpath" "$aside"          # moves the LINK, not the data
    run mkdir "$localpath"                # fresh real local dir
    if [ "$copier" = "rsync -a" ]; then run rsync -a "$target/" "$localpath/"
    else run cp -a "$target/." "$localpath/"; fi
    verify_copy "$target" "$localpath" "$copier" \
      || die "post-copy verify FAILED for $target -> $localpath.
  Kept the aside symlink '$aside' and the cloud copy '$target' — removed NOTHING. Retry."
    MIGRATE_ACTIVE=0
    info "$localpath is now a real local dir (copied from the cloud)."
    info "RETAINED: cloud copy at '$target' and the old symlink at '$aside'."
    info "Delete '$aside' ONLY after you've confirmed $localpath is correct."
    return 0
  fi
  warn "$localpath is neither a directory nor a symlink; leaving it untouched."
}

# ---------------------------------------------------------------------------
# Dotfiles bare-repo lane (slice 3, step 8) — purely LOCAL. A bare repo at
# $HOME/.dotfiles with $HOME as the work tree, a sourced alias file, and an
# idempotent guarded rc-source block. NO cloud mount/remote. ADOPT (clone+checkout)
# is DEFERRED (design only — see the dotfiles-lane spec §7).
# ---------------------------------------------------------------------------

# Run git against the bare dotfiles repo with $HOME as the work tree. Body only.
dotfiles_git() { git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" "$@"; }

# True (0) if $DOTFILES_DIR is OUR bare repo (idempotency / refuse-clobber discriminator).
dotfiles_is_ours() {
  [ -d "$DOTFILES_DIR" ] || return 1
  [ "$(git --git-dir="$DOTFILES_DIR" rev-parse --is-bare-repository 2>/dev/null)" = "true" ]
}

# Resolve the rc to edit into the GLOBAL RC_TARGET. --dotfiles-rc wins; else by $SHELL
# basename. Unknown/unset $SHELL => DIE requiring --dotfiles-rc (refuse-don't-guess: a
# guessed wrong rc means the alias is written but never loaded — a silent failure).
# MUST be called BARE (never rc="$(dotfiles_resolve_rc)"): `die` (exit 1) inside $()
# exits only the SUBSHELL, so the $()-form would NOT halt the parent on failure.
dotfiles_resolve_rc() {
  if [ -n "$DOTFILES_RC" ]; then RC_TARGET="$DOTFILES_RC"; return 0; fi
  case "$(basename "${SHELL:-}")" in
    zsh)  RC_TARGET="$HOME/.zshrc" ;;
    bash) RC_TARGET="$HOME/.bashrc" ;;
    *)    die "cannot determine your shell rc from \$SHELL='${SHELL:-}'. Re-run with
  --dotfiles-rc PATH (e.g. macOS bash login shells often want --dotfiles-rc ~/.bash_profile)." ;;
  esac
}

# Add a guarded `source` block for the alias file to RC_TARGET, ONCE. Idempotency key =
# the sentinel comment (grep -qF, fixed-string). Backs the rc up FIRST (#5b uniquifier:
# timestamp + counter, -e OR -L to catch a dangling-symlink backup path). Append-only —
# never rewrites existing rc content. The source line is written SINGLE-QUOTED so
# ${XDG_CONFIG_HOME:-$HOME/.config} expands at rc-source time (per-machine); no backticks.
dotfiles_install_rc_source() {
  local bak stamp n
  if [ -f "$RC_TARGET" ] && grep -qF "$DOTFILES_SENTINEL" "$RC_TARGET" 2>/dev/null; then
    info "rc already contains the xdg-cloud dotfiles block ($RC_TARGET) — leaving it."
    return 0
  fi
  if [ -e "$RC_TARGET" ] || [ -L "$RC_TARGET" ]; then
    stamp="$(date +%Y%m%d-%H%M%S)"; bak="${RC_TARGET}.bak-${stamp}"; n=1
    while [ -e "$bak" ] || [ -L "$bak" ]; do bak="${RC_TARGET}.bak-${stamp}.${n}"; n=$((n + 1)); done
    cp "$RC_TARGET" "$bak"; info "Backed up $RC_TARGET -> $bak"
  fi
  mkdir -p "$(dirname "$RC_TARGET")"
  {
    printf '%s\n' "$DOTFILES_SENTINEL"
    # shellcheck disable=SC2016   # INTENTIONAL: keep ${XDG_CONFIG_HOME:-...} literal so it
    # expands in the USER's shell at rc-source time (per-machine), NOT at write time.
    printf '%s\n' '[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/xdg-cloud/aliases.sh" ] && . "${XDG_CONFIG_HOME:-$HOME/.config}/xdg-cloud/aliases.sh"'
    printf '%s\n' "$DOTFILES_SENTINEL_END"
  } >> "$RC_TARGET"
  info "Added the xdg-cloud dotfiles source block to $RC_TARGET"
}

# --dotfiles-init: create the bare repo + alias file + rc source block. Idempotent.
cmd_dotfiles_init() {
  begin_mutating_mode                      # guard_not_root + trap + (apply-only) lock
  if [ -e "$DOTFILES_DIR" ] || [ -L "$DOTFILES_DIR" ]; then
    dotfiles_is_ours || die "$DOTFILES_DIR exists but is not our bare git repo — refusing to clobber it."
    info "bare repo already present at $DOTFILES_DIR — ensuring config + alias only."
  fi
  dotfiles_resolve_rc                       # sets RC_TARGET or dies (in THIS shell)
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] git init --bare $DOTFILES_DIR        (skipped if already present)"
    info "[dry-run] dotfiles config --local status.showUntrackedFiles no"
    info "[dry-run] write alias file: $DOTFILES_ALIASES"
    info "[dry-run] add guarded source block to: $RC_TARGET   (only if sentinel absent; rc backed up first)"
    return 0
  fi
  dotfiles_is_ours || run git init --bare "$DOTFILES_DIR"
  dotfiles_git config --local status.showUntrackedFiles no
  # alias file — $HOME stays LITERAL (escaped \$HOME under a double-quoted printf format,
  # single-quoted alias value); NO backticks (parse/source-time execution footgun).
  mkdir -p "$(dirname "$DOTFILES_ALIASES")"
  {
    printf '%s\n' "# Generated by $SELF — bare-repo dotfiles alias. Sourced from your shell rc."
    printf '%s\n' "alias dotfiles='git --git-dir=\$HOME/.dotfiles --work-tree=\$HOME'"
  } > "$DOTFILES_ALIASES"
  info "Wrote alias file: $DOTFILES_ALIASES"
  dotfiles_install_rc_source                # idempotent + #5b backup
  info "Done. Open a new shell (or '. $RC_TARGET') then: dotfiles status"
}

# Refuse tracking a path that collides with a cloud-xdg-managed lane or recurses into the
# bare repo. Name-based on the top-level $HOME component (no CLOUD_ROOT needed).
dotfiles_guard_path() {
  local arg="$1" abs rel top k nm
  case "$arg" in /*) abs="$arg" ;; *) abs="$HOME/$arg" ;; esac
  case "$abs" in "$HOME"/*) : ;; *) die "refusing '$arg' — outside \$HOME (the dotfiles work-tree)." ;; esac
  rel="${abs#"$HOME"/}"; top="${rel%%/*}"
  [ "$top" = ".dotfiles" ] && die "refusing \$HOME/.dotfiles (the bare repo itself — recursion)."
  # shellcheck disable=SC2086   # intentional word-split of the space-separated key list
  for k in $CLOUDXDG_KEYS; do
    nm="$(local_name "$(field "$(registry_row "$k")" 2)" "$(field "$(registry_row "$k")" 3)")"
    [ "$top" = "$nm" ] && die "refusing '$top' — it is a cloud-xdg redirect target (user-data lane)."
  done
  # shellcheck disable=SC2086
  for k in $CODE_KEYS; do
    nm="$(local_name "$(field "$(code_row "$k")" 2)" "$(field "$(code_row "$k")" 3)")"
    [ "$top" = "$nm" ] && die "refusing '$top' — it is a CODE/offload container (manage with --offload)."
  done
  # shellcheck disable=SC2086
  for k in $LOCAL_KEYS; do
    nm="$(local_name "$(field "$(code_row "$k")" 2)" "$(field "$(code_row "$k")" 3)")"
    [ "$top" = "$nm" ] && die "refusing '$top' — it is a machine-local dir (never tracked)."
  done
  # Fall-through = allowed. Explicit success: the last loop's `[ ] && die` leaves a
  # non-zero status when nothing matched, which under set -e would abort the caller.
  return 0
}

# --dotfiles-track <path>: stage + commit one path into the bare repo (v1: single path).
cmd_dotfiles_track() {                       # $1 = path (MODE_ARG)
  begin_mutating_mode
  dotfiles_is_ours || die "no dotfiles bare repo at $DOTFILES_DIR — run --dotfiles-init first."
  dotfiles_guard_path "$1"                    # dies on overlap/recursion
  # Resolve to an ABSOLUTE pathspec so `git add` works regardless of the invoking CWD
  # (a relative "$1" would otherwise be resolved against CWD, not the $HOME work-tree).
  local tadd
  case "$1" in /*) tadd="$1" ;; *) tadd="$HOME/$1" ;; esac
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] dotfiles add $1"; info "[dry-run] dotfiles commit -m 'track: $1'"; return 0
  fi
  run git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" add "$tadd"
  dotfiles_git commit -m "track: $1"
  info "Tracked: $1"
}

# --dotfiles-status: read-only. NO begin_mutating_mode, ZERO mutation.
cmd_dotfiles_status() {
  if ! dotfiles_is_ours; then info "no dotfiles bare repo at $DOTFILES_DIR (run --dotfiles-init)."; return 0; fi
  log "Tracked dotfiles (git status -s):"
  dotfiles_git status -s
  if [ -f "$DOTFILES_ALIASES" ]; then info "alias file: present ($DOTFILES_ALIASES)"
  else info "alias file: MISSING ($DOTFILES_ALIASES) — run --dotfiles-init"; fi
  # rc sentinel: best-effort, read-only, never die. Check --dotfiles-rc if given, else
  # the two default rc files (avoids reporting the same file twice when --dotfiles-rc
  # equals a default).
  local rc found=0
  if [ -n "$DOTFILES_RC" ]; then
    if [ -f "$DOTFILES_RC" ] && grep -qF "$DOTFILES_SENTINEL" "$DOTFILES_RC" 2>/dev/null; then
      info "rc source block: present in $DOTFILES_RC"; found=1
    fi
  else
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
      if [ -f "$rc" ] && grep -qF "$DOTFILES_SENTINEL" "$rc" 2>/dev/null; then
        info "rc source block: present in $rc"; found=1
      fi
    done
  fi
  if [ "$found" -eq 0 ]; then info "rc source block: not found (run --dotfiles-init, or --dotfiles-rc PATH)"; fi
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  guard_not_root                # #5a — cheapest refusal, before any filesystem work
  resolve_cloud_root
  normalize_cloud_root
  check_cloud_liveness
  # Arm the cleanup traps FIRST, then take the lock. Order matters (PR #11): if the
  # lock were acquired before the trap was armed, a signal in that gap would strand
  # the lock dir. The handlers are flag/LOCK_OWNED-gated, so arming before any work
  # (and before the lock is owned) is a safe no-op. The trap owns lock release +
  # probe revert + relocate recovery for the rest of the run.
  install_cleanup_trap
  acquire_lock
  log "============================================================="
  log " cloud-xdg-provision  platform=$PLATFORM  style=$STYLE  mode=$([ "$DRY_RUN" -eq 1 ] && echo DRY-RUN || echo APPLY)"
  log " cloud root: $CLOUD_ROOT"
  log "============================================================="

  ensure_local_base
  log ""
  ensure_cloud_tree
  log ""
  log "Redirecting local user dirs -> cloud:"
  # CRITICAL (PR #11): feed OFFLOAD_SET via a here-doc, NOT `printf | while`. A pipe
  # runs the loop body — and thus relocate_dir — in a SUBSHELL, where the PROBE_ACTIVE/
  # RELOCATE_ACTIVE flags it raises never reach the parent shell that owns the cleanup
  # traps (and where the subshell's traps are reset to default). That silently
  # disabled probe-revert + mid-relocate recovery on SIGINT/TERM. A here-doc redirect
  # keeps the loop AND relocate_dir in the PARENT shell, so flags and traps share
  # scope. Parsing is identical to the old pipe: $OFFLOAD_SET still expands with its
  # leading/trailing blank lines, which the `[ -z "$line" ] && continue` skips.
  # (Other printf|while loops — ensure_cloud_tree, write_user_dirs — set no trap
  # flags, so they stay piped.)
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    redirect_one "$line"
  done <<EOF
$OFFLOAD_SET
EOF
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

# ---------------------------------------------------------------------------
# Dispatch — default (no mode flag) runs the provision lane (main); a mode flag
# runs its handler. detect_platform already ran at top level above; read-only
# modes need no cloud-root/lock (main resolves those itself). Reserved mutating
# lanes are recognized but refuse until their slice lands.
# ---------------------------------------------------------------------------
dispatch_mode() {
  case "$MODE" in
    classify)         cmd_classify ;;
    offload-status)   cmd_offload_status ;;
    offload)          cmd_offload   "$MODE_ARG" ;;
    hydrate)          cmd_hydrate   "$MODE_ARG" ;;
    migrate-projects) cmd_migrate_projects ;;
    dotfiles-init)    cmd_dotfiles_init ;;
    dotfiles-track)   cmd_dotfiles_track "$MODE_ARG" ;;
    dotfiles-status)  cmd_dotfiles_status ;;
    *)                die "internal: unknown mode '$MODE'" ;;
  esac
}

if [ -n "$MODE" ]; then dispatch_mode; else main; fi
