# shellcheck shell=bash
#
# xdg-common.sh — shared plumbing for cloud-xdg-provision.sh and home-tree.sh.
#
# SOURCED, never executed (no shebang). It is DECLARATIONS-ONLY: function
# definitions, plain assignments, and the ': "${VAR:=default}"' idiom only —
# all of which return 0 — so sourcing it under the callers' `set -euo pipefail`
# can never abort them (see architecture §4.3). Do NOT add any top-level command
# that can return non-zero (no grep, `[ … ]` tests, `command -v`, etc.) here.
#
# Compatible with stock macOS bash 3.2 (no associative arrays / mapfile / <()).
#
# Contents: logging helpers, the `field` pipe-splitter, platform detection, the
# XDG base-dir defaults, SELF, the ONE canonical directory registry, the two
# per-tool membership/order key lists, and the registry lookup/selection helpers.

# ---------------------------------------------------------------------------
# Logging (byte-identical between both scripts before the refactor)
# ---------------------------------------------------------------------------
log()  { printf '%s\n' "$*"; }
info() { printf '  • %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Field splitter (3.2-safe; no here-strings on assoc arrays)
#   $1 = a 'a|b|c'-style row, $2 = 1-based field index.
# ---------------------------------------------------------------------------
field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

# ---------------------------------------------------------------------------
# Platform detection — sets the global PLATFORM (macos|linux|termux|unknown).
# Same logic and same PLATFORM output both scripts used before the refactor.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034   # PLATFORM is read by the sourcing scripts, not here
detect_platform() {
  case "$(uname -s)" in
    Darwin) PLATFORM=macos ;;
    Linux)
      if [ -n "${TERMUX_VERSION:-}" ] || [ -d /data/data/com.termux ]; then
        PLATFORM=termux
      else
        PLATFORM=linux
      fi ;;
    *) PLATFORM=unknown ;;
  esac
}

# ---------------------------------------------------------------------------
# XDG base-dir defaults — populate the four globals from env or spec defaults.
# No `local`, so the assignments land in the global scope. Call once at top
# level right after sourcing, mirroring each script's old load-time block.
# ---------------------------------------------------------------------------
xdg_init_base_defaults() {
  : "${XDG_CONFIG_HOME:=$HOME/.config}"
  : "${XDG_DATA_HOME:=$HOME/.local/share}"
  : "${XDG_STATE_HOME:=$HOME/.local/state}"
  : "${XDG_CACHE_HOME:=$HOME/.cache}"
}

# Basename of the executed script. `$0` is the EXECUTED script's path and is
# unchanged when this lib is `.`-sourced, so SELF resolves exactly as before.
# shellcheck disable=SC2034   # SELF is read by the sourcing scripts, not here
SELF="$(basename "$0")"

# ---------------------------------------------------------------------------
# The ONE canonical directory registry.
#   Schema:  canonical|macName|linuxName|xdgVar|redirect
#     canonical : folder name created in the cloud root (style applied)
#     macName   : the dir under $HOME on macOS (Apple naming, e.g. Movies)
#     linuxName : the dir under $HOME on Linux (XDG default naming)
#     xdgVar    : the user-dirs.dirs variable to write (empty = none)
#     redirect  : 1 = eligible to symlink local->cloud, 0 = create only
# Superset of both tools' sets: cloud-xdg's 9 dirs in cloud-xdg's order, with
# the home-tree-only `notes` row appended.
# ---------------------------------------------------------------------------
XDG_DIR_REGISTRY="
desktop|Desktop|Desktop|XDG_DESKTOP_DIR|1
documents|Documents|Documents|XDG_DOCUMENTS_DIR|1
downloads|Downloads|Downloads|XDG_DOWNLOAD_DIR|1
music|Music|Music|XDG_MUSIC_DIR|1
pictures|Pictures|Pictures|XDG_PICTURES_DIR|1
videos|Movies|Videos|XDG_VIDEOS_DIR|1
public|Public|Public|XDG_PUBLICSHARE_DIR|1
templates|Templates|Templates|XDG_TEMPLATES_DIR|1
projects|Projects|Projects||1
notes|Notes|Notes||1
"
# Note on the 'projects' row above: it is CODE-classified for cloud-xdg (P2, see
# HOME_CLASS_REGISTRY below) and is NOT in CLOUDXDG_KEYS, so it no longer enters
# OFFLOAD_SET / the symlink lane. The row REMAINS because home-tree.sh (frozen) still
# lists 'projects' in HOMETREE_KEYS and derives SAFE_DIRS from this row's linuxName
# (field 3); the section-6 rclone-filter '+ /Projects/**' coupling depends on it.
# (This comment lives OUTSIDE the registry string on purpose: a '#' line inside the
# double-quoted value would be string DATA, and backticks there would run as command
# substitution at source time — violating the declarations-only source-safety rule.)

