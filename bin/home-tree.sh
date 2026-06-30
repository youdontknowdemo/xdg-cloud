#!/usr/bin/env bash
#
# home-tree.sh — provision a clean LOCAL home/XDG tree and a SAFE cloud backup mirror.
#
# Design rule (non-negotiable):
#   * Live XDG_*_HOME stay on LOCAL fast disk. Apps read/write there.
#   * The cloud (Google Drive via rclone) is a BACKUP DESTINATION, never a live $HOME.
#   * Cache / state / live config / SQLite-backed data are NEVER synced.
#
# This corrects the common footgun of exporting XDG_*_HOME into a Drive mount,
# which corrupts SQLite (FUSE ignores POSIX locks) and thrashes bandwidth on cache.
#
# Platforms: macOS, Linux, Termux/Android. Auto-detected.
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
# Config — override any of these via environment before running.
# ---------------------------------------------------------------------------
: "${RCLONE_REMOTE:=gdrive}"          # name of your `rclone config` remote
: "${DRIVE_SUBDIR:=Backup/home}"      # path inside the remote to mirror into
: "${HOME_TREE_ROOT:=$HOME}"          # where the human-facing folders live
: "${ARCHIVE_SUBDIR:=Backup/_archive}" # where overwritten/deleted files are parked

# XDG live paths (LOCAL only) are populated by xdg_init_base_defaults() from the
# shared lib, called above.

# Human-facing folders that ARE allowed to travel to the cloud. Derived from the
# canonical registry's linuxName (field 3) for each HOMETREE_KEYS entry, in
# home-tree's own order — yielding "Documents Pictures Music Videos Projects Notes",
# identical to the previous literal array. The COUPLING INVARIANT to the rclone
# filter below is documented in the lib next to HOMETREE_KEYS (architecture §6):
# each linuxName here MUST match an allow-path in write_filter or backups silently
# drop that folder. The filter heredoc stays the single source of truth and is
# NOT derived from the registry.
SAFE_DIRS=()
# shellcheck disable=SC2086   # intentional word-split of the space-separated HOMETREE_KEYS
for __k in $HOMETREE_KEYS; do
  SAFE_DIRS+=("$(field "$(registry_row "$__k")" 3)")
done

# Folders/files that must NEVER travel to the cloud (the denylist lives in the
# generated rclone filter; this array is only for the local-creation summary).
NEVER_DIRS=(Cache State Config Downloads)

# Runtime flags
DRY_RUN=1                              # 1 = print actions only; --apply to execute
DO_SYNC=0                              # only touch the cloud when asked
SYNC_MODE="backup"                    # backup (one-way, safe) | bisync (two-way)
MAX_DELETE=25                          # refuse a sync that would delete > N files

# ---------------------------------------------------------------------------
# Plumbing
#   SELF and log/info/warn/die come from the shared lib (bin/lib/xdg-common.sh).
#   run() STAYS here (per-script): home-tree renders commands with `printf %s`
#   (unquoted, space-joined) — deliberately NOT cloud-xdg's `printf %q` per-arg.
# ---------------------------------------------------------------------------
FILTER_FILE="${TMPDIR:-/tmp}/home-tree.rclone-filter"

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    printf '  [run]     %s\n' "$*"
    "$@"
  fi
}

usage() {
  cat <<EOF
$SELF — provision a local home/XDG tree and a safe cloud backup mirror.

Usage:
  $SELF [options]

Options:
  --apply            Actually create dirs / run sync (default is dry-run).
  --sync             Perform a ONE-WAY backup (local -> cloud, deletions archived).
  --bisync           Perform a TWO-WAY sync (uses rclone bisync; see notes).
  --root PATH        Home tree root (default: \$HOME_TREE_ROOT / \$HOME).
  --remote NAME      rclone remote name (default: \$RCLONE_REMOTE / gdrive).
  --dest PATH        Subpath inside the remote (default: \$DRIVE_SUBDIR / Backup/home).
  --max-delete N     Abort a sync that would delete more than N files (default: $MAX_DELETE).
  -h, --help         This help.

Nothing destructive runs without both --apply and one of --sync/--bisync.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)      DRY_RUN=0 ;;
    --sync)       DO_SYNC=1; SYNC_MODE="backup" ;;
    --bisync)     DO_SYNC=1; SYNC_MODE="bisync" ;;
    --root)       shift; HOME_TREE_ROOT="${1:?--root needs a path}" ;;
    --remote)     shift; RCLONE_REMOTE="${1:?--remote needs a name}" ;;
    --dest)       shift; DRIVE_SUBDIR="${1:?--dest needs a path}" ;;
    --max-delete) shift; MAX_DELETE="${1:?--max-delete needs a number}" ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Platform detection — detect_platform() comes from the shared lib; main() calls
# it (sets the global PLATFORM) exactly as before.
# ---------------------------------------------------------------------------

