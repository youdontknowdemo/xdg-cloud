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

# Reclaim lane — DELETES regenerable build artifacts to free disk (counterpart to
# --offload). dry-run default; --apply acts; --global also sweeps the fixed cache
# allow-list. RECLAIM_ROOT is set by cmd_reclaim + read by reclaim_rm's guard.
RECLAIM_GLOBAL=0
RECLAIM_ROOT=""

# iCloud brctl lane (slice 5, step 9) — macOS-only true-offload for iCloud-native data. SECONDARY
# to the rclone --offload (which verifies durable upload before dropping local); iCloud evict is
# heavily gated + fail-closed. status/download are stock; evict needs the compiled upload-state
# helper (make helper) — it is env-overridable so tests can shim it.
ICLOUD_ROOT="$HOME/Library/Mobile Documents/com~apple~CloudDocs"   # same iCloud root as cloud_root_is_live
: "${ICLOUD_HELPER:=$__self_dir/icloud-uploaded}"                  # compiled binary beside this script
ICLOUD_CONFIRM=0                                                    # set by --i-understand-data-loss-risk
ICLOUD_TARGET=""                                                    # resolved target (set by icloud_resolve_under_root)

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

# Dotfiles-adopt window (slice 4). Set ACTIVE around the clone->aside->checkout window so an
# interrupt reports the recoverable state; STAGE ("clone"/"aside"/"checkout") refines the
# message (a partial clone vs. some originals already moved aside). Apply-mode only.
DOTFILES_ADOPT_ACTIVE=0
DOTFILES_ADOPT_STAGE=""

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
#   5. DOTFILES_ADOPT_ACTIVE — print the stage-aware mid-adopt recovery message (slice
#      4): a partial clone and/or originals already moved aside to *.pre-dotfiles are
#      all retained, so the adopt is recoverable (remove a partial repo, then re-run).
#   6. LOCK_OWNED — release the concurrency lock (#5c) on EVERY exit path (success,
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
  if [ "${DOTFILES_ADOPT_ACTIVE:-0}" -eq 1 ]; then
    warn "INTERRUPTED mid-adopt (stage: ${DOTFILES_ADOPT_STAGE:-?}) — your data is SAFE:"
    warn "  bare repo: '$DOTFILES_DIR' (a PARTIAL clone if it stopped during 'clone')."
    warn "  any originals already moved are at '\$HOME/*.pre-dotfiles-*' (RETAINED)."
    warn "  To retry: remove a partial repo first ('rm -rf $DOTFILES_DIR'), then re-run --dotfiles-remote."
    warn "  Restore an aside by moving it back. Delete NOTHING until verified."
    DOTFILES_ADOPT_ACTIVE=0
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
  --dotfiles-track <p>…  Track one or more dotfiles/dirs into the bare repo in ONE commit
                         (refuses cloud-xdg-managed paths; all-or-nothing). --apply to commit.
  --dotfiles-status      Show tracked-file status + whether the alias/rc block are installed.
  --dotfiles-remote URL  ADOPT an existing dotfiles repo on a fresh machine: clone --bare into
                         ~/.dotfiles, move any colliding files aside (*.pre-dotfiles), then check
                         out (never --force). Refuses if ~/.dotfiles already exists. --apply to act.
  --dotfiles-rc PATH     Shell rc to edit (default: ~/.zshrc for zsh, ~/.bashrc for bash).
                         macOS bash login shells usually want --dotfiles-rc ~/.bash_profile.

iCloud (macOS only; paths under ~/Library/Mobile Documents/com~apple~CloudDocs):
  --icloud-status <path>    Report in-iCloud / dataless / uploaded state (read-only).
  --icloud-download <path>  Materialize (hydrate) dataless files — only ADDS data, reversible.
  --icloud-evict <path>     Free local space by evicting FULLY-UPLOADED files to dataless
                            placeholders. Requires the compiled upload-state helper (make helper)
                            AND --i-understand-data-loss-risk. dry-run unless --apply.
                            NOTE: for guaranteed space-freeing prefer the rclone offload (--offload);
                            it verifies durable upload before dropping local.
  --i-understand-data-loss-risk  Required consent for --icloud-evict (no reliable programmatic
                            check for the 'Optimize Mac Storage' setting).

