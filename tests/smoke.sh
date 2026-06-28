#!/usr/bin/env bash
#
# smoke.sh — smoke checks for the xdg-cloud toolkit.
#
# Coverage (smoke + idempotency + B6 regression, per ADR §10 and the PR review):
#   * Both scripts start and complete their default dry-run cleanly.
#   * cloud-xdg-provision.sh --apply is exercised in a sandboxed HOME, and
#     re-running --apply is asserted idempotent (ADR §10 #3).
#   * B6 regression group covers the safety-critical branches the review flagged
#     (populated-dir guard, dangling-symlink guard, relocate happy path) plus the
#     B1–B5 fixes (cloud-root absolutization, mount-liveness refusal, clobber
#     refusal) and home-tree.sh's rclone filter + CLI error paths.
# Still TEST-phase targets: write_user_dirs on Linux, the macOS-TCC failure path
# (B2 — needs real TCC), and home-tree.sh sync/bisync against real rclone.
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

# assert_not_contains HAYSTACK NEEDLE LABEL — fails if NEEDLE is present.
assert_not_contains() {
  case "$1" in
    *"$2"*) printf 'FAIL: %s (did NOT expect to find "%s")\n' "$3" "$2" >&2; exit 1 ;;
    *) printf '  ok: %s\n' "$3" ;;
  esac
}

# assert_nonzero RC LABEL — fails if RC is 0 (used for error-path / guard tests).
assert_nonzero() {
  if [ "$1" -ne 0 ]; then
    printf '  ok: %s (exit %s)\n' "$2" "$1"
  else
    printf 'FAIL: %s (expected non-zero exit, got 0)\n' "$2" >&2; exit 1
  fi
}

ok()   { printf '  ok: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# pass_if RC OK_MSG FAIL_MSG — RC of 0 prints OK_MSG, anything else fails the suite.
# (if/then/else, not `A && B || C`, so a printf in B can't accidentally trigger C.)
pass_if() {
  if [ "$1" -eq 0 ]; then ok "$2"; else fail "$3"; fi
}

echo "smoke: cloud-xdg-provision.sh dry-run"
out="$(/bin/bash "${repo}/bin/cloud-xdg-provision.sh" --cloud-root "${cloud_root}" 2>&1)"
# Assert the specific banner line (proves the script reached main() and detected
# its mode) — not merely that "DRY-RUN" appears somewhere an error could echo it.
assert_contains "${out}" "platform=" "cloud-xdg-provision.sh prints its platform/mode banner"
assert_contains "${out}" "mode=DRY-RUN" "cloud-xdg-provision.sh banner reports DRY-RUN mode"

echo "smoke: home-tree.sh dry-run"
out="$(/bin/bash "${repo}/bin/home-tree.sh" --root "${home_root}" 2>&1)"
assert_contains "${out}" "platform:" "home-tree.sh prints its platform/mode banner"
assert_contains "${out}" "mode: DRY-RUN" "home-tree.sh banner reports DRY-RUN mode"

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

# --allow-local-root: the sandbox cloud root is a deliberate plain local dir, so
# the B4 mount-liveness guard must be overridden here (that guard refuses a
# non-cloud root in apply mode by design).
out="$(HOME="${apply_home}" /bin/bash "${repo}/bin/cloud-xdg-provision.sh" \
  --cloud-root "${apply_cloud}" --apply --allow-local-root 2>&1)"
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
  --cloud-root "${apply_cloud}" --apply --allow-local-root 2>&1)"
assert_contains "${out2}" "ok: Documents -> ${apply_cloud}/documents" \
  "second --apply is idempotent (Documents already ok)"

# …and the symlink must be unchanged after the second run.
if [ "$(readlink "${apply_home}/Documents")" = "${apply_cloud}/documents" ]; then
  printf '  ok: %s\n' "Documents symlink unchanged after second --apply"
else
  printf 'FAIL: %s\n' "Documents symlink changed on second --apply (not idempotent)" >&2
  exit 1
fi

# ===========================================================================
# B6 regression tests — the safety-critical branches the PR review (BLOCKING-1/2/3)
# flagged as uncovered, plus the new B1–B5 guards devops added. Each group uses its
# OWN sandbox HOME/cloud pair (all under ${sandbox}, removed by the EXIT trap) so
# groups never share state. --allow-local-root is passed on every --apply/--relocate
# run because the sandbox cloud root is a plain local dir and the B4 mount-liveness
# guard refuses a non-cloud root in apply mode by design.
# ===========================================================================
PROV="${repo}/bin/cloud-xdg-provision.sh"