# Find the Google Drive for Desktop FUSE mount on macOS (informational only —
# we still route backups through rclone for consistent, lock-safe behavior).
find_macos_drive_mount() {
  local d
  for d in "$HOME"/Library/CloudStorage/GoogleDrive-*; do
    if [ -d "$d/My Drive" ]; then printf '%s\n' "$d/My Drive"; return 0; fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Local tree creation
# ---------------------------------------------------------------------------
ensure_local_xdg() {
  log "Local XDG live dirs (fast disk, never cloud-redirected):"
  local d
  for d in "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"; do
    run mkdir -p "$d"
  done
}

ensure_home_tree() {
  log "Human-facing folders under: $HOME_TREE_ROOT"
  local d
  for d in "${SAFE_DIRS[@]}"; do
    run mkdir -p "$HOME_TREE_ROOT/$d"
  done
}

# ---------------------------------------------------------------------------
# rclone filter — the single source of truth for what may reach the cloud.
# First match wins. Excludes (danger) first, then the safe allowlist, then
# a final catch-all deny so nothing slips through by accident.
# ---------------------------------------------------------------------------
write_filter() {
  # Ensure the target dir exists — $TMPDIR may point at a path not yet created.
  mkdir -p "${TMPDIR:-/tmp}"
  cat > "$FILTER_FILE" <<'FILTEREOF'
# === NEVER sync: high-churn, machine-specific, or lock-sensitive ===
- /Cache/**
- /State/**
- /Config/**
- /Downloads/**
- .cache/**
- .local/state/**
- **/*.sqlite
- **/*.sqlite-wal
- **/*.sqlite-shm
- **/*.db
- **/*.db-journal
- **/.DS_Store
- **/node_modules/**
- **/.git/**
- **/__pycache__/**
- **/*.lock

# === SAFE: human-facing content allowed to travel ===
+ /Documents/**
+ /Pictures/**
+ /Music/**
+ /Videos/**
+ /Notes/**
+ /Projects/**

# === default: deny everything else ===
- *
FILTEREOF
  info "Filter written: $FILTER_FILE"
}

# ---------------------------------------------------------------------------
# Cloud sync
# ---------------------------------------------------------------------------
require_rclone() {
  command -v rclone >/dev/null 2>&1 || die "rclone not found. Install it, then 'rclone config' a remote named '$RCLONE_REMOTE'."
  rclone listremotes 2>/dev/null | grep -qx "${RCLONE_REMOTE}:" \
    || die "rclone remote '${RCLONE_REMOTE}:' not configured. Run 'rclone config'."
}

do_backup() {
  local dst="${RCLONE_REMOTE}:${DRIVE_SUBDIR}"
  local stamp arc
  stamp="$(date +%Y-%m-%d_%H%M%S)"
  arc="${RCLONE_REMOTE}:${ARCHIVE_SUBDIR}/${stamp}"
  log "ONE-WAY backup  $HOME_TREE_ROOT  ->  $dst"
  info "deletions/overwrites archived to: $arc"
  local cmd
  cmd=(rclone sync "$HOME_TREE_ROOT" "$dst"
    --filter-from "$FILTER_FILE"
    --backup-dir "$arc"
    --create-empty-src-dirs
    --max-delete "$MAX_DELETE"
    --progress)
  [ "$DRY_RUN" -eq 1 ] && cmd+=(--dry-run)
  "${cmd[@]}"
}

do_bisync() {
  local dst="${RCLONE_REMOTE}:${DRIVE_SUBDIR}"
  local marker="${XDG_STATE_HOME}/home-tree/bisync-initialized"
  log "TWO-WAY bisync  $HOME_TREE_ROOT  <->  $dst"
  local cmd
  cmd=(rclone bisync "$HOME_TREE_ROOT" "$dst"
    --filter-from "$FILTER_FILE"
    --conflict-resolve newer --conflict-loser num
    --create-empty-src-dirs
    --max-delete "$MAX_DELETE"
    --check-access
    --progress)
  if [ ! -f "$marker" ]; then
    warn "First bisync run — adding --resync to establish the baseline."
    cmd+=(--resync)
  fi
  [ "$DRY_RUN" -eq 1 ] && cmd+=(--dry-run)
  "${cmd[@]}"
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$(dirname "$marker")"; : > "$marker"
  fi
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
print_exports() {
  cat <<'EOF'

# --- Correct XDG exports (LOCAL disk — never the cloud mount) ---
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_CACHE_HOME="$HOME/.cache"
EOF
}

print_next_steps() {
  cat <<EOF

Next steps
  1. Review the dry-run above. Re-run with --apply to create the local tree.
  2. Configure rclone once:   rclone config    (make a remote named '$RCLONE_REMOTE')
  3. Safe one-way backup:     $SELF --apply --sync
     Two-way (careful):       $SELF --apply --bisync
  4. Dotfiles (live config) belong in git, NOT in this sync. Use chezmoi / yadm
     / a bare repo so you get merge semantics and host-conditional logic.
  5. Schedule backups with cron / launchd / a systemd timer pointing at:
       $SELF --apply --sync
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  detect_platform
  log "==================================================================="
  log " home-tree — platform: $PLATFORM    mode: $([ "$DRY_RUN" -eq 1 ] && echo DRY-RUN || echo APPLY)"
  log "==================================================================="

  if [ "$PLATFORM" = "macos" ]; then
    if mount="$(find_macos_drive_mount)"; then
      info "Detected Drive mount: $mount  (backups still go via rclone, not this FUSE path)"
    else
      info "No Google Drive for Desktop mount found — rclone-only is fine."
    fi
  elif [ "$PLATFORM" = "termux" ]; then
    info "Termux: HOME=$HOME, PREFIX=${PREFIX:-?}. rclone via 'pkg install rclone'."
  fi

  ensure_local_xdg
  ensure_home_tree

  log ""
  log "Never-synced (local-only) categories: ${NEVER_DIRS[*]}"
  write_filter

  if [ "$DO_SYNC" -eq 1 ]; then
    log ""
    require_rclone
    case "$SYNC_MODE" in
      backup) do_backup ;;
      bisync) do_bisync ;;
    esac
  else
    log ""
    info "No --sync/--bisync given — local tree + filter prepared, cloud untouched."
  fi

  print_exports
  print_next_steps
}

main
