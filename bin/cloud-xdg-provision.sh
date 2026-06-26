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
  if [ "$DRY_RUN" -eq 1 ]; then printf '  [dry-run] %s\n' "$*"
  else printf '  [run]     %s\n' "$*"; "$@"; fi
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

# style-applied cloud folder name
cloud_name() {
  if [ "$STYLE" = "mac" ]; then
    # capitalize first letter (portable: works on BSD/macOS + GNU)
    local first rest
    first="$(printf '%s' "$1" | cut -c1 | tr '[:lower:]' '[:upper:]')"
    rest="$(printf '%s' "$1" | cut -c2-)"
    printf '%s%s' "$first" "$rest"
  else
    printf '%s' "$1"
  fi
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
    cn="$(cloud_name "$(field "$line" 1)")"
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

  cn="$(cloud_name "$canon")"
  ln="$(local_name "$canon" "$mac" "$lin")"
  target="$CLOUD_ROOT/$cn"
  localpath="$HOME/$ln"

  # already correctly symlinked?
  if [ -L "$localpath" ] && [ "$(readlink "$localpath")" = "$target" ]; then
    info "ok: $ln -> $target"; return 0
  fi

  # missing local dir: just symlink
  if [ ! -e "$localpath" ]; then
    run ln -s "$target" "$localpath"; return 0
  fi

  # existing plain symlink pointing elsewhere
  if [ -L "$localpath" ]; then
    warn "$ln is a symlink to '$(readlink "$localpath")'; leaving it. Remove manually if you want it repointed."
    return 0
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

relocate_dir() {
  local src="$1" dst="$2" stamp aside copier
  stamp="$(date +%Y%m%d-%H%M%S)"
  aside="${src}.pre-offload-${stamp}"
  if command -v rsync >/dev/null 2>&1; then copier="rsync -a"; else copier="cp -a"; fi
  log "RELOCATE  $src  ->  $dst   (copier: $copier)"
  warn "Large dirs (e.g. a 100k-track Music library) can take a long time and a lot of cloud quota."
  run mkdir -p "$dst"
  if [ "$copier" = "rsync -a" ]; then run rsync -a "$src/" "$dst/"
  else run cp -a "$src/." "$dst/"; fi
  run mv "$src" "$aside"
  run ln -s "$dst" "$src"
  info "Original preserved at: $aside  (delete once you've verified the cloud copy)."
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
      cn="$(cloud_name "$(field "$line" 1)")"
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
  desktop   XDG_DESKTOP_DIR   ~/Desktop            -> $CLOUD_ROOT/$(cloud_name desktop)
  documents XDG_DOCUMENTS_DIR ~/Documents          -> $CLOUD_ROOT/$(cloud_name documents)
  downloads XDG_DOWNLOAD_DIR  ~/Downloads          -> create-only (triage)
  music     XDG_MUSIC_DIR     ~/Music              -> $CLOUD_ROOT/$(cloud_name music)
  pictures  XDG_PICTURES_DIR  ~/Pictures           -> $CLOUD_ROOT/$(cloud_name pictures)
  videos    XDG_VIDEOS_DIR    ~/Movies (mac)       -> $CLOUD_ROOT/$(cloud_name videos)
  public    XDG_PUBLICSHARE   ~/Public             -> $CLOUD_ROOT/$(cloud_name public)
  templates XDG_TEMPLATES_DIR ~/Templates          -> $CLOUD_ROOT/$(cloud_name templates)
  projects  (convention)      ~/Projects           -> $CLOUD_ROOT/$(cloud_name projects)

System root dirs (/ /usr /etc /var /opt /Applications /System /Library):
  machine-managed — NOT offloadable. Excluded by design.
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  resolve_cloud_root
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