# --- Group 1: populated dir WITHOUT --relocate is left untouched (review BLOCKING-1;
#     cloud-xdg-provision.sh:316). This is the guard that stands between a user who
#     forgot --relocate and their data being moved. ---
echo "smoke: guard — populated dir without --relocate is left untouched"
g1h="${sandbox}/g1-home"; g1c="${sandbox}/g1-cloud"
mkdir -p "${g1h}/Documents" "${g1c}"
printf 'keep me\n' > "${g1h}/Documents/important.txt"
out="$(HOME="${g1h}" /bin/bash "${PROV}" --cloud-root "${g1c}" --apply --allow-local-root 2>&1)"
assert_contains "${out}" "has contents and is NOT a symlink" "populated dir is reported, not migrated"
if [ -d "${g1h}/Documents" ] && [ ! -L "${g1h}/Documents" ] && [ -f "${g1h}/Documents/important.txt" ]; then
  ok "Documents is still a real dir with its content intact"
else
  fail "Documents was altered despite running without --relocate"
fi

# --- Group 2: dangling/foreign symlink left untouched AND the run still exits 0
#     (regression guard for commit 0761877; cloud-xdg-provision.sh:303). A clean
#     empty HOME can never produce this state — the old smoke test could not cover it. ---
echo "smoke: guard — dangling symlink left untouched, run still exits 0 (regr. 0761877)"
g2h="${sandbox}/g2-home"; g2c="${sandbox}/g2-cloud"
mkdir -p "${g2h}" "${g2c}"
ln -s "${sandbox}/does-not-exist" "${g2h}/Desktop"
set +e
out="$(HOME="${g2h}" /bin/bash "${PROV}" --cloud-root "${g2c}" --apply --allow-local-root 2>&1)"
rc=$?
set -e
pass_if "${rc}" "apply exits 0 despite a dangling symlink" \
  "apply aborted (exit ${rc}) on a dangling symlink — 0761877 regressed"
assert_contains "${out}" "is a symlink to" "dangling symlink is reported and left in place"
if [ -L "${g2h}/Desktop" ] && [ "$(readlink "${g2h}/Desktop")" = "${sandbox}/does-not-exist" ]; then
  ok "dangling Desktop symlink is unchanged"
else
  fail "dangling Desktop symlink was modified"
fi

# --- Group 3: relocate happy path (review BLOCKING-2; cloud-xdg-provision.sh:367).
#     The actual user-data migration: copy -> verify -> mv aside -> symlink. ---
echo "smoke: relocate — populated dir migrated, verified, symlinked, aside kept"
g3h="${sandbox}/g3-home"; g3c="${sandbox}/g3-cloud"
mkdir -p "${g3h}/Music/sub" "${g3c}"
printf 'track\n'  > "${g3h}/Music/a.mp3"
printf 'nested\n' > "${g3h}/Music/sub/n.mp3"
printf 'dot\n'    > "${g3h}/Music/.hidden"   # dotfile: cp -a/rsync must carry it
set +e
out="$(HOME="${g3h}" /bin/bash "${PROV}" --cloud-root "${g3c}" --apply --relocate --allow-local-root 2>&1)"
rc=$?
set -e
pass_if "${rc}" "relocate run exits 0" "relocate run failed (exit ${rc}): ${out}"
if [ -L "${g3h}/Music" ] && [ "$(readlink "${g3h}/Music")" = "${g3c}/music" ]; then
  ok "Music is now a symlink into the cloud root"
else
  fail "Music was not symlinked into the cloud root after relocate"
fi
if [ -f "${g3c}/music/a.mp3" ] && [ -f "${g3c}/music/sub/n.mp3" ] && [ -f "${g3c}/music/.hidden" ]; then
  ok "all files (incl nested + dotfile) were copied into the cloud"
else
  fail "relocate did not copy all files (nested/dotfile) into the cloud"
fi
if ls -d "${g3h}"/Music.pre-offload-* >/dev/null 2>&1; then
  ok "original preserved in a *.pre-offload-* aside dir"
else
  fail "no *.pre-offload-* aside dir was created"
fi
assert_contains "${out}" "Original kept at:" "relocate reports where the original was kept"
assert_not_contains "${out}" "delete once you've verified" \
  "stale 'delete once you've verified' wording is gone (B3 verify-before-delete)"

# --- Group 4: B1 — a RELATIVE --cloud-root is absolutized so the symlink is not
#     dangling (cloud-xdg-provision.sh:169 normalize_cloud_root). Run from a known
#     CWD; the relative path must resolve against it into an absolute, live link. ---
echo "smoke: B1 — relative --cloud-root is absolutized (no dangling symlink)"
g4h="${sandbox}/g4-home"; g4w="${sandbox}/g4-workdir"
mkdir -p "${g4h}" "${g4w}"
set +e
out="$( cd "${g4w}" && HOME="${g4h}" /bin/bash "${PROV}" --cloud-root "relcloud" --apply --allow-local-root 2>&1 )"
rc=$?
set -e
pass_if "${rc}" "relative --cloud-root run exits 0" \
  "relative --cloud-root run failed (exit ${rc})"
