#!/usr/bin/env bash
#
# smoke.sh — smoke checks for the xdg-cloud toolkit.
#
# Coverage (smoke + idempotency, per ADR §10):
#   * Both scripts start and complete their default dry-run cleanly.
#   * cloud-xdg-provision.sh --apply is exercised in a sandboxed HOME, and
#     re-running --apply is asserted idempotent (ADR §10 #3).
# The remaining mutating paths (relocate_dir, write_user_dirs on Linux,
# home-tree.sh sync/bisync against real rclone) remain TEST-phase targets.
#
# Safety + correctness rules baked in:
#   * Scoped to tests/sandbox/ — nothing touches the real $HOME. Apply-mode
#     additionally overrides HOME to a sandbox dir, because the provision script
#     resolves local paths as $HOME/<name>; --cloud-root only redirects the
#     CLOUD side, so HOME must be sandboxed before any --apply run.
#   * TMPDIR redirected into the sandbox so home-tree.sh's rclone filter is
#     written there, not in the real /tmp or the repo.
#   * CAPTURE-then-INSPECT, never pipe script output through grep -q/head:
#     a closed pipe makes the script receive SIGPIPE and exit 141, which with
#     `set -o pipefail` would spuriously fail the test (ADR §10 / PREPARE §2.2).
#   * Runs under /bin/bash to exercise the macOS bash 3.2 code path.
#
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "${here}/.." && pwd)"
sandbox="${repo}/tests/sandbox/smoke.$$"
cloud_root="${sandbox}/cloud"
home_root="${sandbox}/home"

mkdir -p "${cloud_root}" "${home_root}" "${sandbox}/tmp"
export TMPDIR="${sandbox}/tmp"

cleanup() { rm -rf "${sandbox}"; }
trap cleanup EXIT

# assert_contains HAYSTACK NEEDLE LABEL
assert_contains() {
  case "$1" in
    *"$2"*) printf '  ok: %s\n' "$3" ;;
    *) printf 'FAIL: %s (expected to find "%s")\n' "$3" "$2" >&2; exit 1 ;;
  esac
}

echo "smoke: cloud-xdg-provision.sh dry-run"
out="$(/bin/bash "${repo}/bin/cloud-xdg-provision.sh" --cloud-root "${cloud_root}" 2>&1)"
assert_contains "${out}" "DRY-RUN" "cloud-xdg-provision.sh reports DRY-RUN and exits 0"

echo "smoke: home-tree.sh dry-run"
out="$(/bin/bash "${repo}/bin/home-tree.sh" --root "${home_root}" 2>&1)"
assert_contains "${out}" "DRY-RUN" "home-tree.sh reports DRY-RUN and exits 0"

# ---------------------------------------------------------------------------
# Apply-mode idempotency (ADR §10 #3) — cloud-xdg-provision.sh only.
#
# HOME is overridden to a sandbox dir so the local symlinks the script creates
# ($HOME/Documents, …) land in the sandbox, never the real home. A clean,
# empty sandbox HOME has no dangling symlinks, so a correct run exits 0; under
# `set -euo pipefail` a non-zero exit (e.g. the dangling-symlink abort) would
# fail the capture below loudly — which is exactly the regression guard we want.
# ---------------------------------------------------------------------------
echo "smoke: cloud-xdg-provision.sh --apply (idempotency, sandboxed HOME)"
apply_home="${sandbox}/apply-home"
apply_cloud="${sandbox}/apply-cloud"
mkdir -p "${apply_home}" "${apply_cloud}"

out="$(HOME="${apply_home}" /bin/bash "${repo}/bin/cloud-xdg-provision.sh" \
  --cloud-root "${apply_cloud}" --apply 2>&1)"
assert_contains "${out}" "mode=APPLY" "first --apply runs in APPLY mode and exits 0"

# Representative symlink must now exist and resolve into the cloud root.
if [ -L "${apply_home}/Documents" ] &&
   [ "$(readlink "${apply_home}/Documents")" = "${apply_cloud}/documents" ]; then
  printf '  ok: %s\n' "Documents -> ${apply_cloud}/documents created on first --apply"
else
  printf 'FAIL: %s\n' "Documents was not symlinked into the cloud root on --apply" >&2
  exit 1
fi

# Second --apply must be idempotent: exit 0 and report the existing link as ok.
out2="$(HOME="${apply_home}" /bin/bash "${repo}/bin/cloud-xdg-provision.sh" \
  --cloud-root "${apply_cloud}" --apply 2>&1)"
assert_contains "${out2}" "ok: Documents -> ${apply_cloud}/documents" \
  "second --apply is idempotent (Documents already ok)"

# …and the symlink must be unchanged after the second run.
if [ "$(readlink "${apply_home}/Documents")" = "${apply_cloud}/documents" ]; then
  printf '  ok: %s\n' "Documents symlink unchanged after second --apply"
else
  printf 'FAIL: %s\n' "Documents symlink changed on second --apply (not idempotent)" >&2
  exit 1
fi

# home-tree.sh apply-mode needs rclone (sync/bisync) — not available in CI.
echo "smoke: home-tree.sh --apply — SKIPPED (requires rclone; not installed)"

echo "smoke: PASS"