# Each tool manages a DIFFERENT subset in a DIFFERENT order — deliberate
# divergence (not duplication). cloud-xdg keeps Music before Pictures;
# home-tree keeps Pictures before Music. Each iterates its OWN ordered list.
CLOUDXDG_KEYS="desktop documents downloads music pictures videos public templates"
#
# ⚠️ COUPLING INVARIANT (architecture §6): the registry `linuxName` (field 3)
# for every HOMETREE_KEYS entry MUST stay equal to the matching allow-path name
# in home-tree's hardcoded rclone filter (write_filter):
#     + /Documents/**  + /Pictures/**  + /Music/**  + /Videos/**  + /Notes/**  + /Projects/**
# home-tree derives the folders it CREATES from these linuxNames; the rclone
# filter is the single source of truth for what may reach the cloud and is NOT
# derived from the registry. If a future edit renames a linuxName here without
# changing the filter (or vice-versa), home-tree would create a folder the
# filter no longer allows → silent backup gap / data-leak surface. Keep the two
# in lockstep; the §7 filter golden check guards it.
# shellcheck disable=SC2034   # HOMETREE_KEYS is read by home-tree.sh, not here
HOMETREE_KEYS="documents pictures music videos projects notes"

# ---------------------------------------------------------------------------
# Registry lookup + selection
# ---------------------------------------------------------------------------
# Echo the registry row for a canonical key (or nothing). First match wins.
registry_row() {
  printf '%s\n' "$XDG_DIR_REGISTRY" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      "$1|"*) printf '%s\n' "$line"; break ;;
    esac
  done
}

# Emit cloud-xdg's offload set: the rows for CLOUDXDG_KEYS, in that order.
# Reproduces the old literal OFFLOAD_SET line-for-line.
xdg_offload_set() {
  local k
  # shellcheck disable=SC2086   # intentional word-split of the space-separated key list
  for k in $CLOUDXDG_KEYS; do registry_row "$k"; done
}

# ---------------------------------------------------------------------------
# Home-dir classification registry (slice 1) — classes OUTSIDE the XDG-symlink lane.
#   code  : git-managed dirs eligible for rclone offload-on-demand (offloadable=1)
#   local : machine-local dirs that must NEVER offload or symlink (offloadable=0)
#   Schema:  canonical|macName|linuxName|class|offloadable
# SEPARATE from XDG_DIR_REGISTRY by design so xdg_offload_set() + smoke L3 stay
# byte-identical (except the deliberate P2 removal of `projects` from CLOUDXDG_KEYS).
# `projects` is listed here as code AND remains an XDG_DIR_REGISTRY row (home-tree needs
# that row — see the projects row above). home_class() resolves the overlap to `code`.
# ---------------------------------------------------------------------------
HOME_CLASS_REGISTRY="
repos|repos|repos|code|1
androidstudio|AndroidStudioProjects|AndroidStudioProjects|code|1
projects|Projects|Projects|code|1
pyenv|pyenv|pyenv|local|0
applications|Applications|Applications|local|0
syslog|log|log|local|0
qemu|QEMU|QEMU|local|0
"

# Membership + order per new lane (explicit, like CLOUDXDG_KEYS — not registry-scanned).
# shellcheck disable=SC2034   # CODE_KEYS/LOCAL_KEYS are read by cloud-xdg-provision.sh, not here
CODE_KEYS="repos androidstudio projects"
# shellcheck disable=SC2034   # see above
LOCAL_KEYS="pyenv applications syslog qemu"

# Echo the HOME_CLASS_REGISTRY row for a canonical key (or nothing). First match wins.
# Exact structural mirror of registry_row() — proven safe to call inside $( … ).
code_row() {
  printf '%s\n' "$HOME_CLASS_REGISTRY" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      "$1|"*) printf '%s\n' "$line"; break ;;
    esac
  done
}

# Class for ANY canonical key: code|local from HOME_CLASS_REGISTRY (checked FIRST so
# `projects` resolves to code), else xdg if it is an XDG_DIR_REGISTRY row, else unknown.
home_class() {
  local cr xr
  cr="$(code_row "$1")"
  if [ -n "$cr" ]; then field "$cr" 4; return 0; fi
  xr="$(registry_row "$1")"
  if [ -n "$xr" ]; then printf '%s' "xdg"; return 0; fi
  printf '%s' "unknown"
}

# Predicates (for use in `if`; SC2310 is disabled repo-wide in .shellcheckrc).
is_machine_local() { [ "$(home_class "$1")" = "local" ]; }
is_code_dir()      { [ "$(home_class "$1")" = "code" ]; }

# Parameterized rclone-remote precondition (offload lane, later slice). Each script
# wraps it with its own config var + message — do NOT byte-copy home-tree's
# require_rclone (divergent message; dedup rule). True (0) iff rclone present AND a
# remote named "$1" is configured. Body runs only when CALLED (not at source time).
rclone_remote_exists() {
  command -v rclone >/dev/null 2>&1 || return 1
  rclone listremotes 2>/dev/null | grep -qx "$1:"
}