tgt="$(readlink "${g4h}/Documents")"
case "${tgt}" in
  /*) ok "Documents symlink target is absolute (${tgt})" ;;
  *)  fail "Documents symlink target is NOT absolute: ${tgt}" ;;
esac
# -e dereferences the symlink: true only if the target actually resolves (not dangling).
if [ -e "${g4h}/Documents" ]; then
  ok "absolutized symlink resolves (not dangling)"
else
  fail "symlink built from a relative --cloud-root is dangling"
fi

# --- Group 5: B5 — relocate refuses a NON-EMPTY cloud destination, leaving both the
#     local original and the (possibly other-machine) cloud data untouched
#     (cloud-xdg-provision.sh:377). ---
echo "smoke: B5 — relocate refuses a non-empty cloud destination (no clobber)"
g5h="${sandbox}/g5-home"; g5c="${sandbox}/g5-cloud"
mkdir -p "${g5h}/Documents" "${g5c}/documents"
printf 'local original\n'      > "${g5h}/Documents/orig.txt"
printf 'from another machine\n' > "${g5c}/documents/remote.txt"
set +e
out="$(HOME="${g5h}" /bin/bash "${PROV}" --cloud-root "${g5c}" --apply --relocate --allow-local-root 2>&1)"
rc=$?
set -e
pass_if "${rc}" "clobber-guard run exits 0 (refuses cleanly, does not abort)" \
  "run failed (exit ${rc}) instead of refusing cleanly"
assert_contains "${out}" "cloud destination is not empty" "non-empty cloud destination is reported"
if [ -d "${g5h}/Documents" ] && [ ! -L "${g5h}/Documents" ] && [ -f "${g5h}/Documents/orig.txt" ]; then
  ok "local original left untouched (still a real dir)"
else
  fail "local original was modified despite the clobber guard"
fi
if ls -d "${g5h}"/Documents.pre-offload-* >/dev/null 2>&1; then
  fail "an aside dir was created even though migration was refused"
else
  ok "no *.pre-offload-* aside created (nothing was moved)"
fi
if [ -f "${g5c}/documents/remote.txt" ]; then
  ok "pre-existing cloud file preserved"
else
  fail "pre-existing cloud file was lost"
fi

# --- Group B4: mount-liveness guard refuses a non-live root in apply mode, but only
#     WARNS in dry-run so a plan can still be previewed (cloud-xdg-provision.sh:215). ---
echo "smoke: B4 — apply refuses a non-live cloud root without --allow-local-root"
g6h="${sandbox}/g6-home"; g6c="${sandbox}/g6-cloud"
mkdir -p "${g6h}" "${g6c}"
set +e
out="$(HOME="${g6h}" /bin/bash "${PROV}" --cloud-root "${g6c}" --apply 2>&1)"   # no --allow-local-root
rc=$?
set -e
assert_nonzero "${rc}" "apply against a plain local dir is rejected (B4)"
assert_contains "${out}" "does not look like a live cloud mount" "B4 explains why the root was rejected"
set +e
out="$(HOME="${g6h}" /bin/bash "${PROV}" --cloud-root "${g6c}" 2>&1)"           # dry-run, no flag
rc=$?
set -e
pass_if "${rc}" "dry-run still previews a non-live root (exit 0)" \
  "dry-run wrongly aborted on a non-live root"
assert_contains "${out}" "does not look like a live cloud mount" "dry-run warns about the non-live root"

# --- B2 (macOS TCC pre-flight): SKIPPED.
#     Rationale: the failure path needs an UNRENAMEABLE source dir. The only sandbox
#     analogue is a read-only $HOME, but that also makes ensure_local_base's
#     `mkdir -p $HOME/.config` fail, aborting under set -e before relocate_dir runs —
#     so it cannot be reproduced faithfully here. The probe-SUCCESS path is exercised
#     by the relocate group above; the failure path stays a real-macOS TEST target. ---
echo "smoke: B2 macOS TCC pre-flight — SKIPPED (failure path needs real TCC / read-only HOME)"

# --- Group 6: home-tree.sh rclone filter is the single source of truth for what may
#     reach the cloud (review BLOCKING-3; home-tree.sh:153). A dropped deny line would
#     leak SQLite/secrets. Inspect the generated filter directly — no rclone needed. ---
echo "smoke: home-tree.sh — generated rclone filter denies danger + allows the safe set"
g7root="${sandbox}/g7-home"; mkdir -p "${g7root}"
out="$(/bin/bash "${repo}/bin/home-tree.sh" --root "${g7root}" 2>&1)"
filter="${TMPDIR}/home-tree.rclone-filter"
if [ -f "${filter}" ]; then
  ok "filter file was written to TMPDIR"
else
  fail "home-tree did not write its rclone filter"
fi
fcontent="$(cat "${filter}")"
assert_contains "${fcontent}" "- **/*.sqlite" "filter denies SQLite (FUSE-lock-sensitive)"
assert_contains "${fcontent}" "- **/.git/**"  "filter denies .git"
assert_contains "${fcontent}" "- /Cache/**"   "filter denies Cache"
assert_contains "${fcontent}" "- /Downloads/**" "filter denies Downloads"
assert_contains "${fcontent}" "+ /Documents/**" "filter allows Documents"
assert_contains "${fcontent}" "+ /Projects/**"  "filter allows Projects"
assert_contains "${fcontent}" "- *" "filter ends with a catch-all deny (defense in depth)"