Reclaim (free local disk by deleting REGENERABLE build artifacts; dry-run unless --apply):
  --reclaim [PATH]          Sweep PATH (default: cwd) for build artifacts (Rust target/,
                            node_modules, __pycache__, framework caches, and manifest-
                            anchored + git-ignored build/dist/out) and delete them.
                            Never touches git-tracked or unanchored dirs. Prefers
                            tool-native clean (cargo/mvn/gradle) over rm.
                            CAUTION: with --apply this EXECUTES project build tooling
                            (./gradlew, cargo/mvn/gradle clean) in swept dirs — only
                            point it at trees you trust.
  --global                  Also sweep the fixed user-cache allow-list (Homebrew, npm,
                            pip, Xcode DerivedData, ~/.gradle/caches). Opt-in.

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
    --dotfiles-track)     set_mode dotfiles-track; shift
                          # v2: consume ALL following non-flag args as the path list,
                          # newline-joined into MODE_ARG (newline, not space, so paths
                          # containing spaces survive — the consumer reads it via the same
                          # here-doc idiom). Stop at the next flag; `continue` skips the
                          # trailing shift since this arm consumed its own args.
                          [ $# -gt 0 ] && [ "${1#-}" = "$1" ] || die "--dotfiles-track needs at least one path"
                          while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do
                            MODE_ARG="$MODE_ARG
$1"
                            shift
                          done
                          continue ;;
    --dotfiles-status)    set_mode dotfiles-status ;;
    --dotfiles-remote)    set_mode dotfiles-remote; shift; MODE_ARG="${1:?--dotfiles-remote needs a repo URL}" ;;
    --icloud-status)      set_mode icloud-status;   shift; MODE_ARG="${1:?--icloud-status needs a path}" ;;
    --icloud-download)    set_mode icloud-download; shift; MODE_ARG="${1:?--icloud-download needs a path}" ;;
    --icloud-evict)       set_mode icloud-evict;    shift; MODE_ARG="${1:?--icloud-evict needs a path}" ;;
    --i-understand-data-loss-risk) ICLOUD_CONFIRM=1 ;;
    --reclaim)            set_mode reclaim
                          # optional root path: consume the next arg only if it's not a flag
                          if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then shift; MODE_ARG="$1"; fi ;;
    --global)             RECLAIM_GLOBAL=1 ;;
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
#
# GIT_CEILING hardening (PR #23 / smoke C13): the rev-parse calls below ask "is THIS dir its
# own git work tree?" — they must NOT inherit a PARENT git repo if the container happens to be
# nested inside one. GIT_CEILING_DIRECTORIES stops git's upward search before it ascends ABOVE
# the listed (absolute) dir. The ceiling MUST be the PARENT of the dir being probed: git
# ignores a ceiling equal to the `-C` working directory ("will not exclude the current working
# directory"), so a ceiling of the probed dir itself is a NO-OP (verified on git 2.54.0). Thus
# the container probe uses dirname(base); each depth-1 subdir probe uses base (= dirname of
# base/<sub>). For a container NOT nested in any repo (the common ~/repos case), this is
# identical to the unscoped probe — no regression.
offload_repos_in() {
  local base="$1" d parent
  parent="$(dirname "$base")"
  if GIT_CEILING_DIRECTORIES="$parent" git -C "$base" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s\n' "$base"; return 0
  fi
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    GIT_CEILING_DIRECTORIES="$base" git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 && printf '%s\n' "$d"
  done
  # Explicit success: the loop's last `git … && printf` leaves a non-zero status when the
  # final subdir is not a repo, which under set -e would abort `repos="$(offload_repos_in …)"`
  # in the caller. The function's contract is its OUTPUT (the repo list), not its exit code.
  return 0
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

# Write the dedicated alias file. $HOME stays LITERAL (escaped \$HOME under a double-quoted
# printf format, single-quoted alias value); NO backticks (parse/source-time execution footgun).
# Extracted from cmd_dotfiles_init (slice 4) so --dotfiles-remote (adopt) reuses it verbatim.
dotfiles_write_aliases() {
  mkdir -p "$(dirname "$DOTFILES_ALIASES")"
  {
    printf '%s\n' "# Generated by $SELF — bare-repo dotfiles alias. Sourced from your shell rc."
    printf '%s\n' "alias dotfiles='git --git-dir=\$HOME/.dotfiles --work-tree=\$HOME'"
  } > "$DOTFILES_ALIASES"
  info "Wrote alias file: $DOTFILES_ALIASES"
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
  dotfiles_write_aliases                     # extracted (slice 4) — behavior-identical
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
cmd_dotfiles_track() {                       # $1 = newline-joined path list (MODE_ARG)
  begin_mutating_mode
  dotfiles_is_ours || die "no dotfiles bare repo at $DOTFILES_DIR — run --dotfiles-init first."
  local paths="$1" p abs joined
  # PASS 1 — FAIL-CLOSED ATOMIC: validate EVERY path (overlap/recursion guard + existence)
  # BEFORE staging or committing anything. dotfiles_guard_path dies on the first managed/
  # recursive path, so if ANY path is bad nothing is staged (all-or-nothing). Paths are
  # read via a here-doc (newline-delimited) so spaces in a path are preserved.
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    dotfiles_guard_path "$p"                  # dies on overlap/recursion
    case "$p" in /*) abs="$p" ;; *) abs="$HOME/$p" ;; esac
    [ -e "$abs" ] || die "refusing to track '$p' — no such file or directory under \$HOME."
  done <<EOF
$paths
EOF
  # Human-readable one-line list for messages/commit (newlines -> spaces; safe for display).
  joined="$(printf '%s' "$paths" | tr '\n' ' ' | sed 's/^ *//; s/ *$//')"
  if [ "$DRY_RUN" -eq 1 ]; then
    while IFS= read -r p; do [ -z "$p" ] && continue; info "[dry-run] dotfiles add $p"; done <<EOF
$paths
EOF
    info "[dry-run] dotfiles commit -m 'track: $joined'  (ONE commit for all paths)"; return 0
  fi
  # PASS 2 — all guards passed: stage every path (ABSOLUTE pathspec so `git add` works from
  # any CWD, not just $HOME), then exactly ONE commit.
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$p" in /*) abs="$p" ;; *) abs="$HOME/$p" ;; esac
    run git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" add "$abs"
  done <<EOF
$paths
EOF
  dotfiles_git commit -m "track: $joined"
  info "Tracked: $joined"
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

# True (0) if the top-level $HOME component of a repo-relative path is a cloud-xdg-managed lane
# (a CLOUDXDG redirect target / a CODE container / a machine-LOCAL dir) or the bare repo itself.
# This is the NON-DYING sibling of dotfiles_guard_path — adopt needs a boolean to scan every
# tracked path and report ALL offenders in one message. Ends with an explicit `return 1` so the
# no-match path never leaves a non-zero status that would trip set -e in the caller.
# Case-fold helper (bash 3.2 has no ${v,,}). Lowercases via tr so a managed-name compare is
# case-INSENSITIVE — on a case-insensitive FS (macOS default) 'documents/' IS the 'Documents'
# dir and must still be refused (security review: case-sensitive compare let it evade the guard).
_dotfiles_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

dotfiles_path_is_managed() {
  local rel="$1" top top_lc k nm
  rel="${rel#/}"; top="${rel%%/*}"
  top_lc="$(_dotfiles_lc "$top")"
  [ "$top_lc" = ".dotfiles" ] && return 0
  # shellcheck disable=SC2086
  for k in $CLOUDXDG_KEYS; do
    nm="$(local_name "$(field "$(registry_row "$k")" 2)" "$(field "$(registry_row "$k")" 3)")"
    [ "$top_lc" = "$(_dotfiles_lc "$nm")" ] && return 0
  done
  # shellcheck disable=SC2086
  for k in $CODE_KEYS; do
    nm="$(local_name "$(field "$(code_row "$k")" 2)" "$(field "$(code_row "$k")" 3)")"
    [ "$top_lc" = "$(_dotfiles_lc "$nm")" ] && return 0
  done
  # shellcheck disable=SC2086
  for k in $LOCAL_KEYS; do
    nm="$(local_name "$(field "$(code_row "$k")" 2)" "$(field "$(code_row "$k")" 3)")"
    [ "$top_lc" = "$(_dotfiles_lc "$nm")" ] && return 0
  done
  return 1
}

# True (0) if a repo-relative path is LEXICALLY unsafe — it could escape the $HOME work tree when
# joined as "$HOME/$path". SECURITY (Finding 1, empirically confirmed): a malicious repo can track
# '../evil' via a crafted tree (nested tree with a '..' subtree); `git ls-tree` lists it verbatim,
# and "$HOME/../evil" escapes $HOME — so the pre-aside mv (or checkout) would touch a file OUTSIDE
# the work tree. Refused in PASS A before ANY aside/mutation. Explicit `return 1` on safe (set-e).
dotfiles_path_is_unsafe() {
  case "$1" in
    /*|..|../*|./*|*/../*|*/..) return 0 ;;   # absolute, '..', leading '../' or './', embedded/trailing '/..'
  esac
  return 1
}

# --dotfiles-remote <url>: ADOPT an existing dotfiles repo on a FRESH machine. Clone --bare into
# ~/.dotfiles, move any colliding $HOME files aside (*.pre-dotfiles-<stamp>), then checkout with
# NO --force. LOAD-BEARING: never clobber a user file. Two-pass (lead refinement): PASS A scans
# the FULL tracked list and dies (leaving $HOME untouched) if ANY tracked path is a managed lane;
# PASS B pre-asides every collider, THEN checks out.
cmd_dotfiles_adopt() {                        # $1 = repo URL
  begin_mutating_mode                          # guard_not_root + trap + (apply-only) lock
  local url="$1" p abs bak stamp n aside_list tmp home_real refused tracked_file parent_real
  # ---- refuse-clobber: adopt is fresh-machine only ----
  if [ -e "$DOTFILES_DIR" ] || [ -L "$DOTFILES_DIR" ]; then
    if dotfiles_is_ours; then
      die "$DOTFILES_DIR already exists (already initialized). Adopt is for a FRESH machine — use
  'dotfiles pull' / --dotfiles-track for an existing repo."
    fi
    die "$DOTFILES_DIR exists but is not our bare repo — refusing to clobber it."
  fi
  dotfiles_resolve_rc                          # sets RC_TARGET or dies IN THIS SHELL (before any mutation)
  # Canonical $HOME (symlinks resolved) for the PASS B realpath confinement backstop.
  home_real="$(cd "$HOME" 2>/dev/null && pwd -P)" || die "cannot resolve \$HOME ('$HOME')."

  # ---- dry-run: temp-clone preview. Nothing under $HOME is touched. ----
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] git clone --bare '$url' -> $DOTFILES_DIR ; config status.showUntrackedFiles=no"
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/xdg-adopt.XXXXXX")" || die "cannot create temp dir for dry-run preview"
    if git clone --bare "$url" "$tmp" >/dev/null 2>&1; then
      # NUL-delimited so exotic filenames (non-ASCII/control/quote — which --name-only would
      # C-quote) round-trip. A PIPE (subshell) is fine here: the preview only prints — it does not
      # accumulate, die, or set a trap flag (unlike the apply-path scans, which must run in the
      # parent shell). command-sub would strip the NULs, so it is NOT usable.
      git --git-dir="$tmp" ls-tree -r -z --name-only HEAD 2>/dev/null | while IFS= read -r -d '' p; do
        [ -z "$p" ] && continue
        if dotfiles_path_is_unsafe "$p"; then info "[dry-run] WOULD REFUSE: unsafe path '$p' (would escape \$HOME)"; continue; fi
        if dotfiles_path_is_managed "$p"; then info "[dry-run] WOULD REFUSE: repo tracks managed path '$p'"; continue; fi
        if [ -e "$HOME/$p" ] || [ -L "$HOME/$p" ]; then info "[dry-run] would move aside: \$HOME/$p"; fi
      done
      info "[dry-run] would then: dotfiles checkout (NO --force); write $DOTFILES_ALIASES + rc block on $RC_TARGET."
    else
      warn "[dry-run] clone preview failed for '$url' (network/URL?). Under --apply this aborts cleanly, \$HOME untouched."
    fi
    rm -rf "$tmp"
    return 0
  fi

  # ---- CLONE (apply). Failure => remove the partial repo; $HOME untouched (nothing moved yet). ----
  DOTFILES_ADOPT_ACTIVE=1; DOTFILES_ADOPT_STAGE="clone"
  if ! git clone --bare "$url" "$DOTFILES_DIR"; then
    rm -rf "$DOTFILES_DIR"                      # only ours-this-run (a pre-existing repo was refused above)
    DOTFILES_ADOPT_ACTIVE=0
    die "git clone --bare failed for '$url'. Removed the partial $DOTFILES_DIR; your \$HOME is untouched."
  fi
  dotfiles_git config --local status.showUntrackedFiles no

  # ---- enumerate tracked paths, NUL-delimited, into a TEMP FILE. NUL is the only separator safe
  #      for arbitrary filenames; command substitution STRIPS NULs and a pipe would run the scan
  #      loops in a subshell (breaking die/accumulation/trap-flag-in-parent), so each pass reads
  #      from the file via redirect (parent shell, NULs + exotic names preserved). ----
  tracked_file="$(mktemp "${TMPDIR:-/tmp}/xdg-adopt-tracked.XXXXXX")" || {
    rm -rf "$DOTFILES_DIR"; DOTFILES_ADOPT_ACTIVE=0
    die "cannot create temp file for the tracked-path scan; removed the clone, \$HOME untouched."
  }
  dotfiles_git ls-tree -r -z --name-only HEAD > "$tracked_file" 2>/dev/null || true

  # ---- PASS A — fail-closed pre-scan (BEFORE any aside/mutation): refuse the WHOLE adopt if any
  #      tracked path is UNSAFE (would escape $HOME) or a cloud-xdg-managed lane. Accumulate ALL
  #      offenders; if any, remove the fresh clone so $HOME is FULLY untouched, then die. ----
  refused=""
  # shellcheck disable=SC2094   # false positive: the ls-tree write above fully completes before this read (separate statements)
  while IFS= read -r -d '' p; do
    [ -z "$p" ] && continue
    if dotfiles_path_is_unsafe "$p"; then refused="${refused}    $p    (unsafe — would escape \$HOME)
"
    elif dotfiles_path_is_managed "$p"; then refused="${refused}    $p    (cloud-xdg-managed lane)
"; fi
  done < "$tracked_file"
  if [ -n "$refused" ]; then
    rm -f "$tracked_file"; rm -rf "$DOTFILES_DIR"; DOTFILES_ADOPT_ACTIVE=0
    die "the remote repo tracks unsafe or cloud-xdg-managed path(s) — refusing adopt. Removed the
  fresh clone; your \$HOME is UNTOUCHED. Offenders:
${refused}  Fix the repo (remove escaping paths; untrack managed dirs), then retry."
  fi

  # ---- PASS B — collision pre-aside. Managed/unsafe already refused. BACKSTOP (defense-in-depth
  #      vs a symlinked intermediate dir the lexical PASS A can't see): resolve the collider's
  #      parent (pwd -P) and refuse if it lands OUTSIDE $HOME BEFORE mv. Symlink colliders move the
  #      LINK (not the target); NEVER overwrites an existing aside. ----
  DOTFILES_ADOPT_STAGE="aside"; aside_list=""
  # shellcheck disable=SC2094   # false positive: the ls-tree write above fully completes before this read (separate statements)
  while IFS= read -r -d '' p; do
    [ -z "$p" ] && continue
    abs="$HOME/$p"
    if [ -e "$abs" ] || [ -L "$abs" ]; then
      parent_real="$(cd "$(dirname "$abs")" 2>/dev/null && pwd -P)" || parent_real=""
      case "$parent_real" in
        "$home_real"|"$home_real"/*) : ;;
        *) rm -f "$tracked_file"; rm -rf "$DOTFILES_DIR"; DOTFILES_ADOPT_ACTIVE=0
           die "refusing: tracked path '$p' resolves OUTSIDE \$HOME ('$abs' -> '${parent_real:-unresolved}'). Removed the clone; any asides so far RETAINED — inspect." ;;
      esac
      stamp="$(date +%Y%m%d-%H%M%S)"; bak="${abs}.pre-dotfiles-${stamp}"; n=1
      while [ -e "$bak" ] || [ -L "$bak" ]; do bak="${abs}.pre-dotfiles-${stamp}.${n}"; n=$((n + 1)); done
      mkdir -p "$(dirname "$abs")"
      mv "$abs" "$bak"
      aside_list="${aside_list}    $abs  ->  $bak
"
    fi
  done < "$tracked_file"
  rm -f "$tracked_file"

  # ---- CHECKOUT (NO -f/--force). Colliders are aside, so it writes only absent paths => clean. ----
  DOTFILES_ADOPT_STAGE="checkout"
  if ! dotfiles_git checkout; then
    DOTFILES_ADOPT_ACTIVE=0
    warn "dotfiles checkout FAILED unexpectedly after pre-asiding colliders — NOT forcing."
    if [ -n "$aside_list" ]; then
      warn "Files moved aside (RETAINED):"; printf '%s' "$aside_list" >&2
      die "adopt incomplete: bare repo left at $DOTFILES_DIR; the asides above are retained. Inspect, then retry or restore. Delete NOTHING until verified."
    fi
    die "adopt incomplete: bare repo left at $DOTFILES_DIR (no files were moved aside). Inspect, then retry. Delete NOTHING until verified."
  fi
  DOTFILES_ADOPT_ACTIVE=0

  # ---- RC wiring. Always write the alias file. But if the ADOPTED repo TRACKS the rc we'd edit,
  #      do NOT append our sentinel block — it would dirty the just-checked-out tracked rc and risk
  #      folding our machine-specific block into their repo. Inform the user instead. ----
  dotfiles_write_aliases
  if dotfiles_git ls-files --error-unmatch "$RC_TARGET" >/dev/null 2>&1; then
    info "Your rc ($RC_TARGET) is tracked by the adopted repo — NOT adding our source block (it would"
    info "  dirty the tracked rc). Ensure your rc sources the alias file: $DOTFILES_ALIASES"
  else
    dotfiles_install_rc_source
  fi

  # ---- report ----
  if [ -n "$aside_list" ]; then
    info "Adopted '$url'. Pre-existing files were moved aside (RETAINED — reconcile, then delete):"
    printf '%s' "$aside_list"
  else
    info "Adopted '$url' (no collisions)."
  fi
  info "Open a new shell (or '. $RC_TARGET'), then: dotfiles status"
}

# ---------------------------------------------------------------------------
# iCloud brctl lane (slice 5, step 9) — macOS-only. SECONDARY to the rclone --offload (which
# verifies durable upload before dropping local). --icloud-evict is fail-closed: it evicts NOTHING
# unless every gate passes AND the compiled helper confirms EVERY candidate is fully uploaded.
# --icloud-status is read-only; --icloud-download only ADDS data (reversible). Live iCloud is not
# testable in smoke — brctl is invoked via run() (PATH-shimmable) and the helper via $ICLOUD_HELPER.
# ---------------------------------------------------------------------------

icloud_guard_macos() { [ "$PLATFORM" = "macos" ] || die "iCloud modes are macOS-only (this is $PLATFORM)."; }

icloud_require_brctl() { command -v brctl >/dev/null 2>&1 || die "brctl not found (macOS iCloud tool). Cannot proceed."; }

# Normalize $1 to an absolute path and require it under $ICLOUD_ROOT (and that it exists).
# bash 3.2 — no readlink -f. Sets the global ICLOUD_TARGET.
icloud_resolve_under_root() {
  case "$1" in /*) ICLOUD_TARGET="$1" ;; *) ICLOUD_TARGET="$(pwd)/$1" ;; esac
  case "$ICLOUD_TARGET" in
    "$ICLOUD_ROOT"|"$ICLOUD_ROOT"/*) : ;;
    *) die "path is not under iCloud Drive ($ICLOUD_ROOT): $ICLOUD_TARGET" ;;
  esac
  [ -e "$ICLOUD_TARGET" ] || die "no such path: $ICLOUD_TARGET"
}

# True (0) if $1 is already dataless (evicted / no local extents) — evict would be a no-op.
# Explicit return in each branch (set-e trailing-match footgun).
icloud_is_dataless() {
  case "$(stat -f '%Sf' "$1" 2>/dev/null)" in
    *dataless*) return 0 ;;
    *)          return 1 ;;
  esac
}

# --icloud-status <path>: read-only report. NO helper required (reports 'unknown' without it).
cmd_icloud_status() {                    # $1 = path
  icloud_guard_macos
  icloud_resolve_under_root "$1"
  local have_helper=0; [ -x "$ICLOUD_HELPER" ] && have_helper=1
  log "iCloud status under: $ICLOUD_TARGET (read-only)"
  local ftmp f ubi datal upl
  ftmp="$(mktemp "${TMPDIR:-/tmp}/xdg-icloud.XXXXXX")" || die "cannot create temp file"
  find "$ICLOUD_TARGET" -type f > "$ftmp" 2>/dev/null || true
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if icloud_is_dataless "$f"; then datal="dataless"; else datal="materialized"; fi
    case "$(mdls -name kMDItemFSIsUbiquitous -raw "$f" 2>/dev/null)" in 1|"(1)"|true) ubi="in-icloud" ;; *) ubi="local?" ;; esac
    if [ "$have_helper" -eq 1 ]; then
      if "$ICLOUD_HELPER" "$f" >/dev/null 2>&1; then upl="uploaded"; else upl="not-uploaded"; fi
    else upl="unknown(helper not built)"; fi
    printf '  %-12s %-14s %-24s %s\n' "$ubi" "$datal" "$upl" "$f"
  done < "$ftmp"
  rm -f "$ftmp"
}

# --icloud-download <path>: materialize dataless files. Only ADDS data — reversible/safe. No helper.
cmd_icloud_download() {                  # $1 = path
  begin_mutating_mode
  icloud_guard_macos; icloud_resolve_under_root "$1"; icloud_require_brctl
  local ftmp f
  ftmp="$(mktemp "${TMPDIR:-/tmp}/xdg-icloud.XXXXXX")" || die "cannot create temp file"
  find "$ICLOUD_TARGET" -type f > "$ftmp" 2>/dev/null || true
  [ -s "$ftmp" ] || { rm -f "$ftmp"; info "no files to download under: $ICLOUD_TARGET"; return 0; }
  while IFS= read -r f; do [ -z "$f" ] && continue; run brctl download "$f"; done < "$ftmp"
  rm -f "$ftmp"
  if [ "$DRY_RUN" -eq 1 ]; then info "[dry-run] would download (hydrate) the files above (re-run with --apply)."
  else info "Download (hydrate) complete."; fi
}

# --icloud-evict <path>: THE fail-closed gate. Evict local copies of FULLY-UPLOADED files to dataless
# placeholders. Gates cheapest -> most-expensive; ANY fail => die, evict NOTHING. No trap flag: each
# evict is pre-proven-uploaded AND reversible (re-download), so a mid-batch interrupt is safe.
cmd_icloud_evict() {                     # $1 = path
  begin_mutating_mode
  icloud_guard_macos                                   # (1) macOS only
  icloud_resolve_under_root "$1"                       # (2) under CloudDocs (+ exists)
  icloud_require_brctl                                 # (3) brctl present
  [ -x "$ICLOUD_HELPER" ] || die "upload-state helper not built ($ICLOUD_HELPER).
  Run 'make helper' (needs Xcode Command Line Tools). Without it, upload state can't be verified, so
  evict is refused. For guaranteed space-freeing use the rclone offload: '$SELF --offload <dir>'."   # (4) graceful degrade
  [ "$ICLOUD_CONFIRM" -eq 1 ] || die "evict can lose data if 'Optimize Mac Storage' is off or files
  aren't uploaded; that OS setting has no reliable programmatic check. Re-run with
  --i-understand-data-loss-risk to proceed. (Safer alternative: '$SELF --offload <dir>'.)"           # (5) explicit consent

  # (6) candidate list = every NON-dataless file (dataless = already evicted, skip as a no-op).
  # bash 3.2: temp file + while-read + indexed-array append (no mapfile / no process-substitution).
  local ftmp f; local candidates=()
  ftmp="$(mktemp "${TMPDIR:-/tmp}/xdg-icloud.XXXXXX")" || die "cannot create temp file"
  find "$ICLOUD_TARGET" -type f > "$ftmp" 2>/dev/null || true
  while IFS= read -r f; do [ -z "$f" ] && continue; icloud_is_dataless "$f" && continue; candidates+=("$f"); done < "$ftmp"
  rm -f "$ftmp"
  [ "${#candidates[@]}" -gt 0 ] || { info "nothing to evict (all already dataless or empty)."; return 0; }

  # (7) THE UPLOAD GATE — the helper must confirm EVERY candidate uploaded (rc 0), in ONE exec.
  # Read-only; runs in dry-run too for an accurate preview. Fail-closed: any not-uploaded/error =>
  # evict NOTHING (covers the WHOLE set before a single evict — no per-file interleave).
  local hout; hout="$(mktemp "${TMPDIR:-/tmp}/xdg-icloud.XXXXXX")" || die "cannot create temp file"
  if ! "$ICLOUD_HELPER" "${candidates[@]}" > "$hout" 2>/dev/null; then
    warn "refusing to evict — NOT every target file is confirmed fully-uploaded (fail-closed):"
    grep -v '^uploaded	' "$hout" 2>/dev/null | sed 's/^/    /' >&2 || true
    rm -f "$hout"
    die "evict aborted. Wait for iCloud upload (check '$SELF --icloud-status <path>'), or use
  '$SELF --offload <dir>' for a verified space-free. Nothing was evicted."
  fi
  rm -f "$hout"

  # (8) EVICT (apply only; dry-run prints via run()). Per-file — 'brctl evict <dir>' is undocumented.
  local c
  for c in "${candidates[@]}"; do run brctl evict "$c"; done
  if [ "$DRY_RUN" -eq 1 ]; then
    info "[dry-run] would evict ${#candidates[@]} fully-uploaded file(s). Re-run with --apply to act."
  else
    info "Evicted ${#candidates[@]} fully-uploaded file(s) to dataless placeholders. Re-download with
  '$SELF --icloud-download <path>' or by opening them."
  fi
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
# ---------------------------------------------------------------------------
# Reclaim lane — purge KNOWN-REGENERABLE build artifacts + (opt-in) global caches
# to free local disk. The DELETE-side counterpart to --offload. Load-bearing:
# NEVER a false positive. Tiered detection (docs/preparation/research-reclaim.md §2):
#   * unambiguous artifact name (target/+Cargo.toml, node_modules/+package.json,
#     __pycache__/.pytest_cache/.mypy_cache/.ruff_cache/*.egg-info,
#     .next/.nuxt/.svelte-kit/.turbo+package.json) -> anchor manifest sufficient.
#   * generic name (build/dist/out) -> anchor manifest AND git-ignored; refused
#     outside a git repo.
#   * git-TRACKED -> never touched. Outside a repo -> only tool-native-authoritative
#     (cargo/mvn/gradle, tool present) or pure-bytecode names; else refused.
# Guards: no symlink follow (-type d), no ascend above root, degenerate-path
# refusal, stop-descending into a matched dir, skip node_modules-with-.git.
# dry-run default; --apply gates deletion; tool-native clean preferred over rm.
# ---------------------------------------------------------------------------

reclaim_size() { du -sh "$1" 2>/dev/null | cut -f1 || printf '?'; }

# git predicates (fail-closed — any error yields the SAFE, non-deleting answer).
reclaim_in_repo()    { git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
# reclaim_is_tracked: $1=path $2=repo-dir. Returns 0 (tracked -> DON'T delete) for a
# match AND for ANY git error; returns 1 (not tracked) ONLY on the specific exit 1
# that ls-files --error-unmatch uses for a genuine no-match. Fail-closed: a corrupt
# index / lock / abnormal git state (exit 128) must never be read as "not tracked".
reclaim_is_tracked() {
  local rc
  git -C "$2" ls-files --error-unmatch -- "$1" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && return 1   # exit 1 == clean no-match -> not tracked
  return 0                      # exit 0 (tracked) or any other (error) -> treat as tracked (safe)
}
reclaim_is_ignored() { git -C "$2" check-ignore -q -- "$1" >/dev/null 2>&1; }           # $1=path $2=repo-dir

# reclaim_manifest PARENT NAME -> true iff PARENT/NAME is a REGULAR, non-symlink
# file. A symlinked manifest must not steer classification (it could otherwise
# qualify an out-of-tree dir for deletion or aim tool-native clean at an
# attacker-chosen project).
reclaim_manifest() { [ -f "$1/$2" ] && [ ! -L "$1/$2" ]; }

# reclaim_anchor NAME PARENT -> echoes the toolchain kind if PARENT holds an
# anchoring manifest for a candidate named NAME (else empty). Always returns 0.
reclaim_anchor() {
  local name="$1" p="$2"
  case "$name" in
    target)
      if   reclaim_manifest "$p" Cargo.toml; then printf 'cargo'
      elif reclaim_manifest "$p" pom.xml;    then printf 'maven'; fi ;;
    node_modules|.next|.nuxt|.svelte-kit|.turbo)
      reclaim_manifest "$p" package.json && printf 'node' ;;
    build|dist|out)
      if   reclaim_manifest "$p" package.json;   then printf 'node'
      elif reclaim_manifest "$p" build.gradle || reclaim_manifest "$p" build.gradle.kts; then printf 'gradle'
      elif reclaim_manifest "$p" pyproject.toml || reclaim_manifest "$p" setup.py; then printf 'py'
      elif reclaim_manifest "$p" CMakeLists.txt; then printf 'cmake'; fi ;;
  esac
  return 0
}

# Guarded rm: degenerate-path refusal (mirror the offload guard) then rm -rf.
reclaim_rm() {
  local d="$1"
  case "$d" in
    ""|"/"|"$HOME"|"$RECLAIM_ROOT") die "internal: refusing rm of unsafe path '$d'" ;;
    *..*)                           die "internal: refusing rm of path with '..': '$d'" ;;
  esac
  printf '  [run]     rm -rf %q\n' "$d"
  rm -rf "$d" || warn "  rm failed for $d (left as-is)"
  return 0
}

# Tool-native clean inside a project dir. Returns 1 if the tool is ABSENT (caller
# falls back to guarded rm, which is only reached in-repo); 0 if it ran (or the
# clean errored — warned, left as-is).
reclaim_toolclean() {
  local dir="$1"; shift
  command -v "$1" >/dev/null 2>&1 || return 1
  printf '  [run]     (cd %q &&' "$dir"; printf ' %q' "$@"; printf ')\n'
  ( cd "$dir" 2>/dev/null && "$@" >/dev/null 2>&1 ) || warn "  $* failed in $dir (left as-is)"
  return 0
}

# Gradle clean: prefer ./gradlew, then gradle, else (in-repo anchored+ignored) rm.
reclaim_gradle_clean() {
  local p="$1" d="$2"
  if [ -x "$p/gradlew" ]; then
    printf '  [run]     (cd %q && ./gradlew clean)\n' "$p"
    ( cd "$p" 2>/dev/null && ./gradlew -q clean >/dev/null 2>&1 ) || warn "  gradlew clean failed in $p"
    return 0
  fi
  reclaim_toolclean "$p" gradle -q clean && return 0
  reclaim_rm "$d"
}

# Global caches (opt-in --global). Fixed known paths only — never tree-discovered.
# Tool-native where available; guarded rm for the pure-artifact dirs.
reclaim_global_caches() {
  local drun; drun="$([ "$DRY_RUN" -eq 1 ] && printf dry-run || printf run)"
  log "Global caches (--global):"
  if command -v brew >/dev/null 2>&1; then
    printf '  [%s]  brew cleanup -s\n' "$drun"
    [ "$DRY_RUN" -eq 0 ] && { brew cleanup -s >/dev/null 2>&1 || true; }
  fi
  if command -v npm >/dev/null 2>&1; then
    printf '  [%s]  npm cache clean --force\n' "$drun"
    [ "$DRY_RUN" -eq 0 ] && { npm cache clean --force >/dev/null 2>&1 || true; }
  fi
  if command -v pip3 >/dev/null 2>&1; then
    printf '  [%s]  pip3 cache purge\n' "$drun"
    [ "$DRY_RUN" -eq 0 ] && { pip3 cache purge >/dev/null 2>&1 || true; }
  fi
  local dd="$HOME/Library/Developer/Xcode/DerivedData"
  [ -d "$dd" ] && { printf '  [%s]  rm -rf ~/Library/Developer/Xcode/DerivedData/* (%s)\n' "$drun" "$(reclaim_size "$dd")"; [ "$DRY_RUN" -eq 0 ] && rm -rf "${dd:?}"/* 2>/dev/null; }
  local gc="$HOME/.gradle/caches"
  [ -d "$gc" ] && { printf '  [%s]  rm -rf ~/.gradle/caches (%s)\n' "$drun" "$(reclaim_size "$gc")"; [ "$DRY_RUN" -eq 0 ] && rm -rf "${gc:?}" 2>/dev/null; }
  return 0
}

cmd_reclaim() {                       # $1 = optional root (default: cwd)
  begin_mutating_mode                 # guard_not_root + trap + (apply-only) lock
  local root rootreal cand parent base kind decision why sz cr a skip
  root="${1:-$PWD}"
  [ -d "$root" ] || die "reclaim root does not exist: $root"
  rootreal="$(cd "$root" 2>/dev/null && pwd -P)" || die "cannot resolve reclaim root: $root"
  case "$rootreal" in
    ""|"/"|"$HOME") die "refusing to sweep '$rootreal' (too broad — never a blind \$HOME/root walk). Pass a project or dev dir." ;;
  esac
  RECLAIM_ROOT="$rootreal"            # consumed by reclaim_rm's degenerate-path guard

  if [ "$DRY_RUN" -eq 1 ]; then log "Reclaim sweep under: $rootreal   (dry-run — nothing deleted; --apply to act)"
  else log "Reclaim sweep under: $rootreal   (APPLY — deleting reclaimable artifacts)"; fi

  # Discover candidate dirs by name into a NUL-delimited tempfile. -type d excludes
  # symlinks (no -L); find lists parents before children (enables stop-descend).
  local tf; tf="$(mktemp "${TMPDIR:-/tmp}/xdg-reclaim.XXXXXX")" || die "cannot create temp file"
  find "$rootreal" -type d \( -name target -o -name node_modules -o -name __pycache__ \
      -o -name .pytest_cache -o -name .mypy_cache -o -name .ruff_cache -o -name '*.egg-info' \
      -o -name .next -o -name .nuxt -o -name .svelte-kit -o -name .turbo \
      -o -name build -o -name dist -o -name out \) -print0 > "$tf" 2>/dev/null || true

  local -a accepted=()
  local plan="" n=0
  while IFS= read -r -d '' cand; do
    [ -z "$cand" ] && continue
    cr="$(cd "$cand" 2>/dev/null && pwd -P)" || continue
    case "$cr" in "$rootreal"/*) : ;; *) continue ;; esac       # strictly under root
    skip=0
    for a in ${accepted[@]+"${accepted[@]}"}; do
      case "$cr" in "$a"/*) skip=1; break ;; esac               # inside an accepted match
    done
    [ "$skip" -eq 1 ] && continue

    base="${cand##*/}"; parent="$(dirname "$cand")"
    kind="$(reclaim_anchor "$base" "$parent")"
    decision=""; why=""
    case "$base" in
      __pycache__|.pytest_cache|.mypy_cache|.ruff_cache|*.egg-info)
        decision="rm"; why="python cache/artifact (unambiguous)" ;;
      target)
        if [ "$kind" = "cargo" ]; then decision="cargo"; why="Rust target/ (Cargo.toml)"
        elif [ "$kind" = "maven" ]; then decision="maven"; why="Maven target/ (pom.xml)"
        else why="named 'target' with no Cargo.toml/pom.xml"; fi ;;
      node_modules)
        if [ -e "$cand/.git" ]; then why="node_modules holds .git (checked-out dep)"
        elif [ "$kind" = "node" ]; then decision="rm"; why="node_modules (package.json)"
        else why="node_modules with no sibling package.json"; fi ;;
      .next|.nuxt|.svelte-kit|.turbo)
        if [ "$kind" = "node" ]; then decision="rm"; why="$base build cache (package.json)"
        else why="$base with no sibling package.json"; fi ;;
      build|dist|out)
        if   [ -z "$kind" ]; then why="generic '$base' with no build manifest"
        elif ! reclaim_in_repo "$parent"; then why="generic '$base' outside a git repo (need gitignore proof)"
        elif reclaim_is_tracked "$cand" "$parent"; then why="'$base' is git-tracked"
        elif ! reclaim_is_ignored "$cand" "$parent"; then why="'$base' not git-ignored"
        elif [ "$kind" = "gradle" ]; then decision="gradle"; why="Gradle build/ (build.gradle + gitignored)"
        elif [ "$kind" = "cmake" ] && [ -f "$cand/CMakeCache.txt" ]; then decision="rm"; why="CMake build/ (CMakeLists.txt + CMakeCache.txt + gitignored)"
        elif [ "$kind" = "cmake" ]; then why="'$base' anchored by CMakeLists.txt but no CMakeCache.txt inside"
        else decision="rm"; why="'$base' (manifest + gitignored)"; fi ;;
    esac

    # Belt-and-suspenders: never delete a git-TRACKED candidate, even unambiguous ones.
    if [ -n "$decision" ] && reclaim_in_repo "$parent" && reclaim_is_tracked "$cand" "$parent"; then
      decision=""; why="$base is git-tracked"
    fi
    # Outside-a-repo tier gate: only tool-native-authoritative (cargo/mvn, tool
    # present) or pure-bytecode names may be reclaimed without a git context.
    # (generic build/dist/out already required in-repo + gitignored above, so only
    # unambiguous names reach here with a decision.)
    if [ -n "$decision" ] && ! reclaim_in_repo "$parent"; then
      case "$base" in
        __pycache__|.pytest_cache|.mypy_cache|.ruff_cache|*.egg-info) : ;;
        target)
          if   [ "$decision" = "cargo" ] && command -v cargo >/dev/null 2>&1; then :
          elif [ "$decision" = "maven" ] && command -v mvn   >/dev/null 2>&1; then :
          else decision=""; why="target/ outside a repo needs cargo/mvn present"; fi ;;
        *) decision=""; why="$base outside a git repo (not tool-native-authoritative)" ;;
      esac
    fi

    if [ -n "$decision" ]; then
      accepted+=("$cr"); n=$((n + 1)); sz="$(reclaim_size "$cand")"
      plan="${plan}  reclaim [${decision}]  ${sz}	${cand}