# --- Group 7: CLI error paths exit non-zero (review MINOR-3). set -euo pipefail means
#     a silent acceptance of bad input would be a real defect. ---
echo "smoke: error paths — invalid input exits non-zero"
set +e; out="$(/bin/bash "${PROV}" --style bogus 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "--style bogus exits non-zero"
assert_contains "${out}" "invalid --style" "--style bogus names the bad value"
set +e; out="$(/bin/bash "${PROV}" --frobnicate 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "unknown option exits non-zero"
assert_contains "${out}" "unknown option" "unknown option is named"
set +e; out="$(/bin/bash "${PROV}" --cloud-root 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "--cloud-root with no value exits non-zero"
set +e; out="$(/bin/bash "${PROV}" --style 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "--style with no value exits non-zero"

# --- Group 8: home-tree.sh --apply --sync against a LOCAL rclone remote (no real
#     cloud) now that rclone is installed. This validates the rclone filter END TO
#     END with the real binary: the safe set reaches the remote while SQLite and the
#     NEVER dirs are denied (the data-leak failure mode the filter exists to stop).
#     Skipped only if rclone is genuinely absent. ---
if command -v rclone >/dev/null 2>&1; then
  echo "smoke: home-tree.sh --apply --sync (local rclone remote, sandboxed)"
  ht_home="${sandbox}/ht-home"; ht_dest="${sandbox}/ht-dest"; ht_arch="${sandbox}/ht-arch"
  mkdir -p "${ht_home}/Documents" "${ht_home}/Pictures" "${ht_home}/Cache" "${ht_dest}"
  printf 'doc\n'  > "${ht_home}/Documents/report.txt"
  printf 'pic\n'  > "${ht_home}/Pictures/photo.txt"
  printf 'db\n'   > "${ht_home}/Documents/app.sqlite"   # MUST be denied (lock-sensitive)
  printf 'junk\n' > "${ht_home}/Cache/tmp.bin"          # MUST be denied (NEVER dir)
  # A local-backend rclone remote pointed at the sandbox — require_rclone sees it
  # via RCLONE_CONFIG; --dest is an absolute path so testremote:<path> stays in-sandbox.
  ht_conf="${sandbox}/rclone.conf"
  printf '[testremote]\ntype = local\n' > "${ht_conf}"
  set +e
  out="$(RCLONE_CONFIG="${ht_conf}" ARCHIVE_SUBDIR="${ht_arch}" \
    /bin/bash "${repo}/bin/home-tree.sh" --root "${ht_home}" --remote testremote \
    --dest "${ht_dest}" --apply --sync 2>&1)"
  rc=$?
  set -e
  pass_if "${rc}" "home-tree --apply --sync exits 0 against a local remote" \
    "home-tree --apply --sync failed (exit ${rc}): ${out}"
  assert_contains "${out}" "mode: APPLY" "home-tree reports APPLY mode"
  if [ -f "${ht_dest}/Documents/report.txt" ] && [ -f "${ht_dest}/Pictures/photo.txt" ]; then
    ok "safe files (Documents, Pictures) reached the remote"
  else
    fail "home-tree --sync did not copy the safe files to the remote"
  fi
  if [ -e "${ht_dest}/Documents/app.sqlite" ]; then
    fail "SECURITY: *.sqlite leaked to the remote despite the filter"
  else
    ok "filter kept *.sqlite out of the remote"
  fi
  if [ -e "${ht_dest}/Cache" ]; then
    fail "Cache/ leaked to the remote despite the filter"
  else
    ok "filter kept Cache/ out of the remote"
  fi
else
  echo "smoke: home-tree.sh --apply --sync — SKIPPED (rclone not installed)"
fi

echo "smoke: PASS"