"
      if [ "$DRY_RUN" -eq 0 ]; then
        case "$decision" in
          cargo)  reclaim_toolclean "$parent" cargo clean || reclaim_rm "$cand" ;;
          maven)  reclaim_toolclean "$parent" mvn -q clean || reclaim_rm "$cand" ;;
          gradle) reclaim_gradle_clean "$parent" "$cand" ;;
          rm)     reclaim_rm "$cand" ;;
        esac
      fi
    elif [ -n "$why" ]; then
      plan="${plan}  skip            -	${cand}  (${why})
"
    fi
  done < "$tf"
  rm -f "$tf"

  [ "$RECLAIM_GLOBAL" -eq 1 ] && reclaim_global_caches

  printf '%s' "$plan"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "$n project artifact(s) would be reclaimed. Re-run with --apply to delete."
    [ "$RECLAIM_GLOBAL" -eq 0 ] && info "add --global to also sweep user caches (Homebrew, npm, pip, Xcode DerivedData, ~/.gradle/caches)."
  else
    log "Reclaimed $n project artifact(s) under $rootreal."
  fi
}

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
    dotfiles-remote)  cmd_dotfiles_adopt "$MODE_ARG" ;;
    icloud-status)    cmd_icloud_status   "$MODE_ARG" ;;
    icloud-download)  cmd_icloud_download "$MODE_ARG" ;;
    icloud-evict)     cmd_icloud_evict    "$MODE_ARG" ;;
    reclaim)          cmd_reclaim         "$MODE_ARG" ;;
    *)                die "internal: unknown mode '$MODE'" ;;
  esac
}

if [ -n "$MODE" ]; then dispatch_mode; else main; fi
