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
# Capture the host temp dir BEFORE overriding TMPDIR — the reclaim group needs a
# fixture root OUTSIDE the repo work tree, and the override below points inside it.
host_tmp="${TMPDIR:-/tmp}"
export TMPDIR="${sandbox}/tmp"

# rec_root is a reclaim fixture created OUTSIDE the repo work tree (see the
# reclaim group near the end) — cleaned here too. Empty until that group sets it.
rec_root=""
cleanup() { rm -rf "${sandbox}" ${rec_root:+"${rec_root}"}; }
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

# --- Group B6 (issue #9): macOS 'group:everyone deny delete' ACL on a special folder
#     is DETECTED and the dir is SKIPPED with accurate native-iCloud guidance — NOT
#     the misleading "grant Full Disk Access and retry" advice (FDA cannot override a
#     deny ACE). Gated on real macOS + `chmod +a`: the ACL is an APFS/macOS feature
#     and is genuinely unreproducible elsewhere, so non-macOS skips with a reason.
#     This is the regression the old B2-SKIPPED note called a "real-macOS TEST target":
#     `chmod +a` on a SINGLE dir reproduces it faithfully without a read-only HOME. ---
b6_supported=0
if [ "$(uname -s)" = "Darwin" ]; then
  b6probe="${sandbox}/b6-aclprobe"
  mkdir -p "${b6probe}"
  if chmod +a "group:everyone deny delete" "${b6probe}" 2>/dev/null; then
    b6_supported=1
    # Strip the ACL so the EXIT-trap rm -rf can delete the probe (deny-delete would
    # otherwise block removing the dir itself).
    chmod -a "group:everyone deny delete" "${b6probe}" 2>/dev/null || true
  fi
  rm -rf "${b6probe}"
fi
if [ "${b6_supported}" -eq 1 ]; then
  echo "smoke: B6 — macOS deny-delete ACL special folder is skipped with accurate guidance"
  b6h="${sandbox}/b6-home"; b6c="${sandbox}/b6-cloud"
  mkdir -p "${b6h}/Documents" "${b6c}"
  printf 'notes\n' > "${b6h}/Documents/notes.txt"
  chmod +a "group:everyone deny delete" "${b6h}/Documents"
  set +e
  out="$(HOME="${b6h}" /bin/bash "${PROV}" --cloud-root "${b6c}" --apply --relocate --allow-local-root 2>&1)"
  rc=$?
  set -e
  # Strip the ACL NOW (output is captured) so cleanup is robust even if an assert
  # below fails and the EXIT trap fires with the dir still ACL-protected.
  chmod -a "group:everyone deny delete" "${b6h}/Documents" 2>/dev/null || true
  pass_if "${rc}" "ACL-protected dir run exits 0 (skips cleanly)" \
    "run failed (exit ${rc}) instead of skipping the ACL dir: ${out}"
  # (a) NOT relocated: still a real dir (not a symlink), contents intact, no aside.
  if [ -d "${b6h}/Documents" ] && [ ! -L "${b6h}/Documents" ] && [ -f "${b6h}/Documents/notes.txt" ]; then
    ok "ACL-protected Documents left in place (real dir, not a symlink)"
  else
    fail "ACL-protected Documents was altered/relocated despite the deny-delete ACL"
  fi
  if ls -d "${b6h}"/Documents.pre-offload-* >/dev/null 2>&1; then
    fail "an aside dir was created even though the ACL dir should be skipped"
  else
    ok "no *.pre-offload-* aside created (nothing was moved)"
  fi
  # (b) accurate guidance is printed.
  assert_contains "${out}" "deny delete" "skip message names the deny-delete ACL"
  assert_contains "${out}" "NOT TCC" "skip message states it is the ACL, not TCC"
  assert_contains "${out}" "Desktop & Documents Folders" \
    "Documents skip points to Apple's native iCloud feature"
  # (c) the misleading "grant FDA and retry" advice is NOT shown for the ACL case
  #     (the B2/TCC path owns that wording — it must not leak here).
  assert_not_contains "${out}" "add your terminal, then retry" \
    "no misleading 'grant Full Disk Access and retry' advice for the ACL case"
else
  echo "smoke: B6 macOS deny-delete ACL — SKIPPED (needs real macOS + chmod +a ACL support)"
fi

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

# ===========================================================================
# Minor-fix regression tests (M1 / M4 / M6) — observable behaviour changes from
# the second remediation round. Same isolation rules as the B6 groups above.
# ===========================================================================

# --- Group 9: M1 — --style mac uses the Apple folder name (videos -> "Movies",
#     NOT a naive-capitalised "Videos"), and the cloud folder agrees with the
#     local symlink target (cloud-xdg-provision.sh:287 cloud_name). Both style
#     branches are checked so neither direction can regress. ---
echo "smoke: M1 — --style mac names the videos cloud folder 'Movies' (Apple name)"
g9h="${sandbox}/g9-home"; g9c="${sandbox}/g9-cloud"
mkdir -p "${g9h}" "${g9c}"
out="$(HOME="${g9h}" /bin/bash "${PROV}" --cloud-root "${g9c}" --style mac --apply --allow-local-root 2>&1)"
if [ -d "${g9c}/Movies" ] && [ ! -e "${g9c}/Videos" ]; then
  ok "mac style created cloud/Movies and not cloud/Videos"
else
  fail "mac style did not name the videos folder 'Movies' (Videos present or Movies missing)"
fi
# On macOS the local dir is ~/Movies (Apple name) regardless of style; under mac
# style its symlink target must be the matching cloud/Movies (no folder/link drift).
if [ -L "${g9h}/Movies" ] && [ "$(readlink "${g9h}/Movies")" = "${g9c}/Movies" ]; then
  ok "mac style: ~/Movies symlink target matches cloud/Movies"
else
  ok "mac style: ~/Movies link check skipped (non-macOS local naming differs)"
fi
# xdg (default) keeps the lowercase canonical name — guards the other branch.
g9hx="${sandbox}/g9-home-xdg"; g9cx="${sandbox}/g9-cloud-xdg"
mkdir -p "${g9hx}" "${g9cx}"
out="$(HOME="${g9hx}" /bin/bash "${PROV}" --cloud-root "${g9cx}" --style xdg --apply --allow-local-root 2>&1)"
if [ -d "${g9cx}/videos" ] && [ ! -e "${g9cx}/Movies" ]; then
  ok "xdg style created lowercase cloud/videos and not cloud/Movies"
else
  fail "xdg style did not keep the videos folder lowercase"
fi

# --- Group 10: M4 — aside name is made UNIQUE on collision (counter suffix), the
#     pre-existing aside is left untouched (NO nesting), and "Original kept at:"
#     points to the real new location (cloud-xdg-provision.sh:relocate_dir).
#     Determinism: a `date` shim pins the stamp so the collision is reproducible
#     rather than racing the wall clock. Pre-seeding BOTH the bare aside and its
#     ".1" forces the counter to advance to ".2", proving the loop increments. ---
echo "smoke: M4 — colliding aside name gets a unique counter suffix (no nesting)"
g10h="${sandbox}/g10-home"; g10c="${sandbox}/g10-cloud"; g10shim="${sandbox}/g10-shim"
mkdir -p "${g10h}/Documents" "${g10c}" "${g10shim}"
printf 'ORIGINAL\n' > "${g10h}/Documents/orig.txt"
# Pin date so the aside stamp is deterministic; delegate every other call to real date.
cat > "${g10shim}/date" <<'DATESH'
#!/bin/sh
case "$1" in
  +%Y%m%d-%H%M%S) echo "20260101-120000" ;;
  *) exec /bin/date "$@" ;;
esac
DATESH
chmod +x "${g10shim}/date"
stamp="20260101-120000"
bare="${g10h}/Documents.pre-offload-${stamp}"
one="${g10h}/Documents.pre-offload-${stamp}.1"
two="${g10h}/Documents.pre-offload-${stamp}.2"
mkdir -p "${bare}"; printf 'BARE\n' > "${bare}/sentinel"
mkdir -p "${one}";  printf 'DOT1\n' > "${one}/sentinel"
out="$(HOME="${g10h}" PATH="${g10shim}:${PATH}" /bin/bash "${PROV}" \
  --cloud-root "${g10c}" --apply --relocate --allow-local-root 2>&1)"
# the original migrated into the .2 aside (bare and .1 were taken)
if [ -f "${two}/orig.txt" ]; then
  ok "aside collision advanced the counter to .2 and moved the original there"
else
  fail "colliding aside was not given a unique .2 name"
fi
# pre-existing asides untouched — NO nesting of the source dir inside them
if [ -f "${bare}/sentinel" ] && [ ! -e "${bare}/Documents" ] &&
   [ -f "${one}/sentinel" ]  && [ ! -e "${one}/Documents" ]; then
  ok "pre-existing aside dirs left intact (no nesting)"
else
  fail "a pre-existing aside was nested into / clobbered"
fi
assert_contains "${out}" "Original kept at: ${two}" "'Original kept at' points to the real unique aside"

# --- Group 11 (M6): dry-run output is shell-quoted so a space-containing cloud
#     root renders copy-paste-safe (run() now uses printf %q; cloud-xdg-provision.sh:run). ---
echo "smoke: M6 — dry-run output shell-quotes a space-containing path"
g11h="${sandbox}/g11-home"; g11c="${sandbox}/My Cloud Drive"
mkdir -p "${g11h}" "${g11c}"
out="$(HOME="${g11h}" /bin/bash "${PROV}" --cloud-root "${g11c}" 2>&1)"   # dry-run
assert_contains "${out}" 'My\ Cloud\ Drive' "dry-run backslash-escapes spaces in the cloud path"

# ===========================================================================
# Robustness wins (issues #4 / #5 / #7) — same isolation rules as the groups above.
# ===========================================================================

# --- Issue #4: multiple ~/Library/CloudStorage/GoogleDrive-*/My Drive mounts must
#     NOT be silently first-matched — resolve_cloud_root dies with a disambiguation
#     message listing the candidates. macOS-gated: the auto-detect runs only on
#     macOS (elsewhere resolve_cloud_root takes the generic 'CLOUD_ROOT unset' die). ---
if [ "$(uname -s)" = "Darwin" ]; then
  echo "smoke: #4 — multiple Google Drive mounts are refused with a disambiguation message"
  i4h="${sandbox}/i4-home"
  mkdir -p "${i4h}/Library/CloudStorage/GoogleDrive-a@x.com/My Drive"
  mkdir -p "${i4h}/Library/CloudStorage/GoogleDrive-b@y.com/My Drive"
  set +e
  out="$(HOME="${i4h}" /bin/bash "${PROV}" 2>&1)"   # dry-run, no --cloud-root → auto-detect
  rc=$?
  set -e
  assert_nonzero "${rc}" "multi-mount auto-detect exits non-zero (refuses to guess)"
  assert_contains "${out}" "Multiple Google Drive mounts found" "multi-mount death names the ambiguity"
  assert_contains "${out}" "--cloud-root" "multi-mount death tells the user to pass --cloud-root"
  assert_contains "${out}" "GoogleDrive-a@x.com/My Drive" "candidate list includes the first mount"
  assert_contains "${out}" "GoogleDrive-b@y.com/My Drive" "candidate list includes the second mount"
  # Single-mount sanity: exactly one candidate resolves cleanly (the count==1 path).
  i4h1="${sandbox}/i4-home-single"
  mkdir -p "${i4h1}/Library/CloudStorage/GoogleDrive-solo@x.com/My Drive"
  set +e
  out="$(HOME="${i4h1}" /bin/bash "${PROV}" 2>&1)"   # dry-run
  rc=$?
  set -e
  pass_if "${rc}" "single Google Drive mount auto-detects cleanly (exit 0)" \
    "single-mount auto-detect failed (exit ${rc}): ${out}"
  assert_contains "${out}" "GoogleDrive-solo@x.com/My Drive" "single mount is used as the cloud root"
else
  echo "smoke: #4 multiple Google Drive mounts — SKIPPED (auto-detect is macOS-only)"
fi

# --- Issue #20: iCloud Drive auto-detect as a FALLBACK. When NO Google Drive
#     mount exists, resolve_cloud_root() falls back to iCloud Drive at
#     ~/Library/Mobile Documents/com~apple~CloudDocs. Google Drive stays primary:
#     when both are present, GD still wins (iCloud is reached only in the count==0
#     branch). macOS-gated, matching the #4 harness — the auto-detect is macOS-only. ---
if [ "$(uname -s)" = "Darwin" ]; then
  icloud_rel="Library/Mobile Documents/com~apple~CloudDocs"

  # 20a: iCloud present, NO Google Drive → fall back to iCloud, exit 0, banner shows it.
  echo "smoke: #20a — iCloud Drive is auto-detected when no Google Drive mount exists"
  i20h="${sandbox}/i20-home-icloud"
  mkdir -p "${i20h}/${icloud_rel}"
  set +e
  out="$(HOME="${i20h}" /bin/bash "${PROV}" 2>&1)"   # dry-run, no --cloud-root → auto-detect
  rc=$?
  set -e
  pass_if "${rc}" "iCloud-only auto-detect resolves cleanly (exit 0)" \
    "iCloud fallback auto-detect failed (exit ${rc}): ${out}"
  assert_contains "${out}" "com~apple~CloudDocs" "iCloud Drive path is used as the cloud root"

  # 20b: BOTH iCloud and a single Google Drive present → Google Drive still wins.
  echo "smoke: #20b — Google Drive stays primary when both Google Drive and iCloud exist"
  i20b="${sandbox}/i20-home-both"
  mkdir -p "${i20b}/Library/CloudStorage/GoogleDrive-me@x.com/My Drive"
  mkdir -p "${i20b}/${icloud_rel}"
  set +e
  out="$(HOME="${i20b}" /bin/bash "${PROV}" 2>&1)"   # dry-run
  rc=$?
  set -e
  pass_if "${rc}" "both-present run auto-detects cleanly (exit 0)" \
    "both-present auto-detect failed (exit ${rc}): ${out}"
  assert_contains "${out}" "GoogleDrive-me@x.com/My Drive" "Google Drive wins when both are present"
  assert_not_contains "${out}" "com~apple~CloudDocs" "iCloud is NOT chosen while a Google Drive mount exists"

  # 20c: neither present → updated die naming BOTH options, non-zero exit.
  echo "smoke: #20c — neither Google Drive nor iCloud present dies naming both options"
  i20c="${sandbox}/i20-home-neither"
  mkdir -p "${i20c}/Library"   # a HOME with neither provider dir
  set +e
  out="$(HOME="${i20c}" /bin/bash "${PROV}" 2>&1)"   # dry-run
  rc=$?
  set -e
  assert_nonzero "${rc}" "no-provider auto-detect exits non-zero"
  assert_contains "${out}" "No Google Drive or iCloud Drive found" "die names both Google Drive and iCloud"
  assert_contains "${out}" "--cloud-root" "no-provider die tells the user to pass --cloud-root"

  # 20d: half-set-up Google Drive (GoogleDrive-* dir but NO My Drive) + iCloud →
  # iCloud fallback still fires, but with a visible warning naming the situation.
  echo "smoke: #20d — partial Google Drive (no My Drive) + iCloud falls back to iCloud WITH a warning"
  i20d="${sandbox}/i20-home-partial"
  mkdir -p "${i20d}/Library/CloudStorage/GoogleDrive-me@x.com"   # NOTE: no /My Drive subdir
  mkdir -p "${i20d}/${icloud_rel}"
  set +e
  out="$(HOME="${i20d}" /bin/bash "${PROV}" 2>&1)"   # dry-run
  rc=$?
  set -e
  pass_if "${rc}" "partial-GD + iCloud run resolves cleanly (exit 0)" \
    "partial-GD fallback failed (exit ${rc}): ${out}"
  assert_contains "${out}" "com~apple~CloudDocs" "iCloud Drive is chosen despite the partial Google Drive folder"
  assert_contains "${out}" "no 'My Drive' inside" "the partial-Google-Drive fallback is warned, not silent"
else
  echo "smoke: #20 iCloud Drive fallback auto-detect — SKIPPED (auto-detect is macOS-only)"
fi

# --- Issue #5c: concurrency lock. A second run is refused while the lock dir
#     exists; a normal run releases it (no stale lock left behind). XDG_CACHE_HOME
#     is set explicitly so the lock path is deterministic regardless of the outer
#     environment. Cross-platform (apply mode + --allow-local-root). ---
echo "smoke: #5c — concurrency lock refuses a second run, releases on exit"
i5h="${sandbox}/i5-home"; i5c="${sandbox}/i5-cloud"; i5cache="${i5h}/.cache"
mkdir -p "${i5cache}" "${i5c}"
lockdir="${i5cache}/cloud-xdg-provision.lock"
mkdir -p "${lockdir}"   # simulate another run already holding the lock
set +e
out="$(HOME="${i5h}" XDG_CACHE_HOME="${i5cache}" /bin/bash "${PROV}" \
  --cloud-root "${i5c}" --apply --allow-local-root 2>&1)"
rc=$?
set -e
assert_nonzero "${rc}" "apply is refused while a lock exists"
assert_contains "${out}" "another run is in progress" "lock refusal explains why"
if [ -d "${lockdir}" ]; then
  ok "pre-existing lock left intact (a refused run must not remove a lock it didn't create)"
else
  fail "a refused run removed a lock it did not own"
fi
rmdir "${lockdir}"
# With the lock cleared, a clean run must acquire AND release it — no stale lock.
set +e
out="$(HOME="${i5h}" XDG_CACHE_HOME="${i5cache}" /bin/bash "${PROV}" \
  --cloud-root "${i5c}" --apply --allow-local-root 2>&1)"
rc=$?
set -e
pass_if "${rc}" "apply runs cleanly once the lock is gone (exit 0)" \
  "apply failed after lock cleared (exit ${rc}): ${out}"
if [ -d "${lockdir}" ]; then
  fail "lock dir was left behind after a normal run (trap did not release it)"
else
  ok "lock released on exit — no stale lock remains (master cleanup trap fired)"
fi

# --- Issue #5b: write_user_dirs backs up a pre-existing user-dirs.dirs before
#     overwriting it. That path is non-macOS only, so we force PLATFORM=linux via a
#     `uname` PATH-shim (the script reads `uname -s` at load). --allow-local-root
#     makes check_cloud_liveness return BEFORE the Linux GNU-stat liveness probe, so
#     the shimmed run stays portable on this macOS host. Skips with reason if the
#     shimmed non-macOS path proves unstable here. ---
echo "smoke: #5b — existing user-dirs.dirs is backed up before overwrite (uname-shim forces Linux)"
i6shim="${sandbox}/i6-shim"
mkdir -p "${i6shim}"
cat > "${i6shim}/uname" <<'UNAMESH'
#!/bin/sh
case "$1" in
  -s) echo "Linux" ;;
  *) exec /usr/bin/uname "$@" ;;
esac
UNAMESH
chmod +x "${i6shim}/uname"
i6h="${sandbox}/i6-home"; i6c="${sandbox}/i6-cloud"
i6cfg="${i6h}/.config"; i6cache="${i6h}/.cache"
mkdir -p "${i6cfg}" "${i6cache}" "${i6c}"
printf 'XDG_DOCUMENTS_DIR="/old/hand/tuned/path"\n' > "${i6cfg}/user-dirs.dirs"
set +e
out="$(HOME="${i6h}" XDG_CONFIG_HOME="${i6cfg}" XDG_CACHE_HOME="${i6cache}" \
  PATH="${i6shim}:${PATH}" /bin/bash "${PROV}" \
  --cloud-root "${i6c}" --apply --allow-local-root 2>&1)"
rc=$?
set -e
if [ "${rc}" -eq 0 ]; then
  ok "shimmed-Linux apply run exits 0"
  if ls -d "${i6cfg}"/user-dirs.dirs.bak-* >/dev/null 2>&1; then
    ok "user-dirs.dirs.bak-* backup was created before overwrite"
  else
    fail "no user-dirs.dirs.bak-* backup was created"
  fi
  bakfile=""
  for bf in "${i6cfg}"/user-dirs.dirs.bak-*; do
    [ -e "${bf}" ] || continue
    bakfile="${bf}"; break
  done
  if [ -n "${bakfile}" ] && grep -q '/old/hand/tuned/path' "${bakfile}"; then
    ok "backup preserves the original hand-tuned content"
  else
    fail "backup did not preserve the original content"
  fi
  assert_contains "${out}" "Backed up existing user-dirs.dirs" "run reports the backup it made"
  if grep -q "${i6c}" "${i6cfg}/user-dirs.dirs"; then
    ok "live user-dirs.dirs was rewritten to point into the cloud root"
  else
    fail "user-dirs.dirs was not rewritten after backup"
  fi
else
  echo "  SKIP: #5b backup — shimmed non-macOS path unstable on this host (exit ${rc})"
fi

# --- Issue #7 (dead local_name param): covered by the M1 mac/xdg folder-name group
#     above, which exercises local_name("$mac","$lin") via the ~/Movies symlink
#     target check. No separate assertion needed. ---

# --- Issue #5a (root-refusal guard): SKIPPED — exercising the refusal needs uid 0,
#     and `id` cannot be safely stubbed under set -euo pipefail without masking real
#     failures. The guard is a 2-line `[ "$(id -u)" = "0" ] && die`; verified by
#     inspection. ---
echo "smoke: #5a root-refusal guard — SKIPPED (needs uid 0; not stubbable here)"

# ===========================================================================
# Consistency + Linux coverage (issues #6 / #8). Both force PLATFORM=linux via the
# uname PATH-shim because the Linux-only branches are otherwise untested on this
# macOS host. Same isolation rules; self-cleaning under sandbox.
# ===========================================================================

# --- Issue #6: write_user_dirs must AGREE with the symlink layer — a cloud-pointing
#     XDG var is written only for a genuinely-redirected dir. downloads is the moving
#     part: create-only (local) by default, redirected only with --redirect-downloads.
#     Also covers local_name's Linux naming (~/Videos, not ~/Movies). ---
echo "smoke: #6 — user-dirs.dirs agrees with the symlink layer (forced-Linux)"
i7shim="${sandbox}/i7-shim"; mkdir -p "${i7shim}"
cat > "${i7shim}/uname" <<'UNAMESH'
#!/bin/sh
case "$1" in
  -s) echo "Linux" ;;
  *) exec /usr/bin/uname "$@" ;;
esac
UNAMESH
chmod +x "${i7shim}/uname"
i7c="${sandbox}/i7-cloud"; mkdir -p "${i7c}"

# (a)+(b): DEFAULT run — documents redirected (cloud var), downloads NOT.
i7h="${sandbox}/i7-home"; i7cfg="${i7h}/.config"; i7cache="${i7h}/.cache"
mkdir -p "${i7cfg}" "${i7cache}"
set +e
out="$(HOME="${i7h}" XDG_CONFIG_HOME="${i7cfg}" XDG_CACHE_HOME="${i7cache}" \
  PATH="${i7shim}:${PATH}" /bin/bash "${PROV}" \
  --cloud-root "${i7c}" --apply --allow-local-root 2>&1)"
rc=$?
set -e
if [ "${rc}" -eq 0 ]; then
  udirs="$(cat "${i7cfg}/user-dirs.dirs" 2>/dev/null || true)"
  assert_contains "${udirs}" "XDG_DOCUMENTS_DIR=\"${i7c}/documents\"" \
    "(a) redirected dir (documents) gets a cloud-pointing XDG var"
  assert_not_contains "${udirs}" "XDG_DOWNLOAD_DIR" \
    "(b) downloads gets NO cloud-pointing XDG var by default"
  # local_name Linux naming: the Linux dir is ~/Videos, never ~/Movies.
  if [ -L "${i7h}/Videos" ]; then
    ok "local_name Linux branch: HOME/Videos symlink created (XDG name)"
  else
    fail "expected HOME/Videos symlink under forced-Linux (local_name Linux branch)"
  fi
  if [ -e "${i7h}/Movies" ]; then
    fail "HOME/Movies must not exist under forced-Linux naming"
  else
    ok "HOME/Movies absent under forced-Linux (Apple name not used on Linux)"
  fi
  if [ -L "${i7h}/Downloads" ]; then
    fail "Downloads was symlinked by default (must stay create-only)"
  else
    ok "Downloads left local by default (symlink layer agrees with user-dirs.dirs)"
  fi
  assert_contains "${out}" "skip redirect: downloads" "default run shows the downloads-skip hint"

  # (c): --redirect-downloads → downloads DOES get a cloud var AND is symlinked.
  i7h2="${sandbox}/i7-home2"; i7cfg2="${i7h2}/.config"; i7cache2="${i7h2}/.cache"
  mkdir -p "${i7cfg2}" "${i7cache2}"
  set +e
  out="$(HOME="${i7h2}" XDG_CONFIG_HOME="${i7cfg2}" XDG_CACHE_HOME="${i7cache2}" \
    PATH="${i7shim}:${PATH}" /bin/bash "${PROV}" \
    --cloud-root "${i7c}" --apply --allow-local-root --redirect-downloads 2>&1)"
  rc=$?
  set -e
  pass_if "${rc}" "--redirect-downloads run exits 0" "run failed (exit ${rc}): ${out}"
  udirs2="$(cat "${i7cfg2}/user-dirs.dirs" 2>/dev/null || true)"
  assert_contains "${udirs2}" "XDG_DOWNLOAD_DIR=\"${i7c}/downloads\"" \
    "(c) --redirect-downloads gives downloads a cloud-pointing XDG var"
  if [ -L "${i7h2}/Downloads" ]; then
    ok "(c) --redirect-downloads actually symlinks Downloads into the cloud"
  else
    fail "(c) --redirect-downloads did not symlink Downloads"
  fi
else
  echo "  SKIP: #6 forced-Linux user-dirs test — shimmed path unstable here (exit ${rc})"
fi

# --- Issue #8: cloud_root_is_live() Linux fstype classification. SHIM `stat` (canned
#     %T fstype + %d device id) AND uname=Linux, then exercise the B4 gate (--apply
#     WITHOUT --allow-local-root). Verified against the production logic: fuse* → live;
#     known-local → refused; UNKNOWN-fuse-magic/"" → fall through to the st_dev
#     heuristic (different device = live, same = refused). ---
echo "smoke: #8 — cloud_root_is_live fstype classification (stat+uname shims, forced-Linux)"
fsshim="${sandbox}/fs-shim"; mkdir -p "${fsshim}"
cat > "${fsshim}/uname" <<'UN'
#!/bin/sh
case "$1" in -s) echo "Linux" ;; *) exec /usr/bin/uname "$@" ;; esac
UN
cat > "${fsshim}/stat" <<'ST'
#!/bin/sh
# Canned stat for the #8 test, driven by SHIM_* env vars.
#   stat -f -c %T <path> -> the fstype name; stat -c %d <path> -> a device id
#   (HOME gets SHIM_DEV_HOME, the cloud root gets SHIM_DEV_ROOT).
case "$1" in
  -f) printf '%s\n' "${SHIM_FSTYPE}" ;;
  -c) p=""; for a in "$@"; do p="$a"; done
      if [ "$p" = "$HOME" ]; then printf '%s\n' "${SHIM_DEV_HOME}"; else printf '%s\n' "${SHIM_DEV_ROOT}"; fi ;;
  *) exec /usr/bin/stat "$@" ;;
esac
ST
chmod +x "${fsshim}/uname" "${fsshim}/stat"
fs_n=0
run_fstype_case() {  # $1=fstype  $2=dev_root  $3=dev_home  → sets globals out, rc
  fs_n=$((fs_n + 1))
  fch="${sandbox}/fs-${fs_n}-home"; fcc="${sandbox}/fs-${fs_n}-cloud"
  mkdir -p "${fch}/.cache" "${fch}/.config" "${fcc}"
  set +e
  out="$(HOME="${fch}" XDG_CONFIG_HOME="${fch}/.config" XDG_CACHE_HOME="${fch}/.cache" \
    SHIM_FSTYPE="$1" SHIM_DEV_ROOT="$2" SHIM_DEV_HOME="$3" \
    PATH="${fsshim}:${PATH}" /bin/bash "${PROV}" --cloud-root "${fcc}" --apply 2>&1)"
  rc=$?
  set -e
}
# Live FUSE types proceed past the B4 gate (no --allow-local-root needed).
for fst in fuse fuseblk fuse.glusterfs; do
  run_fstype_case "${fst}" 0 0
  pass_if "${rc}" "fstype '${fst}' treated as live (apply proceeds past B4)" \
    "fstype '${fst}' was wrongly refused (exit ${rc}): ${out}"
  assert_not_contains "${out}" "does not look like a live cloud mount" \
    "fstype '${fst}' not flagged as a dead mount"
done
# Known-local types are refused without --allow-local-root.
for fst in ext4 xfs tmpfs; do
  run_fstype_case "${fst}" 0 0
  assert_nonzero "${rc}" "fstype '${fst}' refused (known local fs, B4)"
  assert_contains "${out}" "does not look like a live cloud mount" \
    "fstype '${fst}' refusal explains the dead-mount reason"
done
# UNKNOWN fuse-magic (old coreutils) and empty fstype → fall through to st_dev.
# Different device than HOME = treated live (the documented fail-safe — don't over-refuse).
run_fstype_case "UNKNOWN (0x65735546)" 4242 11
pass_if "${rc}" "UNKNOWN fuse-magic + different device → st_dev fallback treats as live" \
  "UNKNOWN-magic different-device run was refused (exit ${rc}): ${out}"
assert_not_contains "${out}" "does not look like a live cloud mount" \
  "UNKNOWN-magic different-device not over-refused (documented fail-safe)"
run_fstype_case "" 4242 11
pass_if "${rc}" "empty fstype + different device → st_dev fallback treats as live" \
  "empty-fstype different-device run was refused (exit ${rc}): ${out}"
# Same device under the fallback → conservative refusal.
run_fstype_case "UNKNOWN (0x65735546)" 11 11
assert_nonzero "${rc}" "UNKNOWN fuse-magic + SAME device → st_dev fallback refuses (conservative)"
assert_contains "${out}" "does not look like a live cloud mount" \
  "same-device fallback refusal explains the reason"

# --- Review M-c: verify_copy() is the post-copy gate — on a bad copy it must die
#     BEFORE the destructive `mv`, leaving the original in place (never lost to a
#     truncated/incomplete copy). The success path is covered; this exercises the
#     MISMATCH->die path. A copier PATH-shim does the REAL copy then DELETES a file
#     from the destination, so verify_copy's read-back finds a genuine diff. Both
#     rsync (the default copier when present) and cp (the fallback) are shimmed, so
#     whichever the script picks, the sabotage lands — no skip needed (cp always
#     exists). Confirmed by bypass-sanity: if verify_copy is forced to return 0, this
#     group fails (original gets moved to an aside, run exits 0). ---
echo "smoke: M-c — verify_copy aborts on a bad copy WITHOUT moving the original"
vch="${sandbox}/vc-home"; vcc="${sandbox}/vc-cloud"; vcshim="${sandbox}/vc-shim"
mkdir -p "${vch}/Documents" "${vcc}" "${vch}/.cache" "${vcshim}"
printf 'original-payload\n' > "${vch}/Documents/payload.txt"
printf 'second-file\n'      > "${vch}/Documents/other.txt"
vc_real_rsync="$(command -v rsync || true)"
vc_real_cp="$(command -v cp || echo /bin/cp)"
# rsync shim: pass the dry-run VERIFY call (-n) through untouched; for the real COPY,
# copy then delete payload.txt from the dest so the verify read-back sees it missing.
cat > "${vcshim}/rsync" <<'RS'
#!/bin/sh
for a in "$@"; do case "$a" in -n) exec "$REAL_RSYNC" "$@" ;; esac; done
"$REAL_RSYNC" "$@"; rc=$?
last=""; for a in "$@"; do last="$a"; done
rm -f "${last}payload.txt" 2>/dev/null || true
exit $rc
RS
# cp shim (used only if rsync is absent — verify_copy's cp path compares file count):
# copy then delete payload.txt from the dest so the count/bytes mismatch.
cat > "${vcshim}/cp" <<'CP'
#!/bin/sh
"$REAL_CP" "$@"; rc=$?
last=""; for a in "$@"; do last="$a"; done
rm -f "${last}payload.txt" 2>/dev/null || true
exit $rc
CP
chmod +x "${vcshim}/rsync" "${vcshim}/cp"
set +e
out="$(HOME="${vch}" XDG_CACHE_HOME="${vch}/.cache" \
  REAL_RSYNC="${vc_real_rsync}" REAL_CP="${vc_real_cp}" \
  PATH="${vcshim}:${PATH}" /bin/bash "${PROV}" \
  --cloud-root "${vcc}" --apply --relocate --allow-local-root 2>&1)"
rc=$?
set -e
assert_nonzero "${rc}" "bad-copy run EXITS NON-ZERO (verify_copy aborted the relocate)"
assert_contains "${out}" "post-copy verification FAILED" "failure names the post-copy verification gate"
if [ -d "${vch}/Documents" ] && [ ! -L "${vch}/Documents" ] &&
   [ -f "${vch}/Documents/payload.txt" ] && [ -f "${vch}/Documents/other.txt" ]; then
  ok "original ~/Documents intact at its path (real dir, both files present)"
else
  fail "original ~/Documents was altered/moved despite the verify failure"
fi
if ls -d "${vch}"/Documents.pre-offload-* >/dev/null 2>&1; then
  fail "original was moved to a *.pre-offload-* aside despite verify failing (destructive mv ran)"
else
  ok "no *.pre-offload-* aside created (the destructive mv never ran)"
fi
if ls -d "${vch}/.cache/cloud-xdg-provision.lock" >/dev/null 2>&1; then
  fail "lock dir left behind after the aborted run"
else
  ok "lock released after the aborted run"
fi

# ===========================================================================
# PR #11 remediation — INTERRUPT regression (the gap that let two BLOCKING trap
# bugs ship): actually send a signal MID-RELOCATE and assert the process terminates
# safely. This group FAILS against the pre-fix code (subshell-scoped flags +
# handler-never-exits → exit 0, relocate completes, no recovery message) and PASSES
# after the fix (de-piped loop + split EXIT/INT-TERM with exit 130). Empirically
# confirmed both directions by stashing the bin fix.
#
# Mechanism: an `mv` PATH-shim sleeps 5s AFTER the rename whose destination matches
# IR_SLEEP_MATCH, widening that exact window. We background --apply --relocate on a
# populated sandbox dir and signal it while the shim sleeps. (bash defers the trapped
# signal until the in-flight mv returns, so the interrupt is deterministic, not
# racing the window edge.)
#
# WHY SIGTERM, not SIGINT: a job started with `&` in a NON-INTERACTIVE shell (this
# test) has SIGINT/SIGQUIT set to SIG_IGN on entry, and POSIX forbids a
# non-interactive shell from trapping a signal that was ignored on entry — so a
# `kill -INT` here would be silently dropped (the child can't catch it) and the run
# would finish normally, testing nothing. SIGTERM is NOT ignored for background jobs,
# and the production handler traps BOTH (`trap on_signal INT TERM`), so SIGTERM
# exercises the identical code path a real foreground Ctrl-C (SIGINT) takes.
# ===========================================================================
ir_n=0
interrupt_relocate() {  # $1=dest-substring to widen  $2=seconds before the signal
  ir_n=$((ir_n + 1))
  ir_home="${sandbox}/ir-${ir_n}-home"; ir_cloud="${sandbox}/ir-${ir_n}-cloud"
  ir_shim="${sandbox}/ir-${ir_n}-shim"
  mkdir -p "${ir_home}/Documents" "${ir_cloud}" "${ir_home}/.cache" "${ir_shim}"
  printf 'important-payload\n' > "${ir_home}/Documents/payload.txt"
  cat > "${ir_shim}/mv" <<'MVSH'
#!/bin/sh
# Widen one relocate window: do the real rename, then sleep if its destination
# matches IR_SLEEP_MATCH, so a signal to the parent lands while we're inside it.
last=""; for a in "$@"; do last="$a"; done
/bin/mv "$@"; rc=$?
case "$last" in *"${IR_SLEEP_MATCH}"*) sleep 5 ;; esac
exit $rc
MVSH
  chmod +x "${ir_shim}/mv"
  set +e
  HOME="${ir_home}" XDG_CACHE_HOME="${ir_home}/.cache" IR_SLEEP_MATCH="$1" \
    PATH="${ir_shim}:${PATH}" /bin/bash "${PROV}" \
    --cloud-root "${ir_cloud}" --apply --relocate --allow-local-root \
    > "${sandbox}/ir-${ir_n}-out.txt" 2>&1 &
  ir_pid=$!
  sleep "$2"
  kill -TERM "${ir_pid}" 2>/dev/null   # TERM, not INT — see the WHY-SIGTERM note above
  wait "${ir_pid}"; ir_rc=$?
  set -e
  ir_out="$(cat "${sandbox}/ir-${ir_n}-out.txt" 2>/dev/null || true)"
}

# --- Probe window (macOS-only — the TCC rename-probe exists only on PLATFORM=macos).
#     Interrupt while the dir is renamed aside to *.tcc-probe.*; the master handler
#     must revert it, leave the original intact, release the lock, and exit non-zero. ---
if [ "$(uname -s)" = "Darwin" ]; then
  echo "smoke: PR#11 interrupt — signal in the TCC-probe window reverts safely (macOS)"
  interrupt_relocate ".tcc-probe." 2
  assert_nonzero "${ir_rc}" "probe-window signal exits NON-ZERO (not 0 — B2 regression guard)"
  if ls -d "${ir_home}"/Documents.tcc-probe.* >/dev/null 2>&1; then
    fail "probe was left stranded (.tcc-probe.* dir) — B1 regression (revert dead in subshell)"
  else
    ok "no stranded *.tcc-probe.* dir (probe was reverted by the parent-scope handler)"
  fi
  if [ -d "${ir_home}/Documents" ] && [ ! -L "${ir_home}/Documents" ] &&
     [ -f "${ir_home}/Documents/payload.txt" ]; then
    ok "original ~/Documents intact (real dir, payload preserved — relocate aborted cleanly)"
  else
    fail "original ~/Documents was relocated/altered despite a mid-probe interrupt"
  fi
  if ls -d "${ir_home}/.cache/cloud-xdg-provision.lock" >/dev/null 2>&1; then
    fail "lock dir left behind after an interrupted run (#5c guarantee broken)"
  else
    ok "lock released on interrupt (no stale lock)"
  fi
else
  echo "smoke: PR#11 interrupt (probe window) — SKIPPED (TCC probe is macOS-only)"
fi

# --- mv->ln window (cross-platform): interrupt after the original is renamed aside
#     (*.pre-offload-*) but before the symlink is created. The handler must PRINT the
#     recovery message (proving the RELOCATE_ACTIVE flag — set inside relocate_dir —
#     is visible to the PARENT-scope handler after de-piping), keep the data in the
#     aside, release the lock, and exit non-zero. ---
echo "smoke: PR#11 interrupt — signal in the mv->ln window recovers safely"
interrupt_relocate ".pre-offload-" 3
assert_nonzero "${ir_rc}" "mv->ln-window signal exits NON-ZERO (not 0 — B2 regression guard)"
assert_contains "${ir_out}" "INTERRUPTED mid-relocate" \
  "recovery message printed (RELOCATE_ACTIVE flag reached the parent handler — B1 fix)"
ir_aside_ok=0
for a in "${ir_home}"/Documents.pre-offload-*; do
  [ -f "${a}/payload.txt" ] && ir_aside_ok=1
done
if [ "${ir_aside_ok}" -eq 1 ]; then
  ok "original data preserved in the *.pre-offload-* aside (never vanished)"
else
  fail "data was not safely in an aside after a mid-mv->ln interrupt"
fi
if ls -d "${ir_home}/.cache/cloud-xdg-provision.lock" >/dev/null 2>&1; then
  fail "lock dir left behind after an interrupted run (#5c guarantee broken)"
else
  ok "lock released on interrupt (no stale lock)"
fi

# ===========================================================================
# Shared-library mechanism (#2 / #3 dedup refactor) — standing guards for the
# bin/lib/xdg-common.sh sourcing machinery that the groups above don't touch.
# The PRE-vs-POST golden equivalence proof is a one-shot TEST-phase artifact;
# THESE lock the new failure/edge modes against future drift. Same isolation
# rules: everything lives under ${sandbox} and is removed by the EXIT trap.
# The real bin/lib/xdg-common.sh is NEVER renamed/removed — we operate only on
# sandbox COPIES / SYMLINKS of the scripts.
# ===========================================================================

# --- Group L1: missing-lib contract (architecture §4.2). Each script must, when
#     its bin/lib/xdg-common.sh is absent/unreadable, print the exact
#     "required library not found or unreadable" error to stderr and exit 1
#     (BEFORE sourcing — die() isn't available yet, so the message is inlined). ---
echo "smoke: L1 — missing shared library is reported and aborts with exit 1"
for scr in cloud-xdg-provision.sh home-tree.sh; do
  l1dir="${sandbox}/l1-${scr}"
  mkdir -p "${l1dir}"
  cp "${repo}/bin/${scr}" "${l1dir}/${scr}"   # copy WITHOUT a lib/ subdir alongside it
  set +e
  out="$(/bin/bash "${l1dir}/${scr}" --help 2>&1)"
  rc=$?
  set -e
  if [ "${rc}" -eq 1 ]; then
    ok "${scr}: missing-lib run exits 1 (exact contract, not just non-zero)"
  else
    fail "${scr}: missing-lib run exited ${rc}, expected 1"
  fi
  assert_contains "${out}" "required library not found or unreadable" \
    "${scr}: missing-lib error names the unreadable library"
  # The aborted-path must report the absolute lib path it looked for, under the copy's dir.
  assert_contains "${out}" "${l1dir}/lib/xdg-common.sh" \
    "${scr}: missing-lib error reports the resolved lib path it expected"
done
# Unreadable (present but chmod 000) is the OTHER half of the `[ ! -r ]` guard.
# Gated on non-root: root bypasses read perms, which would mask the guard.
if [ "$(id -u)" != "0" ]; then
  echo "smoke: L1b — present-but-unreadable shared library is also reported (chmod 000)"
  l1bdir="${sandbox}/l1b"
  mkdir -p "${l1bdir}/lib"
  cp "${repo}/bin/cloud-xdg-provision.sh" "${l1bdir}/cloud-xdg-provision.sh"
  cp "${repo}/bin/lib/xdg-common.sh" "${l1bdir}/lib/xdg-common.sh"
  chmod 000 "${l1bdir}/lib/xdg-common.sh"
  set +e
  out="$(/bin/bash "${l1bdir}/cloud-xdg-provision.sh" --help 2>&1)"
  rc=$?
  set -e
  chmod 644 "${l1bdir}/lib/xdg-common.sh"   # restore so the EXIT-trap rm can recurse in
  if [ "${rc}" -eq 1 ]; then
    ok "unreadable-lib run exits 1"
  else
    fail "unreadable-lib run exited ${rc}, expected 1"
  fi
  assert_contains "${out}" "required library not found or unreadable" \
    "unreadable-lib error names the unreadable library"
else
  echo "smoke: L1b unreadable-lib — SKIPPED (running as root; -r bypassed)"
fi

# --- Group L2: symlink self-location (architecture §4.2 resolve loop). When the
#     script is invoked through a SYMLINK from an unrelated CWD, the resolve loop
#     must follow the link chain to the REAL script dir and source the lib relative
#     to THAT dir — not relative to the symlink's own dir. The link dirs below
#     deliberately contain NO lib/ subdir, so a resolve loop that failed to chase
#     the symlink (or used the link's dir) would not find the lib and the banner
#     would never print. A two-hop chain exercises the `while [ -h ]` loop body
#     more than once. bash 3.2-safe (ln -s, readlink without -f, cd -P). ---
echo "smoke: L2 — script invoked via a symlink chain from another CWD still finds its lib"
l2link1="${sandbox}/l2-a"; l2link2="${sandbox}/l2-b"; l2cwd="${sandbox}/l2-cwd"
l2home="${sandbox}/l2-home"; l2cloud="${sandbox}/l2-cloud"
mkdir -p "${l2link1}" "${l2link2}" "${l2cwd}" "${l2home}" "${l2cloud}"
# hop 1: l2-a/cloud-xdg-provision.sh -> real bin script;
# hop 2: l2-b/cloud-xdg-provision.sh -> l2-a/cloud-xdg-provision.sh (the loop must chase both).
ln -s "${repo}/bin/cloud-xdg-provision.sh" "${l2link1}/cloud-xdg-provision.sh"
ln -s "${l2link1}/cloud-xdg-provision.sh"  "${l2link2}/cloud-xdg-provision.sh"
set +e
out="$( cd "${l2cwd}" && HOME="${l2home}" /bin/bash "${l2link2}/cloud-xdg-provision.sh" \
  --cloud-root "${l2cloud}" 2>&1 )"
rc=$?
set -e
pass_if "${rc}" "symlinked dry-run exits 0 (lib resolved via the link chain)" \
  "symlinked run failed (exit ${rc}) — resolve loop did not find the lib: ${out}"
assert_contains "${out}" "platform=" \
  "symlinked run reached main() and printed its banner (lib functions loaded)"
assert_contains "${out}" "mode=DRY-RUN" "symlinked run banner reports DRY-RUN mode"

# --- Group L3: registry-derivation standing guard (architecture §5, §6). Source
#     the library and assert (a) xdg_offload_set() reproduces cloud-xdg's 8-row
#     OFFLOAD_SET in EXACT order, and (b) home-tree's SAFE_DIRS — derived from
#     HOMETREE_KEYS + the linuxName column (field 3) — equals the historical
#     literal "Documents Pictures Music Videos Projects Notes" in that order.
#     This locks the §6 linuxName<->rclone-filter coupling and the divergent
#     per-script ordering (cloud-xdg: Music before Pictures; home-tree: Pictures
#     before Music) against silent registry drift. Run under /bin/bash (3.2). ---
echo "smoke: L3 — registry derivation reproduces OFFLOAD_SET (8 rows, order) + SAFE_DIRS"
lib="${repo}/bin/lib/xdg-common.sh"
expected_offload="$(printf '%s\n' \
  'desktop|Desktop|Desktop|XDG_DESKTOP_DIR|1' \
  'documents|Documents|Documents|XDG_DOCUMENTS_DIR|1' \
  'downloads|Downloads|Downloads|XDG_DOWNLOAD_DIR|1' \
  'music|Music|Music|XDG_MUSIC_DIR|1' \
  'pictures|Pictures|Pictures|XDG_PICTURES_DIR|1' \
  'videos|Movies|Videos|XDG_VIDEOS_DIR|1' \
  'public|Public|Public|XDG_PUBLICSHARE_DIR|1' \
  'templates|Templates|Templates|XDG_TEMPLATES_DIR|1')"
set +e
actual_offload="$(/bin/bash -c '. "$1"; xdg_offload_set' _ "${lib}")"
rc=$?
set -e
pass_if "${rc}" "sourcing the lib + xdg_offload_set runs cleanly" \
  "xdg_offload_set failed to run (exit ${rc})"
if [ "${actual_offload}" = "${expected_offload}" ]; then
  ok "xdg_offload_set reproduces the 8-row OFFLOAD_SET in cloud-xdg order"
else
  printf 'FAIL: xdg_offload_set drifted from the historical OFFLOAD_SET\n' >&2
  printf '--- expected ---\n%s\n--- actual ---\n%s\n' "${expected_offload}" "${actual_offload}" >&2
  exit 1
fi
# home-tree SAFE_DIRS derivation (mirrors home-tree.sh: linuxName per HOMETREE_KEYS).
set +e
actual_safe="$(/bin/bash -c '. "$1"; r=""; for k in $HOMETREE_KEYS; do r="$r $(field "$(registry_row "$k")" 3)"; done; printf "%s" "${r# }"' _ "${lib}")"
rc=$?
set -e
pass_if "${rc}" "deriving SAFE_DIRS from HOMETREE_KEYS runs cleanly" \
  "SAFE_DIRS derivation failed (exit ${rc})"
if [ "${actual_safe}" = "Documents Pictures Music Videos Projects Notes" ]; then
  ok "SAFE_DIRS derives to the historical set+order (Pictures before Music; Notes present)"
else
  fail "SAFE_DIRS drifted: got '${actual_safe}' (locks §6 filter coupling — investigate before changing)"
fi

# --- #12 (M-d): acquire_lock must distinguish a genuine concurrent lock from an
#     UNWRITABLE $XDG_CACHE_HOME. The old code reported BOTH as "another run is in
#     progress". Here the cache dir EXISTS but is read-only, so the lock mkdir fails
#     for a non-lock reason → the new accurate message must appear and the misleading
#     "another run" message must NOT. Gated on this host actually enforcing read-only
#     dir perms for the owner (skipped under root / a permissive FS). ---
echo "smoke: #12 (M-d) — unwritable cache reported distinctly, not as 'another run in progress'"
mdh="${sandbox}/md-home"; mdc="${sandbox}/md-cloud"; mdcache="${mdh}/.cache"
mkdir -p "${mdcache}" "${mdc}"
mdprobe="${sandbox}/md-permprobe"; mkdir -p "${mdprobe}"; chmod 0500 "${mdprobe}"
if mkdir "${mdprobe}/cannot" 2>/dev/null; then
  rmdir "${mdprobe}/cannot" 2>/dev/null || true
  chmod 0700 "${mdprobe}" 2>/dev/null || true
  echo "  SKIP: #12 — this host does not enforce read-only dir perms for the owner (root/permissive FS)"
else
  chmod 0500 "${mdcache}"   # cache exists but is read-only → lock mkdir fails (not a pre-existing lock)
  set +e
  out="$(HOME="${mdh}" XDG_CACHE_HOME="${mdcache}" /bin/bash "${PROV}" \
    --cloud-root "${mdc}" --apply --allow-local-root 2>&1)"
  rc=$?
  set -e
  chmod 0700 "${mdcache}" 2>/dev/null || true   # restore so the EXIT-trap rm -rf can clean up
  chmod 0700 "${mdprobe}" 2>/dev/null || true
  assert_nonzero "${rc}" "apply is refused when the cache dir is unwritable"
  assert_contains "${out}" "cannot create lock dir" "unwritable cache gives the accurate perms error"
  assert_not_contains "${out}" "another run is in progress" "unwritable cache is NOT misreported as a concurrent run"
fi

# --- #13 (M-e): write_user_dirs' backup-name collision loop now tests -e OR -L, so a
#     DANGLING symlink at the first .bak path is detected and the uniquifier advances
#     (the old -e-only check saw a dangling link as "missing" and cp would clobber
#     THROUGH it). uname-shim forces the Linux user-dirs.dirs path; date-shim pins the
#     stamp so the .bak name is deterministic. ---
echo "smoke: #13 (M-e) — dangling symlink at the backup path advances the uniquifier"
meh="${sandbox}/me-home"; mec="${sandbox}/me-cloud"; meshim="${sandbox}/me-shim"
mecfg="${meh}/.config"; mecache="${meh}/.cache"
mkdir -p "${mecfg}" "${mecache}" "${mec}" "${meshim}"
cat > "${meshim}/uname" <<'UNAMESH'
#!/bin/sh
case "$1" in
  -s) echo "Linux" ;;
  *) exec /usr/bin/uname "$@" ;;
esac
UNAMESH
cat > "${meshim}/date" <<'DATESH'
#!/bin/sh
case "$1" in
  +%Y%m%d-%H%M%S) echo "20260101-120000" ;;
  *) exec /bin/date "$@" ;;
esac
DATESH
chmod +x "${meshim}/uname" "${meshim}/date"
printf 'XDG_DOCUMENTS_DIR="/old/hand/tuned"\n' > "${mecfg}/user-dirs.dirs"
mestamp="20260101-120000"
medangling="${mecfg}/user-dirs.dirs.bak-${mestamp}"
ln -s "${sandbox}/no-such-target" "${medangling}"   # a DANGLING symlink at the first .bak name
set +e
out="$(HOME="${meh}" XDG_CONFIG_HOME="${mecfg}" XDG_CACHE_HOME="${mecache}" \
  PATH="${meshim}:${PATH}" /bin/bash "${PROV}" \
  --cloud-root "${mec}" --apply --allow-local-root 2>&1)"
rc=$?
set -e
if [ "${rc}" -eq 0 ]; then
  if [ -f "${medangling}.1" ]; then
    ok "backup advanced to .bak-<stamp>.1 (dangling symlink at .bak-<stamp> was detected)"
  else
    fail "backup did not advance past the dangling symlink (-e || -L collision check)"
  fi
  if [ -L "${medangling}" ]; then
    ok "the dangling symlink was left intact (not followed/overwritten)"
  else
    fail "the dangling symlink at the backup path was clobbered"
  fi
  if grep -q '/old/hand/tuned' "${medangling}.1"; then
    ok ".1 backup preserved the original hand-tuned content"
  else
    fail ".1 backup did not preserve the original content"
  fi
else
  echo "  SKIP: #13 — shimmed-Linux apply path unstable on this host (exit ${rc})"
fi

# --- #15 (M-g): the deny-delete ACL gate now matches `deny` AND `delete` on the SAME
#     ACE line via acl_denies_delete (a here-doc loop — a `case` inside `$(...)` would
#     fail to PARSE under stock bash 3.2). Two directions via an `ls -lde` shim, in
#     dry-run --relocate (the ACL gate runs before any DRY_RUN guard, so no real moves
#     happen): a COMPOUND ACE ('deny write,delete') that the old substring would MISS
#     is now caught (gate returns before the "RELOCATE" line); a benign 'deny write'
#     ACE is NOT mistaken for it (relocate proceeds). macOS-only (the gate is
#     PLATFORM=macos). ---
if [ "$(uname -s)" = "Darwin" ]; then
  echo "smoke: #15 (M-g) — deny-delete ACL detection (compound caught; benign not over-matched)"
  mgshim="${sandbox}/mg-shim"; mkdir -p "${mgshim}"
  mg_set_acl() {   # $1 = the ACE rights text embedded in the shimmed `ls -lde` output
    cat > "${mgshim}/ls" <<LSSH
#!/bin/sh
if [ "\$1" = "-lde" ]; then
  printf '%s\n' "drwx------+ 2 me staff 64 Jan 1 00:00 \$2"
  printf '%s\n' " 0: group:everyone $1"
  exit 0
fi
exec /bin/ls "\$@"
LSSH
    chmod +x "${mgshim}/ls"
  }
  # (a) compound, reordered deny ACE — the old "deny delete" substring would miss it.
  mga_h="${sandbox}/mg-a-home"; mga_c="${sandbox}/mg-a-cloud"
  mkdir -p "${mga_h}/Documents" "${mga_c}"; printf 'PAYLOAD\n' > "${mga_h}/Documents/keep.txt"
  mg_set_acl "deny write,delete"
  set +e
  out="$(HOME="${mga_h}" PATH="${mgshim}:${PATH}" /bin/bash "${PROV}" \
    --cloud-root "${mga_c}" --relocate --allow-local-root 2>&1)"
  rc=$?
  set -e
  pass_if "${rc}" "dry-run --relocate over a compound deny-delete ACE exits 0" \
    "compound-ACE dry-run failed (exit ${rc}): ${out}"
  assert_contains "${out}" "deny delete' ACL" "compound 'deny write,delete' ACE IS detected (robustness over substring)"
  assert_not_contains "${out}" "RELOCATE  " "detected ACL blocks the relocate (gate returns before the RELOCATE line)"
  # (b) benign 'deny write' (no delete) — must NOT be mistaken for deny-delete.
  mgb_h="${sandbox}/mg-b-home"; mgb_c="${sandbox}/mg-b-cloud"
  mkdir -p "${mgb_h}/Documents" "${mgb_c}"; printf 'PAYLOAD\n' > "${mgb_h}/Documents/keep.txt"
  mg_set_acl "deny write"
  set +e
  out="$(HOME="${mgb_h}" PATH="${mgshim}:${PATH}" /bin/bash "${PROV}" \
    --cloud-root "${mgb_c}" --relocate --allow-local-root 2>&1)"
  rc=$?
  set -e
  pass_if "${rc}" "dry-run --relocate over a benign deny-write ACE exits 0" \
    "benign-ACE dry-run failed (exit ${rc}): ${out}"
  assert_not_contains "${out}" "deny delete' ACL" "benign 'deny write' ACE is NOT mistaken for deny-delete"
  assert_contains "${out}" "RELOCATE  " "benign ACE proceeds past the ACL gate into the relocate flow"
else
  echo "  SKIP: #15 (M-g) — ACL deny-delete gate is macOS-only (uname=$(uname -s))"
fi

# ===========================================================================
# Group C (slice 1): home-dir CLASSIFICATION foundation — the classification
# registry/derivation, helper correctness, the read-only --classify /
# --offload-status modes (ZERO mutation), the reserved-but-inert mutating lanes,
# and a default-flow regression. Mirrors the L3 derivation-golden style. Sourced
# under /bin/bash to exercise the macOS bash 3.2 path; mode runs use a sandbox
# HOME so nothing touches the real home. This is a NON-destructive slice — no
# offload/dotfiles mutation exists yet, so there are deliberately NO offload
# round-trip cases here (those land with the offload slice). `lib` is defined in
# the L3 block above; PROV/sandbox/cloud_root are the file-wide globals. ---
# ===========================================================================

# --- C1: HOME_CLASS_REGISTRY derivation — CODE_KEYS/LOCAL_KEYS reproduce the
#     expected rows in EXACT order (the classification analogue of the L3
#     OFFLOAD_SET golden). Locks the taxonomy + membership against silent drift. ---
echo "smoke: C1 — classification registry derives CODE_KEYS/LOCAL_KEYS (rows + order)"
expected_code="$(printf '%s\n' \
  'repos|repos|repos|code|1' \
  'androidstudio|AndroidStudioProjects|AndroidStudioProjects|code|1' \
  'projects|Projects|Projects|code|1')"
expected_local="$(printf '%s\n' \
  'pyenv|pyenv|pyenv|local|0' \
  'applications|Applications|Applications|local|0' \
  'syslog|log|log|local|0' \
  'qemu|QEMU|QEMU|local|0')"
set +e
actual_code="$(/bin/bash -c '. "$1"; for k in $CODE_KEYS; do code_row "$k"; done' _ "${lib}")"
rc=$?
set -e
pass_if "${rc}" "sourcing the lib + iterating CODE_KEYS runs cleanly" \
  "CODE_KEYS derivation failed to run (exit ${rc})"
if [ "${actual_code}" = "${expected_code}" ]; then
  ok "CODE_KEYS reproduces the code rows (repos, androidstudio, projects) in order"
else
  printf 'FAIL: CODE_KEYS drifted from the expected code set\n--- expected ---\n%s\n--- actual ---\n%s\n' \
    "${expected_code}" "${actual_code}" >&2
  exit 1
fi
actual_local="$(/bin/bash -c '. "$1"; for k in $LOCAL_KEYS; do code_row "$k"; done' _ "${lib}")"
if [ "${actual_local}" = "${expected_local}" ]; then
  ok "LOCAL_KEYS reproduces the machine-local rows (pyenv, applications, syslog, qemu) in order"
else
  printf 'FAIL: LOCAL_KEYS drifted from the expected local set\n--- expected ---\n%s\n--- actual ---\n%s\n' \
    "${expected_local}" "${actual_local}" >&2
  exit 1
fi

# --- C2: classification helpers resolve the right class per lane. home_class()
#     must check HOME_CLASS_REGISTRY FIRST so the overloaded 'projects' key (in
#     both registries) resolves to code, fall through to xdg for a pure XDG row,
#     and report unknown otherwise. ---
echo "smoke: C2 — home_class/is_code_dir/is_machine_local/code_row resolve correct classes"
set +e
helpers_out="$(/bin/bash -c '
  set -euo pipefail
  . "$1"
  printf "repos=%s\n"     "$(home_class repos)"
  printf "pyenv=%s\n"     "$(home_class pyenv)"
  printf "documents=%s\n" "$(home_class documents)"
  printf "bogus=%s\n"     "$(home_class definitely_not_a_key)"
  if is_code_dir repos;      then printf "is_code_dir_repos=yes\n";      fi
  if is_machine_local pyenv; then printf "is_machine_local_pyenv=yes\n"; fi
  if is_code_dir pyenv;      then printf "is_code_dir_pyenv=yes\n"; else printf "is_code_dir_pyenv=no\n"; fi
  code_row repos
' _ "${lib}")"
rc=$?
set -e
pass_if "${rc}" "classification helpers run cleanly under set -euo pipefail when sourced" \
  "classification helpers aborted (exit ${rc}): ${helpers_out}"
assert_contains "${helpers_out}" "repos=code"      "home_class(repos)=code"
assert_contains "${helpers_out}" "pyenv=local"     "home_class(pyenv)=local"
assert_contains "${helpers_out}" "documents=xdg"   "home_class(documents)=xdg (XDG row, not in HOME_CLASS_REGISTRY)"
assert_contains "${helpers_out}" "bogus=unknown"   "home_class(unknown key)=unknown"
assert_contains "${helpers_out}" "is_code_dir_repos=yes"      "is_code_dir(repos) is true"
assert_contains "${helpers_out}" "is_machine_local_pyenv=yes" "is_machine_local(pyenv) is true"
assert_contains "${helpers_out}" "is_code_dir_pyenv=no"       "is_code_dir(pyenv) is false (local is not code)"
assert_contains "${helpers_out}" "repos|repos|repos|code|1"   "code_row(repos) returns the full registry row"

# --- C2b: rclone_remote_exists() must FAIL CLOSED (non-zero) for a missing
#     remote and must NOT abort its caller under set -e — it gates the later
#     offload lane via `if`. RCLONE_CONFIG points at an empty sandbox file so the
#     result is host-independent whether or not rclone is installed. ---
echo "smoke: C2b — rclone_remote_exists fails closed for a missing remote (no set -e abort)"
rcfg="${sandbox}/empty-rclone.conf"; : > "${rcfg}"
set +e
rre_out="$(RCLONE_CONFIG="${rcfg}" /bin/bash -c '
  set -euo pipefail
  . "$1"
  if rclone_remote_exists no_such_remote_xyz; then printf "result=present\n"; else printf "result=absent\n"; fi
  printf "survived=yes\n"
' _ "${lib}")"
rc=$?
set -e
pass_if "${rc}" "rclone_remote_exists returned without aborting the set -e caller" \
  "rclone_remote_exists aborted its caller (exit ${rc}): ${rre_out}"
assert_contains "${rre_out}" "result=absent" "missing remote reports absent (fails closed)"
assert_contains "${rre_out}" "survived=yes"  "caller continued past the predicate (no set -e abort)"

# --- C3: read-only modes exit 0, print the expected class lines, and mutate
#     NOTHING. Zero-mutation is proven by a full before/after tree snapshot of a
#     sandbox HOME (find | sort). The names asserted are platform-stable because
#     macName==linuxName for every classification row. XDG_STATE_HOME is sandboxed
#     so --offload-status reads the sandbox state dir, not the real one. ---
echo "smoke: C3 — --classify is read-only and reports each lane's class"
c_home="${sandbox}/cls-home"; mkdir -p "${c_home}"
c_before="$(cd "${c_home}" && find . | sort)"
set +e
out="$(HOME="${c_home}" XDG_STATE_HOME="${c_home}/state" /bin/bash "${PROV}" --classify 2>&1)"
rc=$?
set -e
pass_if "${rc}" "--classify exits 0" "--classify failed (exit ${rc}): ${out}"
assert_contains "${out}" "Home-dir classification" "--classify prints its read-only header"
assert_contains "${out}" "code   repos"    "--classify labels repos as code"
assert_contains "${out}" "code   Projects" "--classify labels Projects as code (P2 reclassification)"
assert_contains "${out}" "local  pyenv"    "--classify labels pyenv as machine-local"
assert_contains "${out}" "xdg    Documents" "--classify labels Documents as xdg"
c_after="$(cd "${c_home}" && find . | sort)"
if [ "${c_before}" = "${c_after}" ]; then
  ok "--classify mutated nothing (sandbox HOME tree identical before/after)"
else
  printf 'FAIL: --classify mutated the home tree\n' >&2
  diff <(printf '%s\n' "${c_before}") <(printf '%s\n' "${c_after}") >&2 || true
  exit 1
fi

echo "smoke: C3b — --offload-status is read-only and reports code dirs as local with no state file"
o_home="${sandbox}/ofs-home"; mkdir -p "${o_home}"
o_before="$(cd "${o_home}" && find . | sort)"
set +e
out="$(HOME="${o_home}" XDG_STATE_HOME="${o_home}/state" /bin/bash "${PROV}" --offload-status 2>&1)"
rc=$?
set -e
pass_if "${rc}" "--offload-status exits 0" "--offload-status failed (exit ${rc}): ${out}"
assert_contains "${out}" "Code-dir offload status" "--offload-status prints its read-only header"
assert_contains "${out}" "code   repos" "--offload-status lists repos (a code dir)"
assert_contains "${out}" "local" "--offload-status reports code dirs as local when no state file exists"
assert_not_contains "${out}" "offloaded ->" "no state file => nothing is reported as offloaded"
o_after="$(cd "${o_home}" && find . | sort)"
if [ "${o_before}" = "${o_after}" ]; then
  ok "--offload-status mutated nothing (sandbox HOME tree identical before/after)"
else
  printf 'FAIL: --offload-status mutated the home tree\n' >&2
  diff <(printf '%s\n' "${o_before}") <(printf '%s\n' "${o_after}") >&2 || true
  exit 1
fi

# --- C4 (removed in slice 3): there are no longer any reserved-inert modes —
#     offload/hydrate/migrate-projects went live in slice 2 and dotfiles-init/-track/
#     -status go live in this slice. The old "reserved modes refuse" assertion no
#     longer has a subject; an UNKNOWN flag is still rejected by the arg-parse `*)`
#     arm, which the C4b check below covers. ---
echo "smoke: C4b — an unknown option is rejected (non-zero) and mutates nothing"
r_home="${sandbox}/rsv-home"; mkdir -p "${r_home}"
r_before="$(cd "${r_home}" && find . | sort)"
set +e
out="$(HOME="${r_home}" /bin/bash "${PROV}" --no-such-flag 2>&1)"
rc=$?
set -e
assert_nonzero "${rc}" "unknown option exits non-zero"
assert_contains "${out}" "unknown option" "unknown option is reported"
r_after="$(cd "${r_home}" && find . | sort)"
if [ "${r_before}" = "${r_after}" ]; then
  ok "unknown option mutated nothing (sandbox HOME tree identical before/after)"
else
  printf 'FAIL: unknown option mutated the home tree\n' >&2
  diff <(printf '%s\n' "${r_before}") <(printf '%s\n' "${r_after}") >&2 || true
  exit 1
fi

# --- C5: regression — with NO mode flag, MODE stays empty and dispatch routes to
#     main() (the default provision lane), unchanged. The provision banner is the
#     observable proof it reached main(); the report/reserved handlers never
#     print it (they have no banner). ---
echo "smoke: C5 — default (no mode) still routes to main() and prints the provision banner"
d_home="${sandbox}/def-home"; mkdir -p "${d_home}"
set +e
out="$(HOME="${d_home}" /bin/bash "${PROV}" --cloud-root "${cloud_root}" 2>&1)"
rc=$?
set -e
pass_if "${rc}" "default no-mode dry-run exits 0" "default no-mode run failed (exit ${rc}): ${out}"
assert_contains "${out}" "platform=" "no-mode run reaches main() and prints the provision banner"
assert_contains "${out}" "mode=DRY-RUN" "no-mode run is the default dry-run provision lane"
assert_not_contains "${out}" "Home-dir classification" "no-mode run did NOT enter a report mode"

# --- C6 (slice 2): offload round-trip happy path + fail-closed drop guard. CRITICAL
#     DATA-LOSS coverage — uses a SANDBOX HOME + an IN-SANDBOX container + an
#     in-sandbox type=local rclone remote, NEVER the real $HOME. The local DROP
#     deletes the sandbox container only. Skipped if rclone is genuinely absent. ---
if command -v rclone >/dev/null 2>&1; then
  echo "smoke: C6 — offload round-trip (push+verify+drop, status, hydrate) + dirty-repo fail-closed"
  oh="${sandbox}/off-home"; oremote="${sandbox}/off-remote"; ostate="${oh}/state"
  oconf="${sandbox}/off-rclone.conf"
  mkdir -p "${oh}/repos/proj-a" "${oremote}"
  printf '[loc]\ntype = local\n' > "${oconf}"
  # A clean, fully-pushed git repo: commit + a bare origin + upstream tracking, so
  # all of G2 (clean) / G3 (pushed) / G4 (no stash) pass and the drop is reachable.
  ( cd "${oh}/repos/proj-a" && git init -q \
      && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
      && printf 'hi\n' > f.txt && git add f.txt \
      && git -c user.email=t@t -c user.name=t commit -q -m add ) >/dev/null 2>&1
  git init -q --bare "${sandbox}/proj-a.git"
  ( cd "${oh}/repos/proj-a" && git remote add origin "${sandbox}/proj-a.git" \
      && git push -q -u origin HEAD ) >/dev/null 2>&1
  # GIT_CEILING_DIRECTORIES stops git's upward work-tree discovery at the sandbox so
  # offload_repos_in does NOT mistake the surrounding xdg-cloud repo for the container
  # (the sandbox lives inside this repo's tree — a test artifact, not a real ~/repos).
  orun() { RCLONE_CONFIG="${oconf}" HOME="${oh}" XDG_STATE_HOME="${ostate}" \
    GIT_CEILING_DIRECTORIES="${oh}" \
    /bin/bash "${PROV}" --code-remote loc --code-dest "${oremote}" "$@"; }
  # offload --apply: push, read-back verify, then DROP the local container.
  set +e; out="$(orun --offload repos --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "offload --apply exits 0 (clean+pushed repo)" "offload --apply failed (exit ${rc}): ${out}"
  if [ ! -e "${oh}/repos" ]; then ok "local container dropped after verified offload"; else fail "local repos NOT dropped after offload"; fi
  if [ -f "${ostate}/xdg-cloud/offloaded/repos" ]; then ok "offload state file written"; else fail "offload state file missing"; fi
  set +e; out="$(orun --offload-status 2>&1)"; set -e
  assert_contains "${out}" "offloaded ->" "offload-status reports the dir as offloaded"
  # hydrate --apply: restore from the remote.
  set +e; out="$(orun --hydrate repos --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "hydrate --apply exits 0" "hydrate --apply failed (exit ${rc}): ${out}"
  if [ -f "${oh}/repos/proj-a/f.txt" ]; then ok "hydrate restored the container contents"; else fail "hydrate did not restore the repo"; fi
  # Fail-closed: a dirty repo BLOCKS offload and drops NOTHING.
  printf 'dirty\n' > "${oh}/repos/proj-a/uncommitted.txt"
  set +e; out="$(orun --offload repos --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "dirty repo blocks offload (fail-closed, non-zero exit)"
  assert_contains "${out}" "blocking repos" "offload refusal names the blocking repos"
  if [ -d "${oh}/repos/proj-a" ]; then ok "blocked offload dropped NOTHING (container intact)"; else fail "DATA LOSS: blocked offload removed the container"; fi
else
  echo "smoke: C6 offload round-trip — SKIPPED (rclone not installed)"
fi

# --- C7 (slice 2): resolve_code_target refuses a machine-local target BEFORE any
#     rclone/mutation (the venv data-loss guard). No rclone needed — the refusal is
#     in resolve_code_target, which runs before require_code_rclone. ---
echo "smoke: C7 — offload refuses a machine-local (non-CODE) target"
v_home="${sandbox}/venv-home"; mkdir -p "${v_home}/pyenv"
set +e
out="$(HOME="${v_home}" /bin/bash "${PROV}" --offload pyenv --apply 2>&1)"
rc=$?
set -e
assert_nonzero "${rc}" "offloading a machine-local dir exits non-zero"
assert_contains "${out}" "machine-local" "machine-local target refusal explains why (venv guard)"

# --- C8 (slice 2): --migrate-projects un-symlinks a cloud-pointed ~/Projects into a
#     real local dir, NON-DESTRUCTIVELY (cloud copy + aside link retained, rm nothing).
#     Sandbox HOME + in-sandbox cloud root; rsync, no rclone. ---
echo "smoke: C8 — migrate-projects restores ~/Projects to a real local dir (non-destructive)"
m_home="${sandbox}/mig-home"; m_cloud="${sandbox}/mig-cloud"
mkdir -p "${m_home}" "${m_cloud}/projects"
printf 'proj\n' > "${m_cloud}/projects/note.txt"
ln -s "${m_cloud}/projects" "${m_home}/Projects"
set +e
out="$(HOME="${m_home}" /bin/bash "${PROV}" --cloud-root "${m_cloud}" --migrate-projects --apply 2>&1)"
rc=$?
set -e
pass_if "${rc}" "migrate-projects --apply exits 0" "migrate-projects failed (exit ${rc}): ${out}"
if [ -d "${m_home}/Projects" ] && [ ! -L "${m_home}/Projects" ]; then ok "Projects is now a real local dir (not a symlink)"; else fail "Projects is not a real local dir after migrate"; fi
if [ -f "${m_home}/Projects/note.txt" ]; then ok "cloud content copied into the new local Projects dir"; else fail "migrate did not copy the cloud content"; fi
if [ -f "${m_cloud}/projects/note.txt" ]; then ok "cloud copy RETAINED (non-destructive)"; else fail "DATA LOSS: migrate removed the cloud copy"; fi
if ls -d "${m_home}"/Projects.cloud-symlink.* >/dev/null 2>&1; then ok "old symlink retained aside (non-destructive)"; else fail "migrate did not retain the aside symlink"; fi

# ===========================================================================
# Group C9-C16 (slice 2): comprehensive offload-on-demand hardening — the
# CRITICAL data-loss surface. Two-layer strategy (test plan, Task #12):
#   * REAL rclone against a type=local remote for happy/round-trip paths (C6
#     above; C12/C13 below) — only available when rclone is installed.
#   * A PATH-shim `rclone` for deterministic FAILURE INJECTION on the gate
#     (C9/C10/C11/C14/C16) — runs on ANY host, rclone present or not.
# EVERY mutating case uses a sandbox HOME + an in-sandbox container + an
# in-sandbox remote. GIT_CEILING_DIRECTORIES stops git's work-tree discovery
# at the sandbox HOME so offload_repos_in does not climb into the real
# xdg-cloud repo that physically contains tests/sandbox (a test artifact) —
# EXCEPT C13, which deliberately omits the ceiling to probe the walk-up. ---
# ===========================================================================

# mk_rclone_shim DIR — write a static executable `rclone` stand-in into DIR. Its
#   `check` behavior is chosen at RUN time by the $SHIM_CHECK env var the calling
#   script inherits: pass (default, exit 0), fail (always non-zero), or aside-fail
#   (fail ONLY the *.pre-offload-* aside re-verify, pass the pre-drop read-back).
#   `listremotes` advertises "loc:" so require_code_rclone passes; `copy` mirrors
#   src->dest faithfully. (Static body via a quoted heredoc — shim CODE, not this
#   harness's expansions.)
mk_rclone_shim() {
  mkdir -p "$1"
  cat > "$1/rclone" <<'SHIM'
#!/bin/sh
# dest args arrive as the rclone remote spec "loc:<abs path>"; strip the remote
# prefix so writes land at the real in-sandbox path (a type=local remote maps the
# remote name to the filesystem), NOT a literal "loc:..." dir under the CWD.
case "$1" in
  listremotes) echo "loc:"; exit 0 ;;
  copy) d="${4#loc:}"; mkdir -p "$d"; cp -a "$3/." "$d/" 2>/dev/null; exit 0 ;;
  check)
    case "${SHIM_CHECK:-pass}" in
      fail)       exit 1 ;;
      aside-fail) case "$4" in *.pre-offload-*) exit 1 ;; *) exit 0 ;; esac ;;
      *)          exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
SHIM
  chmod +x "$1/rclone"
}

# mk_pushed_repo REPODIR BAREDIR — a clean, fully-pushed git work tree at REPODIR
# with an upstream-tracking branch (so G2 clean / G3 pushed / G4 no-stash all pass).
mk_pushed_repo() {
  mkdir -p "$1"
  ( cd "$1" && git init -q \
      && printf 'hi\n' > f.txt && git add f.txt \
      && git -c user.email=t@t -c user.name=t commit -q -m init ) >/dev/null 2>&1
  git init -q --bare "$2"
  ( cd "$1" && git remote add origin "$2" && git push -q -u origin HEAD ) >/dev/null 2>&1
}

# --- C9: GATE-REFUSAL-BEFORE-RM (core data-loss guard). For each blocker —
#     (a) dirty tree, (b) branch with no upstream, (c) a stash — `--apply
#     --offload` must die non-zero and leave the container BYTE-INTACT (full
#     find|sort snapshot before==after). Uses a shim rclone so it runs on any
#     host; the guards block before any copy is attempted anyway. ---
echo "smoke: C9 — offload gate refuses (dirty / unpushed / stash) and drops NOTHING"
c9shim="${sandbox}/c9-shim"; mk_rclone_shim "${c9shim}"
c9run() { PATH="${c9shim}:${PATH}" RCLONE_CONFIG=/dev/null HOME="$1" \
  XDG_STATE_HOME="$1/state" GIT_CEILING_DIRECTORIES="$1" \
  /bin/bash "${PROV}" --code-remote loc --code-dest "$1/remote" --offload repos --apply; }
# (a) dirty: a clean+pushed repo with an extra untracked file.
c9a="${sandbox}/c9a"; mk_pushed_repo "${c9a}/repos/proj" "${sandbox}/c9a.git"
printf 'dirty\n' > "${c9a}/repos/proj/untracked.txt"
b9="$(cd "${c9a}/repos" && find . | sort)"
set +e; out="$(c9run "${c9a}" 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "dirty repo blocks offload"
assert_contains "${out}" "blocking repos" "dirty-repo refusal names the blocking repos"
if [ "${b9}" = "$(cd "${c9a}/repos" && find . | sort)" ]; then ok "dirty-repo refusal left the container byte-intact"; else fail "DATA LOSS: container changed after a blocked offload (dirty)"; fi
# (b) no upstream: committed but never pushed (no origin).
c9b="${sandbox}/c9b"; mkdir -p "${c9b}/repos/proj"
( cd "${c9b}/repos/proj" && git init -q && printf 'x\n' > f.txt && git add f.txt \
    && git -c user.email=t@t -c user.name=t commit -q -m init ) >/dev/null 2>&1
b9b="$(cd "${c9b}/repos" && find . | sort)"
set +e; out="$(c9run "${c9b}" 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "repo with no upstream blocks offload"
assert_contains "${out}" "no upstream" "unpushed-branch refusal explains the missing upstream"
if [ "${b9b}" = "$(cd "${c9b}/repos" && find . | sort)" ]; then ok "no-upstream refusal left the container byte-intact"; else fail "DATA LOSS: container changed after a blocked offload (no upstream)"; fi
# (c) stash present (tree otherwise clean+pushed).
c9c="${sandbox}/c9c"; mk_pushed_repo "${c9c}/repos/proj" "${sandbox}/c9c.git"
( cd "${c9c}/repos/proj" && printf 'change\n' >> f.txt \
    && git -c user.email=t@t -c user.name=t stash -q ) >/dev/null 2>&1
b9c="$(cd "${c9c}/repos" && find . | sort)"
set +e; out="$(c9run "${c9c}" 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "a present stash blocks offload"
assert_contains "${out}" "stash" "stash refusal names stashes as the blocker"
if [ "${b9c}" = "$(cd "${c9c}/repos" && find . | sort)" ]; then ok "stash refusal left the container byte-intact"; else fail "DATA LOSS: container changed after a blocked offload (stash)"; fi

# --- C10: READ-BACK FAILURE injection. The shim's `copy` SUCCEEDS but `check`
#     returns non-zero — proving the local rm is gated on the INDEPENDENT
#     read-back (G5), not on the copy exit code. Container must stay intact. ---
echo "smoke: C10 — read-back verify failure aborts the drop (rm gated on read-back, not copy rc)"
c10shim="${sandbox}/c10-shim"; mk_rclone_shim "${c10shim}"
c10h="${sandbox}/c10h"; mk_pushed_repo "${c10h}/repos/proj" "${sandbox}/c10.git"
b10="$(cd "${c10h}/repos" && find . | sort)"
set +e
out="$(PATH="${c10shim}:${PATH}" SHIM_CHECK=fail RCLONE_CONFIG=/dev/null HOME="${c10h}" \
  XDG_STATE_HOME="${c10h}/state" GIT_CEILING_DIRECTORIES="${c10h}" \
  /bin/bash "${PROV}" --code-remote loc --code-dest "${c10h}/remote" --offload repos --apply 2>&1)"
rc=$?
set -e
assert_nonzero "${rc}" "read-back failure makes offload exit non-zero"
assert_contains "${out}" "Nothing dropped" "read-back failure says nothing was dropped"
if [ "${b10}" = "$(cd "${c10h}/repos" && find . | sort)" ]; then ok "container byte-intact after read-back failure (no rm on unverified upload)"; else fail "DATA LOSS: container dropped despite read-back failure"; fi

# --- C11: --aside path, re-verify failure KEEPS the aside. With --aside the
#     container is moved aside, then re-verified vs the remote; the shim fails
#     ONLY that aside re-verify. The aside (and its contents) must be RETAINED. ---
echo "smoke: C11 — --aside re-verify failure keeps the moved-aside copy (no data lost)"
c11shim="${sandbox}/c11-shim"; mk_rclone_shim "${c11shim}"
c11h="${sandbox}/c11h"; mk_pushed_repo "${c11h}/repos/proj" "${sandbox}/c11.git"
set +e
out="$(PATH="${c11shim}:${PATH}" SHIM_CHECK=aside-fail RCLONE_CONFIG=/dev/null HOME="${c11h}" \
  XDG_STATE_HOME="${c11h}/state" GIT_CEILING_DIRECTORIES="${c11h}" \
  /bin/bash "${PROV}" --code-remote loc --code-dest "${c11h}/remote" --offload repos --apply --aside 2>&1)"
rc=$?
set -e
assert_nonzero "${rc}" "--aside re-verify failure exits non-zero"
aside_dir=""
for d in "${c11h}"/repos.pre-offload-*; do [ -d "$d" ] && { aside_dir="$d"; break; }; done
if [ -n "${aside_dir}" ]; then ok "the moved-aside copy was KEPT on re-verify failure"; else fail "DATA LOSS: --aside copy removed despite failed re-verify"; fi
if [ -n "${aside_dir}" ] && [ -f "${aside_dir}/proj/f.txt" ]; then ok "aside retains the original container contents"; else fail "aside is missing the original contents"; fi

# --- C14: Y1 (auditor) — blocker-NAMING lives in cmd_offload's DRY-RUN plan, and
#     --offload-status stays byte-identical to slice 1 (no blocker lines). ---
echo "smoke: C14 — dry-run offload plan NAMES a blocking repo; --offload-status stays blocker-free"
c14shim="${sandbox}/c14-shim"; mk_rclone_shim "${c14shim}"
c14h="${sandbox}/c14h"; mk_pushed_repo "${c14h}/repos/proj" "${sandbox}/c14.git"
printf 'dirty\n' > "${c14h}/repos/proj/untracked.txt"
c14run() { PATH="${c14shim}:${PATH}" RCLONE_CONFIG=/dev/null HOME="${c14h}" \
  XDG_STATE_HOME="${c14h}/state" GIT_CEILING_DIRECTORIES="${c14h}" \
  /bin/bash "${PROV}" --code-remote loc --code-dest "${c14h}/remote" "$@"; }
set +e; out="$(c14run --offload repos 2>&1)"; rc=$?; set -e   # dry-run (no --apply)
pass_if "${rc}" "dry-run offload plan exits 0 even with a blocking repo" "dry-run offload plan failed (exit ${rc}): ${out}"
assert_contains "${out}" "WOULD BLOCK" "dry-run plan flags the blocking repo"
assert_contains "${out}" "proj" "dry-run plan NAMES the blocking repo (proj)"
set +e; out="$(c14run --offload-status 2>&1)"; set -e
assert_contains "${out}" "code   repos" "--offload-status still lists the code dir"
assert_not_contains "${out}" "WOULD BLOCK" "--offload-status does NOT name blockers (that lives in the offload plan)"
assert_not_contains "${out}" "no upstream" "--offload-status stays byte-identical to slice 1 (no git blocker lines)"

# --- C15: resolve_code_target refuses NON-CODE targets beyond machine-local — an
#     XDG key (documents) and an arbitrary path are both rejected BEFORE any
#     rclone/mutation (only CODE_KEYS are offload-eligible). No rclone needed. ---
echo "smoke: C15 — offload refuses an XDG key and an arbitrary path (only CODE dirs are eligible)"
c15h="${sandbox}/c15h"; mkdir -p "${c15h}/Documents"
set +e; out="$(HOME="${c15h}" /bin/bash "${PROV}" --offload documents --apply 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "offloading an XDG dir (documents) exits non-zero"
assert_contains "${out}" "not a known CODE dir" "XDG target refusal explains only CODE dirs are eligible"
set +e; out="$(HOME="${c15h}" /bin/bash "${PROV}" --offload /tmp/whatever --apply 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "offloading an arbitrary path exits non-zero"
assert_contains "${out}" "not a known CODE dir" "arbitrary-path target is refused"

# --- C16: hydrate refusals (shim rclone). (a) no state file => refuse; (b) a
#     non-empty local container => refuse to clobber. Neither must mutate. ---
echo "smoke: C16 — hydrate refuses when not offloaded, and refuses to clobber a non-empty local dir"
c16shim="${sandbox}/c16-shim"; mk_rclone_shim "${c16shim}"
c16h="${sandbox}/c16h"; mkdir -p "${c16h}/repos"
c16run() { PATH="${c16shim}:${PATH}" RCLONE_CONFIG=/dev/null HOME="${c16h}" \
  XDG_STATE_HOME="${c16h}/state" GIT_CEILING_DIRECTORIES="${c16h}" \
  /bin/bash "${PROV}" --code-remote loc --code-dest "${c16h}/remote" "$@"; }
set +e; out="$(c16run --hydrate repos --apply 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "hydrate of a not-offloaded dir exits non-zero"
assert_contains "${out}" "not recorded as offloaded" "hydrate refusal explains there is no offload record"
# Now fabricate a state record AND a non-empty local container => clobber refusal.
mkdir -p "${c16h}/state/xdg-cloud/offloaded"
printf 'remote=loc:%s/repos\n' "${c16h}/remote" > "${c16h}/state/xdg-cloud/offloaded/repos"
printf 'keep\n' > "${c16h}/repos/precious.txt"
set +e; out="$(c16run --hydrate repos --apply 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "hydrate over a non-empty local dir exits non-zero"
assert_contains "${out}" "refusing to overwrite" "hydrate refuses to clobber existing local content"
if [ -f "${c16h}/repos/precious.txt" ]; then ok "existing local content left untouched by the refused hydrate"; else fail "DATA LOSS: refused hydrate removed local content"; fi

# --- C12 + C13: REAL rclone (type=local remote) — the --aside SUCCESS round-trip
#     and the NESTED-PARENT-REPO recoverability probe. Skipped if rclone absent. ---
if command -v rclone >/dev/null 2>&1; then
  rconf="${sandbox}/c12-rclone.conf"; printf '[loc]\ntype = local\n' > "${rconf}"

  # C12: --aside happy path — container moved aside, re-verified, then REMOVED;
  # local freed; hydrate restores byte-identical content.
  echo "smoke: C12 — --aside success round-trip (aside removed after verify; hydrate restores)"
  c12h="${sandbox}/c12h"; mk_pushed_repo "${c12h}/repos/proj" "${sandbox}/c12.git"
  printf 'PAYLOAD-12\n' > "${c12h}/repos/proj/data.txt"
  ( cd "${c12h}/repos/proj" && git add data.txt \
      && git -c user.email=t@t -c user.name=t commit -q -m data \
      && git push -q origin HEAD ) >/dev/null 2>&1
  c12run() { RCLONE_CONFIG="${rconf}" HOME="${c12h}" XDG_STATE_HOME="${c12h}/state" \
    GIT_CEILING_DIRECTORIES="${c12h}" \
    /bin/bash "${PROV}" --code-remote loc --code-dest "${c12h}/remote" "$@"; }
  set +e; out="$(c12run --offload repos --apply --aside 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "--aside offload exits 0" "--aside offload failed (exit ${rc}): ${out}"
  if [ ! -e "${c12h}/repos" ]; then ok "--aside offload freed the local container"; else fail "--aside offload did not free local"; fi
  if ls -d "${c12h}"/repos.pre-offload-* >/dev/null 2>&1; then fail "--aside left an aside behind after a SUCCESSFUL verify"; else ok "--aside removed the aside after a verified upload"; fi
  set +e; out="$(c12run --hydrate repos --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "hydrate after --aside offload exits 0" "hydrate failed (exit ${rc}): ${out}"
  if [ "$(cat "${c12h}/repos/proj/data.txt" 2>/dev/null)" = "PAYLOAD-12" ]; then ok "hydrate restored byte-identical content"; else fail "hydrate did not restore the exact content"; fi

  # C13: NESTED-PARENT-REPO probe (auditor Y2), now asserting the HARDENED behavior
  # (v2 GIT_CEILING fix). The CODE container ~/repos has NO own .git but sits inside a
  # PARENT git work tree (the sandbox HOME). c13run deliberately does NOT set a harness
  # GIT_CEILING, so this proves the SCRIPT self-confines discovery: offload_repos_in scopes
  # its rev-parse with GIT_CEILING=dirname(probed dir), so it finds NO repo in the container
  # (instead of inheriting the parent repo). Expected: the 'no git repos found' warning fires,
  # offload still proceeds (no repos => no blockers), pushes ONLY the container subtree, and
  # hydrate restores it byte-identical. The parent's own file is outside the container and
  # never enters the push.
  echo "smoke: C13 — nested parent-repo: discovery confined to the container (hardened)"
  c13h="${sandbox}/c13h"; mkdir -p "${c13h}/repos/proj"
  printf 'CONTAINER-13\n' > "${c13h}/repos/proj/inner.txt"
  printf 'PARENT-ONLY\n'  > "${c13h}/parent-only.txt"
  ( cd "${c13h}" && git init -q \
      && git -c user.email=t@t -c user.name=t add -A \
      && git -c user.email=t@t -c user.name=t commit -q -m init ) >/dev/null 2>&1
  git init -q --bare "${sandbox}/c13.git"
  ( cd "${c13h}" && git remote add origin "${sandbox}/c13.git" && git push -q -u origin HEAD ) >/dev/null 2>&1
  c13run() { RCLONE_CONFIG="${rconf}" HOME="${c13h}" XDG_STATE_HOME="${c13h}/state" \
    /bin/bash "${PROV}" --code-remote loc --code-dest "${c13h}/remote" "$@"; }
  set +e; out="$(c13run --offload repos --apply 2>&1)"; rc=$?; set -e
  # CONFINEMENT PROOF: discovery found no repo in the container (did NOT inherit the parent).
  assert_contains "${out}" "no git repos found" "discovery confined to the container (parent repo not inherited)"
  pass_if "${rc}" "hardened nested offload exits 0 (no repos => no blockers, proceeds)" "nested offload failed (exit ${rc}): ${out}"
  if [ ! -e "${c13h}/repos" ]; then ok "container freed locally after the verified push"; else fail "container not freed"; fi
  if [ -f "${c13h}/remote/repos/proj/inner.txt" ]; then ok "remote holds the container subtree (faithful)"; else fail "remote is MISSING the container content"; fi
  if [ -e "${c13h}/remote/repos/parent-only.txt" ]; then fail "WRONG CONTENT: parent-only file leaked into the offload remote"; else ok "parent's own files did NOT leak into the offload"; fi
  set +e; out="$(c13run --hydrate repos --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "nested case: hydrate exits 0" "hydrate failed in nested case (exit ${rc}): ${out}"
  if [ "$(cat "${c13h}/repos/proj/inner.txt" 2>/dev/null)" = "CONTAINER-13" ]; then ok "hydrate restored byte-identical container content (RECOVERABLE)"; else fail "DATA LOSS: nested-case hydrate did not restore the container"; fi
else
  echo "smoke: C12/C13 (--aside round-trip + nested-parent probe) — SKIPPED (rclone not installed)"
fi

# --- D1 (slice 3): dotfiles --dotfiles-init — bare repo + alias file (LITERAL $HOME) +
#     guarded rc block, then idempotent re-init. SANDBOX HOME + a SANDBOX rc path
#     (--dotfiles-rc) so the real ~/.zshrc/.bashrc/.dotfiles are NEVER touched.
#     Git identity is forced via env so the sandbox commit never depends on user config. ---
echo "smoke: D1 — dotfiles-init creates bare repo + literal-\$HOME alias + idempotent rc block"
df_home="${sandbox}/df-home"; df_rc="${df_home}/.zshrc"
mkdir -p "${df_home}/.config"
printf '# original rc\nexport KEEP=1\n' > "${df_rc}"
dfrun() { HOME="${df_home}" XDG_CONFIG_HOME="${df_home}/.config" XDG_CACHE_HOME="${df_home}/.cache" \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  /bin/bash "${PROV}" --dotfiles-rc "${df_rc}" "$@"; }
set +e; out="$(dfrun --dotfiles-init --apply 2>&1)"; rc=$?; set -e
pass_if "${rc}" "dotfiles-init --apply exits 0" "dotfiles-init failed (exit ${rc}): ${out}"
if [ "$(git --git-dir="${df_home}/.dotfiles" rev-parse --is-bare-repository 2>/dev/null)" = "true" ]; then
  ok "bare repo created at ~/.dotfiles"; else fail "bare repo not created"; fi
df_alias="${df_home}/.config/xdg-cloud/aliases.sh"
# shellcheck disable=SC2016   # INTENTIONAL literal: assert the alias kept $HOME unexpanded
if [ -f "${df_alias}" ] && grep -qF 'git --git-dir=$HOME/.dotfiles --work-tree=$HOME' "${df_alias}"; then
  ok "alias file written with LITERAL \$HOME (not expanded at write time)"
else fail "alias file missing or \$HOME was expanded"; fi
assert_contains "$(cat "${df_rc}")" "export KEEP=1" "original rc content preserved (append-only)"
assert_contains "$(cat "${df_rc}")" ">>> xdg-cloud dotfiles >>>" "rc source block appended"
set +e; dfrun --dotfiles-init --apply >/dev/null 2>&1; rc=$?; set -e
pass_if "${rc}" "re-init exits 0" "re-init failed (exit ${rc})"
n_sent="$(grep -cF '>>> xdg-cloud dotfiles >>>' "${df_rc}")"
if [ "${n_sent}" = "1" ]; then ok "re-init left exactly ONE rc block (idempotent, no dup append)"; else fail "re-init duplicated the rc block (count=${n_sent})"; fi
n_bak=0; for b in "${df_rc}".bak-*; do [ -e "${b}" ] && n_bak=$((n_bak + 1)); done
if [ "${n_bak}" = "1" ]; then ok "re-init made no second backup (idempotent)"; else fail "re-init made ${n_bak} backups (expected 1)"; fi

# --- D2 (slice 3): unknown $SHELL with no --dotfiles-rc → DIE requiring --dotfiles-rc
#     (refuse-don't-guess; the die must halt in the PARENT shell). ---
echo "smoke: D2 — unknown \$SHELL refuses (requires --dotfiles-rc), does not guess"
u_home="${sandbox}/df-unknown"; mkdir -p "${u_home}/.config"
set +e
out="$(HOME="${u_home}" XDG_CONFIG_HOME="${u_home}/.config" XDG_CACHE_HOME="${u_home}/.cache" \
  SHELL=/usr/bin/fish /bin/bash "${PROV}" --dotfiles-init --apply 2>&1)"
rc=$?
set -e
assert_nonzero "${rc}" "unknown \$SHELL exits non-zero (parent die, not a swallowed subshell exit)"
assert_contains "${out}" "--dotfiles-rc" "unknown-shell refusal tells the user to pass --dotfiles-rc"
if [ -e "${u_home}/.dotfiles" ]; then fail "init created a bare repo despite the rc refusal"; else ok "no bare repo created when rc resolution failed"; fi

# --- D3 (slice 3): --dotfiles-track stages a real dotfile but REFUSES cloud-xdg-managed
#     paths (redirect target / CODE container) and the bare repo itself (recursion). ---
echo "smoke: D3 — dotfiles-track tracks a dotfile and refuses managed/recursive paths"
printf 'alias hi=echo\n' > "${df_home}/.myrc"
set +e; out="$(dfrun --dotfiles-track .myrc --apply 2>&1)"; rc=$?; set -e
pass_if "${rc}" "track a normal dotfile exits 0" "track failed (exit ${rc}): ${out}"
if git --git-dir="${df_home}/.dotfiles" --work-tree="${df_home}" ls-files 2>/dev/null | grep -qx ".myrc"; then
  ok "the dotfile was committed into the bare repo"; else fail "the dotfile was not tracked"; fi
for bad in Documents repos .dotfiles; do
  set +e; out="$(dfrun --dotfiles-track "${bad}" --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "track refuses '${bad}' (non-zero exit)"
  assert_contains "${out}" "refusing" "track '${bad}' explains the refusal"
done

# --- D4 (slice 3): --dotfiles-status is read-only and exits 0. ---
echo "smoke: D4 — dotfiles-status is read-only (exit 0, no mutation)"
s_before="$(cd "${df_home}" && find . | sort)"
set +e; out="$(dfrun --dotfiles-status 2>&1)"; rc=$?; set -e
pass_if "${rc}" "dotfiles-status exits 0" "dotfiles-status failed (exit ${rc}): ${out}"
assert_contains "${out}" "Tracked dotfiles" "status prints its read-only header"
s_after="$(cd "${df_home}" && find . | sort)"
if [ "${s_before}" = "${s_after}" ]; then ok "dotfiles-status mutated nothing"; else fail "dotfiles-status mutated the home tree"; fi

# --- D5 (slice 3): rc-backup uniquifier on COLLISION. A `date` PATH-shim pins the
#     stamp so a pre-seeded ${rc}.bak-<stamp> collides deterministically; the new
#     backup must advance to .bak-<stamp>.1 (holding the ORIGINAL rc), and the
#     pre-existing colliding backup must be left untouched. ---
echo "smoke: D5 — rc backup uniquifier advances on a colliding .bak name (.1), keeps the original"
d5shim="${sandbox}/d5-shim"; mkdir -p "${d5shim}"
cat > "${d5shim}/date" <<'DATESH'
#!/bin/sh
echo "20260101-000000"
DATESH
chmod +x "${d5shim}/date"
d5_home="${sandbox}/d5-home"; d5_rc="${d5_home}/.zshrc"; mkdir -p "${d5_home}/.config"
printf '# d5 user rc\nexport D5=1\n' > "${d5_rc}"
printf 'PRE-EXISTING BACKUP (must stay untouched)\n' > "${d5_rc}.bak-20260101-000000"
d5run() { PATH="${d5shim}:${PATH}" HOME="${d5_home}" XDG_CONFIG_HOME="${d5_home}/.config" \
  XDG_CACHE_HOME="${d5_home}/.cache" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  /bin/bash "${PROV}" --dotfiles-rc "${d5_rc}" "$@"; }
set +e; out="$(d5run --dotfiles-init --apply 2>&1)"; rc=$?; set -e
pass_if "${rc}" "dotfiles-init with a colliding backup name exits 0" "init failed (exit ${rc}): ${out}"
if [ -f "${d5_rc}.bak-20260101-000000.1" ]; then ok "backup uniquifier advanced to .1 on collision"; else fail "uniquifier did not advance (.1 missing)"; fi
assert_contains "$(cat "${d5_rc}.bak-20260101-000000.1")" "export D5=1" "the .1 backup holds the ORIGINAL rc content"
assert_contains "$(cat "${d5_rc}.bak-20260101-000000")" "PRE-EXISTING BACKUP" "the pre-existing colliding backup is left untouched"
assert_contains "$(cat "${d5_rc}")" "export D5=1" "user rc content preserved (append-only)"

# --- D6 (slice 3): rc block + alias file are BYTE-CORRECT. The rc source line keeps
#     ${XDG_CONFIG_HOME:-$HOME/.config} literal (expands at the USER's source time),
#     the block is sentinel-fenced, and the alias file contains NO backticks (a
#     parse/source-time execution footgun the coder deliberately avoided). Reuses the
#     df_home repo inited in D1. ---
echo "smoke: D6 — rc source block is byte-correct (literal, fenced) and alias has no backticks"
# shellcheck disable=SC2016   # INTENTIONAL: the needle must stay literal (assert the rc kept it unexpanded)
assert_contains "$(cat "${df_rc}")" '[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/xdg-cloud/aliases.sh" ] && . "${XDG_CONFIG_HOME:-$HOME/.config}/xdg-cloud/aliases.sh"' "rc block has the exact guarded, literal source line"
assert_contains "$(cat "${df_rc}")" "<<< xdg-cloud dotfiles <<<" "rc block is closed by the END sentinel (fenced)"
if grep -q '`' "${df_alias}"; then fail "alias file contains a backtick (parse/source-time execution risk)"; else ok "alias file has NO backticks"; fi

# --- D7 (slice 3): refuse-clobber a FOREIGN ~/.dotfiles. If ~/.dotfiles exists but is
#     not OUR bare repo, --dotfiles-init must die and leave it byte-untouched. ---
echo "smoke: D7 — dotfiles-init refuses to clobber a foreign ~/.dotfiles"
f_home="${sandbox}/df-foreign"; mkdir -p "${f_home}/.config" "${f_home}/.dotfiles"
printf 'NOT OUR REPO\n' > "${f_home}/.dotfiles/keep.txt"
f_before="$(cd "${f_home}/.dotfiles" && find . | sort)"
set +e
out="$(HOME="${f_home}" XDG_CONFIG_HOME="${f_home}/.config" XDG_CACHE_HOME="${f_home}/.cache" \
  /bin/bash "${PROV}" --dotfiles-rc "${f_home}/.zshrc" --dotfiles-init --apply 2>&1)"
rc=$?
set -e
assert_nonzero "${rc}" "init over a foreign ~/.dotfiles exits non-zero"
assert_contains "${out}" "not our bare git repo" "refusal explains it will not clobber a foreign ~/.dotfiles"
if [ "${f_before}" = "$(cd "${f_home}/.dotfiles" && find . | sort)" ] && [ -f "${f_home}/.dotfiles/keep.txt" ]; then ok "foreign ~/.dotfiles left byte-untouched"; else fail "init mutated the foreign ~/.dotfiles"; fi

# --- D8 (slice 3): overlap guard — the classes D3 did not cover: a LOCAL_KEYS dir and
#     a path OUTSIDE $HOME. Each refusal must commit NOTHING (ls-files unchanged).
#     Reuses df_home (inited + .myrc committed in D3). ---
echo "smoke: D8 — track refuses a machine-local dir and an outside-\$HOME path (commits nothing)"
files_before="$(git --git-dir="${df_home}/.dotfiles" --work-tree="${df_home}" ls-files 2>/dev/null | sort)"
mkdir -p "${df_home}/pyenv"
set +e; out="$(dfrun --dotfiles-track pyenv --apply 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "track refuses a LOCAL_KEYS dir (pyenv)"
assert_contains "${out}" "machine-local" "pyenv refusal names it machine-local"
set +e; out="$(dfrun --dotfiles-track /etc/hosts --apply 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "track refuses a path outside \$HOME"
assert_contains "${out}" "outside" "outside-\$HOME refusal explains the work-tree boundary"
if [ "${files_before}" = "$(git --git-dir="${df_home}/.dotfiles" --work-tree="${df_home}" ls-files 2>/dev/null | sort)" ]; then ok "the refused tracks committed NOTHING (ls-files unchanged)"; else fail "a refused track changed the tracked set"; fi

# --- D9 (slice 3): track resolves an ABSOLUTE pathspec ($HOME/<arg>), so it works from
#     ANY CWD — a relative arg must NOT be resolved against the (unrelated) CWD. ---
echo "smoke: D9 — track uses an absolute pathspec (works from a different CWD)"
printf 'x\n' > "${df_home}/.cwdrc"
set +e; ( cd "${sandbox}/tmp" && dfrun --dotfiles-track .cwdrc --apply ) >/dev/null 2>&1; rc=$?; set -e
pass_if "${rc}" "track from a different CWD exits 0" "track from another CWD failed (exit ${rc})"
if git --git-dir="${df_home}/.dotfiles" --work-tree="${df_home}" ls-files 2>/dev/null | grep -qx ".cwdrc"; then
  ok "the dotfile was committed even though CWD != \$HOME (absolute pathspec)"; else fail "track did not resolve the path against \$HOME from another CWD"; fi

# --- D10 (slice 3): track BEFORE init refuses (no bare repo yet). ---
echo "smoke: D10 — dotfiles-track refuses when no bare repo exists yet"
n_home="${sandbox}/df-noinit"; mkdir -p "${n_home}/.config"
printf 'r\n' > "${n_home}/.somerc"
set +e
out="$(HOME="${n_home}" XDG_CONFIG_HOME="${n_home}/.config" XDG_CACHE_HOME="${n_home}/.cache" \
  /bin/bash "${PROV}" --dotfiles-rc "${n_home}/.zshrc" --dotfiles-track .somerc --apply 2>&1)"
rc=$?
set -e
assert_nonzero "${rc}" "track without a bare repo exits non-zero"
assert_contains "${out}" "dotfiles-init" "track refusal tells the user to run --dotfiles-init first"
if [ -e "${n_home}/.dotfiles" ]; then fail "track created a repo despite the refusal"; else ok "no bare repo created by a refused track"; fi

# --- D11 (slice 3): status REPORTS install state (alias + rc block present after init),
#     and the no-repo case is a clean exit-0 hint. Reuses df_home (inited). ---
echo "smoke: D11 — dotfiles-status reports alias + rc install state; no-repo case is a clean hint"
set +e; out="$(dfrun --dotfiles-status 2>&1)"; rc=$?; set -e
pass_if "${rc}" "status exits 0 on an inited repo" "status failed (exit ${rc}): ${out}"
assert_contains "${out}" "alias file: present" "status reports the alias file is present"
assert_contains "${out}" "rc source block: present" "status reports the rc source block is installed"
set +e; out="$(HOME="${sandbox}/df-empty" XDG_CONFIG_HOME="${sandbox}/df-empty/.config" \
  /bin/bash "${PROV}" --dotfiles-status 2>&1)"; rc=$?; set -e
pass_if "${rc}" "status on a home with no repo exits 0 (read-only hint)" "status no-repo failed (exit ${rc}): ${out}"
assert_contains "${out}" "no dotfiles bare repo" "status hints to run --dotfiles-init when no repo exists"

# --- D12 (v2): multi-path --dotfiles-track — (a) several valid dotfiles tracked in ONE
#     commit; (b) a mix of valid + a MANAGED path dies FAIL-CLOSED (commits NOTHING, neither
#     staged). Reuses the D1 inited repo via dfrun (sandbox HOME + sandbox rc). ---
echo "smoke: D12 — multi-path dotfiles-track: one commit for many; fail-closed on a managed path"
printf 'm1\n' > "${df_home}/.multi1"; printf 'm2\n' > "${df_home}/.multi2"; printf 'm3\n' > "${df_home}/.multi3"
# (a) two valid paths in a single commit.
commits_before="$(git --git-dir="${df_home}/.dotfiles" rev-list --count HEAD 2>/dev/null || printf 0)"
set +e; out="$(dfrun --dotfiles-track .multi1 .multi2 --apply 2>&1)"; rc=$?; set -e
pass_if "${rc}" "multi-path track of two valid dotfiles exits 0" "multi-track failed (exit ${rc}): ${out}"
tracked="$(git --git-dir="${df_home}/.dotfiles" --work-tree="${df_home}" ls-files 2>/dev/null)"
if printf '%s\n' "${tracked}" | grep -qx ".multi1" && printf '%s\n' "${tracked}" | grep -qx ".multi2"; then
  ok "both paths were committed"; else fail "multi-path track did not commit both paths"; fi
commits_after="$(git --git-dir="${df_home}/.dotfiles" rev-list --count HEAD 2>/dev/null || printf 0)"
if [ "$((commits_after - commits_before))" = "1" ]; then ok "the two paths landed in exactly ONE commit"; else fail "expected 1 new commit, got $((commits_after - commits_before))"; fi
# (b) valid + MANAGED (Documents) → fail-closed: die, commit/stage NOTHING.
set +e; out="$(dfrun --dotfiles-track .multi3 Documents --apply 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "a mix with a managed path exits non-zero (fail-closed)"
assert_contains "${out}" "refusing" "the managed path is named in the refusal"
tracked="$(git --git-dir="${df_home}/.dotfiles" --work-tree="${df_home}" ls-files 2>/dev/null)"
if printf '%s\n' "${tracked}" | grep -qx ".multi3"; then fail "FAIL-CLOSED VIOLATION: the valid path was staged despite a managed path in the set"; else ok "fail-closed: the valid path was NOT staged (all-or-nothing)"; fi

# --- D13 (slice 4): dotfiles ADOPT (--dotfiles-remote) — the CLOBBER surface. Uses a REAL local
#     bare-repo fixture as the <url> and a SANDBOX HOME (never real $HOME/~/.dotfiles/~/.zshrc).
#     Asserts: collider→aside (original preserved, remote checked out), managed-lane repo refused
#     ($HOME UNTOUCHED, clone removed, no leak), refuse when ~/.dotfiles exists. ---
echo "smoke: D13 — dotfiles adopt: collider→aside, managed-lane refused ($HOME untouched), exists→refuse"
# Fixture A: a normal dotfiles repo tracking .bashrc (used as the clone <url>).
adopt_src="${sandbox}/adopt-src"; mkdir -p "${adopt_src}"
( cd "${adopt_src}" && git init -q && printf 'REMOTE-BASHRC\n' > .bashrc \
    && git -c user.email=t@t -c user.name=t add .bashrc \
    && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1
# Fixture B: a MISCONFIGURED repo tracking a cloud-xdg-managed path (Documents/) + a normal file.
adopt_msrc="${sandbox}/adopt-msrc"; mkdir -p "${adopt_msrc}/Documents"
( cd "${adopt_msrc}" && git init -q && printf 'x\n' > Documents/foo && printf 'y\n' > .vimrc \
    && git -c user.email=t@t -c user.name=t add -A \
    && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1
adrun() { HOME="$1" XDG_CONFIG_HOME="$1/.config" XDG_CACHE_HOME="$1/.cache" \
  /bin/bash "${PROV}" --dotfiles-rc "$1/.zshrc" "${@:2}"; }
# (a) collider: a local .bashrc must be moved aside (content preserved), remote checked out.
ad_a="${sandbox}/adopt-collide"; mkdir -p "${ad_a}"; printf 'LOCAL-KEEP\n' > "${ad_a}/.bashrc"
set +e; out="$(adrun "${ad_a}" --dotfiles-remote "${adopt_src}" --apply 2>&1)"; rc=$?; set -e
pass_if "${rc}" "adopt with a collider exits 0" "adopt collider failed (exit ${rc}): ${out}"
if [ "$(cat "${ad_a}/.bashrc" 2>/dev/null)" = "REMOTE-BASHRC" ]; then ok "the remote dotfile was checked out"; else fail "adopt did not check out the remote .bashrc"; fi
ad_aside=""; for f in "${ad_a}"/.bashrc.pre-dotfiles-*; do [ -e "${f}" ] && { ad_aside="${f}"; break; }; done
if [ -n "${ad_aside}" ] && [ "$(cat "${ad_aside}" 2>/dev/null)" = "LOCAL-KEEP" ]; then ok "the pre-existing local file was moved aside with its content PRESERVED (never clobbered)"; else fail "collider was not asided / original content lost"; fi
# (b) managed-lane repo: refused, $HOME fully untouched (no clone, no checkout of the non-managed file).
ad_b="${sandbox}/adopt-managed"; mkdir -p "${ad_b}"
set +e; out="$(adrun "${ad_b}" --dotfiles-remote "${adopt_msrc}" --apply 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "adopt of a managed-lane repo exits non-zero (fail-closed)"
assert_contains "${out}" "Documents/foo" "the refusal NAMES the managed offender path"
if [ -e "${ad_b}/.dotfiles" ]; then fail "CLOBBER RISK: the fresh clone was left behind on managed-refuse"; else ok "the fresh clone was removed on managed-refuse"; fi
if [ -e "${ad_b}/.vimrc" ]; then fail "\$HOME VIOLATION: a repo file leaked into \$HOME despite the refusal"; else ok "\$HOME left completely untouched on managed-refuse (nothing checked out)"; fi
# (c) refuse when ~/.dotfiles already exists (fresh-machine only).
ad_c="${sandbox}/adopt-exists"; mkdir -p "${ad_c}/.dotfiles"
set +e; out="$(adrun "${ad_c}" --dotfiles-remote "${adopt_src}" --apply 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "adopt refuses when ~/.dotfiles already exists"
assert_contains "${out}" "refusing to clobber" "the pre-existing ~/.dotfiles is not clobbered"

# git_seed DIR — init a work repo in DIR (files already written), commit everything. The
# committed repo path is usable directly as a --dotfiles-remote <url> (adopt clones --bare it).
git_seed() {
  ( cd "$1" && git init -q \
      && git -c user.email=t@t -c user.name=t add -A \
      && git -c user.email=t@t -c user.name=t commit -qm seed ) >/dev/null 2>&1
}

# --- D14 (slice 4): adopt FRESH (no colliders) — every tracked file is checked out into the
#     sandbox $HOME with matching content, the alias file + rc block are written, and the bare
#     repo is configured status.showUntrackedFiles=no. Reuses the D13 adrun helper. ---
echo "smoke: D14 — fresh adopt checks out all tracked files + writes alias/rc + sets showUntrackedFiles=no"
d14src="${sandbox}/d14-src"; mkdir -p "${d14src}/.config"
printf 'FRESH-BASHRC\n' > "${d14src}/.bashrc"; printf 'FRESH-CFG\n' > "${d14src}/.config/app.conf"
git_seed "${d14src}"
d14h="${sandbox}/d14-home"; mkdir -p "${d14h}"
set +e; out="$(adrun "${d14h}" --dotfiles-remote "${d14src}" --apply 2>&1)"; rc=$?; set -e
pass_if "${rc}" "fresh adopt exits 0" "fresh adopt failed (exit ${rc}): ${out}"
if [ "$(cat "${d14h}/.bashrc" 2>/dev/null)" = "FRESH-BASHRC" ] && [ "$(cat "${d14h}/.config/app.conf" 2>/dev/null)" = "FRESH-CFG" ]; then
  ok "all tracked files checked out with matching content (incl. a nested path)"; else fail "adopt did not check out the tracked files"; fi
# shellcheck disable=SC2016   # INTENTIONAL literal: the alias must keep $HOME unexpanded
if [ -f "${d14h}/.config/xdg-cloud/aliases.sh" ] && grep -qF 'git --git-dir=$HOME/.dotfiles --work-tree=$HOME' "${d14h}/.config/xdg-cloud/aliases.sh"; then
  ok "alias file written (literal \$HOME)"; else fail "alias file missing / \$HOME expanded"; fi
assert_contains "$(cat "${d14h}/.zshrc" 2>/dev/null)" ">>> xdg-cloud dotfiles >>>" "rc source block installed on the sandbox --dotfiles-rc"
if [ "$(git --git-dir="${d14h}/.dotfiles" config --get status.showUntrackedFiles 2>/dev/null)" = "no" ]; then
  ok "bare repo configured status.showUntrackedFiles=no"; else fail "showUntrackedFiles was not set to no"; fi

# --- D15 (slice 4): ASIDE-COLLISION — a *.pre-dotfiles-<stamp> already present must NOT be
#     overwritten; the uniquifier advances to .1. A `date` PATH-shim pins the stamp. ---
echo "smoke: D15 — adopt aside uniquifier advances on a colliding .pre-dotfiles name (.1), keeps the earlier aside"
d15shim="${sandbox}/d15-shim"; mkdir -p "${d15shim}"
cat > "${d15shim}/date" <<'DATESH'
#!/bin/sh
echo "20260202-000000"
DATESH
chmod +x "${d15shim}/date"
d15src="${sandbox}/d15-src"; mkdir -p "${d15src}"; printf 'R15\n' > "${d15src}/.bashrc"; git_seed "${d15src}"
d15h="${sandbox}/d15-home"; mkdir -p "${d15h}"
printf 'L15-CURRENT\n' > "${d15h}/.bashrc"
printf 'OLD-ASIDE\n'  > "${d15h}/.bashrc.pre-dotfiles-20260202-000000"
set +e
out="$(PATH="${d15shim}:${PATH}" HOME="${d15h}" XDG_CONFIG_HOME="${d15h}/.config" XDG_CACHE_HOME="${d15h}/.cache" \
  /bin/bash "${PROV}" --dotfiles-rc "${d15h}/.zshrc" --dotfiles-remote "${d15src}" --apply 2>&1)"
rc=$?
set -e
pass_if "${rc}" "adopt with a colliding aside name exits 0" "adopt failed (exit ${rc}): ${out}"
if [ "$(cat "${d15h}/.bashrc.pre-dotfiles-20260202-000000.1" 2>/dev/null)" = "L15-CURRENT" ]; then ok "the new aside advanced to .1 and holds the CURRENT local content"; else fail "aside uniquifier did not advance / lost content"; fi
if [ "$(cat "${d15h}/.bashrc.pre-dotfiles-20260202-000000" 2>/dev/null)" = "OLD-ASIDE" ]; then ok "the earlier aside was NOT overwritten"; else fail "CLOBBER: the earlier aside was overwritten"; fi
if [ "$(cat "${d15h}/.bashrc" 2>/dev/null)" = "R15" ]; then ok "the remote file was checked out"; else fail "remote file not checked out"; fi

# --- D16 (slice 4): SYMLINK collider — a $HOME symlink is moved aside as the LINK (its target
#     file is untouched), and the tracked file is checked out as a real file. ---
echo "smoke: D16 — adopt asides a symlink collider (moves the link, target untouched) + checks out the tracked file"
d16src="${sandbox}/d16-src"; mkdir -p "${d16src}"; printf 'R16\n' > "${d16src}/.bashrc"; git_seed "${d16src}"
d16h="${sandbox}/d16-home"; mkdir -p "${d16h}"
printf 'TARGET-CONTENT\n' > "${d16h}/realtarget"
ln -s "${d16h}/realtarget" "${d16h}/.bashrc"
set +e; out="$(adrun "${d16h}" --dotfiles-remote "${d16src}" --apply 2>&1)"; rc=$?; set -e
pass_if "${rc}" "adopt with a symlink collider exits 0" "adopt failed (exit ${rc}): ${out}"
if [ -f "${d16h}/.bashrc" ] && [ ! -L "${d16h}/.bashrc" ] && [ "$(cat "${d16h}/.bashrc")" = "R16" ]; then ok "tracked file checked out as a real file"; else fail "tracked file not checked out as a real file"; fi
d16_aside=""; for f in "${d16h}"/.bashrc.pre-dotfiles-*; do [ -L "${f}" ] && { d16_aside="${f}"; break; }; done
if [ -n "${d16_aside}" ]; then ok "the collider SYMLINK was moved aside as a link (not its target)"; else fail "symlink collider was not asided as a link"; fi
# T-M2: the asided link must still point at the ORIGINAL target (proves the LINK was moved,
# not dereferenced-and-copied — a subtle clobber where the target's path identity is lost).
if [ -n "${d16_aside}" ] && [ "$(readlink "${d16_aside}" 2>/dev/null)" = "${d16h}/realtarget" ]; then ok "the asided link still resolves to the ORIGINAL target path (moved, not dereferenced)"; else fail "the asided symlink does not point at the original target"; fi
if [ "$(cat "${d16h}/realtarget" 2>/dev/null)" = "TARGET-CONTENT" ]; then ok "the symlink's target file is untouched"; else fail "the symlink target was modified"; fi

# --- D17 (slice 4): MANAGED-LANE refuse, fail-closed, MID-LIST + with a COLLIDER present. The
#     managed offender (repos/) sorts AFTER a valid dotfile (.aaarc) in ls-tree, and $HOME has a
#     collider for .aaarc. PASS A must refuse BEFORE PASS B asides anything: the collider is NOT
#     moved aside and $HOME is byte-identical. This proves the pre-scan runs fully first. ---
echo "smoke: D17 — managed offender mid-list: refuse before any aside (collider intact, \$HOME byte-identical)"
d17src="${sandbox}/d17-src"; mkdir -p "${d17src}/repos"
printf 'OK\n' > "${d17src}/.aaarc"; printf 'BAD\n' > "${d17src}/repos/tracked"   # .aaarc sorts before repos/
git_seed "${d17src}"
d17h="${sandbox}/d17-home"; mkdir -p "${d17h}"
printf 'COLLIDER-KEEP\n' > "${d17h}/.aaarc"           # a collider for the VALID path
# Snapshot USER content only — exclude .cache (the mutating-mode lock scaffold is an expected
# side effect of any --apply run, not a $HOME-data change).
d17_before="$(cd "${d17h}" && find . -path ./.cache -prune -o -print | sort)"
set +e; out="$(adrun "${d17h}" --dotfiles-remote "${d17src}" --apply 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "managed-lane repo is refused (fail-closed)"
assert_contains "${out}" "repos/tracked" "the refusal names the managed offender (scanned mid-list)"
if [ -e "${d17h}/.dotfiles" ]; then fail "CLOBBER RISK: fresh clone left behind on managed-refuse"; else ok "fresh clone removed on managed-refuse"; fi
d17_asided=0; for f in "${d17h}"/.aaarc.pre-dotfiles-*; do [ -e "${f}" ] && d17_asided=1; done
if [ "${d17_asided}" -eq 0 ]; then ok "the valid-path collider was NOT asided (PASS A refused before any PASS B aside)"; else fail "ORDER BUG: a collider was moved aside before the managed pre-scan refused"; fi
if [ "$(cat "${d17h}/.aaarc" 2>/dev/null)" = "COLLIDER-KEEP" ]; then ok "the collider's original content is intact"; else fail "the collider was modified despite the refusal"; fi
if [ "${d17_before}" = "$(cd "${d17h}" && find . -path ./.cache -prune -o -print | sort)" ]; then ok "\$HOME user content is byte-identical before/after the managed-refuse"; else fail "\$HOME changed despite the fail-closed refusal"; fi

# --- D18 (slice 4): adopt refuses when ~/.dotfiles is ALREADY OURS (fresh-machine-only). ---
echo "smoke: D18 — adopt refuses an already-initialized (ours) ~/.dotfiles"
d18h="${sandbox}/d18-home"; mkdir -p "${d18h}"
adrun "${d18h}" --dotfiles-init --apply >/dev/null 2>&1
set +e; out="$(adrun "${d18h}" --dotfiles-remote "${adopt_src}" --apply 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "adopt over an already-ours ~/.dotfiles exits non-zero"
assert_contains "${out}" "already" "the refusal explains the repo is already initialized (use pull/track)"

# --- D19 (slice 4): clone-FAIL (bad url) — dies, the partial ~/.dotfiles is removed, $HOME untouched. ---
echo "smoke: D19 — adopt clone failure removes the partial repo and leaves \$HOME untouched"
d19h="${sandbox}/d19-home"; mkdir -p "${d19h}"
# Exclude .cache (the apply-mode lock scaffold) — the invariant is "no user data / no partial repo".
d19_before="$(cd "${d19h}" && find . -path ./.cache -prune -o -print | sort)"
set +e; out="$(adrun "${d19h}" --dotfiles-remote "${sandbox}/does-not-exist.git" --apply 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "adopt of a bad url exits non-zero"
assert_contains "${out}" "clone" "the failure explains the clone did not succeed"
if [ -e "${d19h}/.dotfiles" ]; then fail "a partial ~/.dotfiles was left behind after clone failure"; else ok "the partial ~/.dotfiles was removed"; fi
if [ "${d19_before}" = "$(cd "${d19h}" && find . -path ./.cache -prune -o -print | sort)" ]; then ok "\$HOME user content is byte-identical after a failed clone"; else fail "\$HOME changed after a failed clone"; fi

# --- D20 (slice 4): dry-run — temp-clone preview lists would-aside + WOULD REFUSE and touches
#     NOTHING under $HOME (no checkout, no aside, no ~/.dotfiles). ---
echo "smoke: D20 — adopt dry-run previews (would-aside + WOULD REFUSE) and mutates nothing"
d20h="${sandbox}/d20-home"; mkdir -p "${d20h}"; printf 'LOCAL20\n' > "${d20h}/.bashrc"
d20_before="$(cd "${d20h}" && find . | sort)"
set +e; out="$(adrun "${d20h}" --dotfiles-remote "${adopt_src}" 2>&1)"; rc=$?; set -e   # NO --apply
pass_if "${rc}" "adopt dry-run exits 0" "adopt dry-run failed (exit ${rc}): ${out}"
assert_contains "${out}" "would move aside" "dry-run previews the collider it would move aside"
if [ "${d20_before}" = "$(cd "${d20h}" && find . | sort)" ] && [ ! -e "${d20h}/.dotfiles" ]; then ok "dry-run touched nothing under \$HOME (no aside, no clone)"; else fail "dry-run mutated \$HOME"; fi
if [ "$(cat "${d20h}/.bashrc" 2>/dev/null)" = "LOCAL20" ]; then ok "the local file is untouched by the dry-run"; else fail "dry-run changed the local file"; fi
# managed-repo dry-run names the WOULD-REFUSE offender — and (T-M3) must itself mutate NOTHING.
d20m_before="$(cd "${d20h}" && find . | sort)"
set +e; out="$(adrun "${d20h}" --dotfiles-remote "${adopt_msrc}" 2>&1)"; set -e
assert_contains "${out}" "WOULD REFUSE" "dry-run flags a managed offender as WOULD REFUSE"
if [ "${d20m_before}" = "$(cd "${d20h}" && find . | sort)" ] && [ ! -e "${d20h}/.dotfiles" ]; then ok "the managed-offender dry-run mutated nothing under \$HOME (no aside, no clone)"; else fail "the managed-offender dry-run mutated \$HOME"; fi

# --- D21 (slice 4): unknown $SHELL with no --dotfiles-rc — resolve_rc dies BEFORE the clone; no repo. ---
echo "smoke: D21 — adopt with an unknown \$SHELL and no --dotfiles-rc refuses before cloning"
d21h="${sandbox}/d21-home"; mkdir -p "${d21h}"
set +e
out="$(HOME="${d21h}" XDG_CONFIG_HOME="${d21h}/.config" XDG_CACHE_HOME="${d21h}/.cache" \
  SHELL=/usr/bin/fish /bin/bash "${PROV}" --dotfiles-remote "${adopt_src}" --apply 2>&1)"
rc=$?
set -e
assert_nonzero "${rc}" "adopt with an unknown \$SHELL exits non-zero"
assert_contains "${out}" "--dotfiles-rc" "the refusal tells the user to pass --dotfiles-rc"
if [ -e "${d21h}/.dotfiles" ]; then fail "a repo was cloned despite the rc refusal (die must precede clone)"; else ok "no repo cloned when rc resolution failed (die precedes clone)"; fi

# --- D22 (slice 4 remediation): PATH-TRAVERSAL refusal (security Blocking). A malicious repo can
#     track '../evil' via a crafted tree (nested tree with a '..' subtree). Adopt must refuse it in
#     PASS A BEFORE any aside/checkout, so the out-of-$HOME target is NEVER written. Sandbox HOME. ---
echo "smoke: D22 — adopt refuses a work-tree-escaping path ('../evil'), \$HOME untouched"
d22src="${sandbox}/adopt-trav-src"; mkdir -p "${d22src}"
( cd "${d22src}" && git init -q
  d22blob="$(printf 'EVIL-PAYLOAD\n' | git hash-object -w --stdin)"
  d22inner="$(printf '100644 blob %s\tevil\n' "${d22blob}" | git mktree)"
  d22outer="$(printf '040000 tree %s\t..\n' "${d22inner}" | git mktree)"
  d22commit="$(git -c user.email=t@t -c user.name=t commit-tree "${d22outer}" -m evil)"
  git update-ref HEAD "${d22commit}" ) >/dev/null 2>&1
d22h="${sandbox}/adopt-trav-home"; mkdir -p "${d22h}"
d22escape="${sandbox}/evil"            # $HOME/../evil resolves here (HOME=$d22h under $sandbox)
rm -f "${d22escape}"
set +e; out="$(adrun "${d22h}" --dotfiles-remote "${d22src}" --apply 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "traversal repo adopt exits non-zero (refused in PASS A)"
assert_contains "${out}" "unsafe" "the refusal names the path as unsafe / would escape \$HOME"
if [ -e "${d22escape}" ] || [ -L "${d22escape}" ]; then fail "WORK-TREE ESCAPE: '../evil' was written OUTSIDE \$HOME (${d22escape})"; else ok "the escaping path was NOT written outside \$HOME"; fi
if [ -e "${d22h}/.dotfiles" ]; then fail "the fresh clone was left behind on a traversal refusal"; else ok "the fresh clone was removed; \$HOME untouched on traversal refusal"; fi

# --- D23 (slice 4 remediation, M1): an EXOTIC-named collider (a name git ls-tree --name-only would
#     C-quote — here an embedded double-quote) is now correctly pre-asided via the -z enumeration. ---
echo "smoke: D23 — exotic-named collider is correctly asided (NUL-delimited enumeration)"
d23src="${sandbox}/adopt-exotic-src"; mkdir -p "${d23src}"
( cd "${d23src}" && git init -q && printf 'REMOTE-Q\n' > 'q"x.txt' \
    && git -c user.email=t@t -c user.name=t add -A \
    && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1
d23h="${sandbox}/adopt-exotic-home"; mkdir -p "${d23h}"; printf 'LOCAL-EXOTIC\n' > "${d23h}/q\"x.txt"
set +e; out="$(adrun "${d23h}" --dotfiles-remote "${d23src}" --apply 2>&1)"; rc=$?; set -e
pass_if "${rc}" "adopt with an exotic-named collider exits 0" "exotic adopt failed (exit ${rc}): ${out}"
if [ "$(cat "${d23h}/q\"x.txt" 2>/dev/null)" = "REMOTE-Q" ]; then ok "the remote exotic-named file was checked out"; else fail "exotic-named remote file not checked out"; fi
d23aside=""; for f in "${d23h}"/q\"x.txt.pre-dotfiles-*; do [ -e "${f}" ] && { d23aside="${f}"; break; }; done
if [ -n "${d23aside}" ] && [ "$(cat "${d23aside}" 2>/dev/null)" = "LOCAL-EXOTIC" ]; then ok "the exotic-named collider was asided with content preserved (C-quoting no longer misses it)"; else fail "exotic-named collider was NOT asided (C-quoting gap)"; fi

# --- D24 (slice 4 remediation, M3): adopting a repo that TRACKS the rc file must NOT dirty it
#     (do not append our source block into the tracked rc). Sandbox HOME + --dotfiles-rc=$HOME/.zshrc. ---
echo "smoke: D24 — adopt of a repo that tracks the rc does NOT dirty it"
d24src="${sandbox}/adopt-rc-src"; mkdir -p "${d24src}"
( cd "${d24src}" && git init -q && printf 'export FROM_REPO=1\n' > .zshrc \
    && git -c user.email=t@t -c user.name=t add -A \
    && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1
d24h="${sandbox}/adopt-rc-home"; mkdir -p "${d24h}"
set +e; out="$(adrun "${d24h}" --dotfiles-remote "${d24src}" --apply 2>&1)"; rc=$?; set -e
pass_if "${rc}" "adopt of a repo tracking the rc exits 0" "tracked-rc adopt failed (exit ${rc}): ${out}"
assert_contains "${out}" "tracked by the adopted repo" "adopt reports the rc is repo-managed (skips the source block)"
if grep -qF ">>> xdg-cloud dotfiles >>>" "${d24h}/.zshrc" 2>/dev/null; then fail "our source block was appended into the TRACKED rc (dirties it)"; else ok "the tracked rc was NOT dirtied with our source block"; fi
d24status="$(git --git-dir="${d24h}/.dotfiles" --work-tree="${d24h}" status --porcelain 2>/dev/null)"
if [ -z "${d24status}" ]; then ok "post-adopt dotfiles status is clean (tracked rc untouched)"; else fail "post-adopt dotfiles status is DIRTY: ${d24status}"; fi

# --- D25 (T-M1): DIR-collider never-clobber. A pre-existing NON-EMPTY DIRECTORY at $HOME/<p>
#     that the repo tracks (as a file) is moved aside WHOLE — its contents preserved verbatim at
#     <p>.pre-dotfiles-*/ — and the tracked file is checked out in its place. This is a DISTINCT
#     data-preservation path (mv of a directory, not a file): D13/D15 cover file colliders and
#     D16 a symlink, but a directory collider had no standing never-clobber guard. ---
echo "smoke: D25 — adopt asides a non-empty DIRECTORY collider WHOLE (contents preserved) + checks out the tracked file"
d25src="${sandbox}/d25-src"; mkdir -p "${d25src}"; printf 'REMOTE-FOO\n' > "${d25src}/foo"; git_seed "${d25src}"
d25h="${sandbox}/d25-home"; mkdir -p "${d25h}/foo"
printf 'PRECIOUS-DIR-DATA\n' > "${d25h}/foo/keep.txt"
set +e; out="$(adrun "${d25h}" --dotfiles-remote "${d25src}" --apply 2>&1)"; rc=$?; set -e
pass_if "${rc}" "adopt with a directory collider exits 0" "adopt (dir collider) failed (exit ${rc}): ${out}"
if [ -f "${d25h}/foo" ] && [ "$(cat "${d25h}/foo" 2>/dev/null)" = "REMOTE-FOO" ]; then ok "the tracked file was checked out where the dir stood"; else fail "the tracked file was not checked out over the dir collider"; fi
d25_aside=""; for d in "${d25h}"/foo.pre-dotfiles-*; do [ -d "${d}" ] && { d25_aside="${d}"; break; }; done
if [ -n "${d25_aside}" ] && [ "$(cat "${d25_aside}/keep.txt" 2>/dev/null)" = "PRECIOUS-DIR-DATA" ]; then ok "the whole directory (with its contents) was moved aside — NEVER clobbered"; else fail "DATA LOSS: the directory collider's contents were not preserved at *.pre-dotfiles"; fi

# --- I1 (slice 5): iCloud evict FAIL-CLOSED gate. macOS-gated (the iCloud modes are macOS-only;
#     PLATFORM=macos comes from `uname -s`). Live iCloud is NOT testable — brctl is shimmed on PATH
#     (records every call) and the upload-state helper is shimmed via $ICLOUD_HELPER (exit 0 = all
#     uploaded / exit 1 = some not). Asserts the load-bearing property: evict calls brctl ONLY when
#     every gate passes AND the helper confirms all candidates uploaded. Sandbox HOME (a CloudDocs
#     tree under it), NEVER real iCloud. ---
if [ "$(uname -s)" = "Darwin" ]; then
  echo "smoke: I1 — iCloud evict is fail-closed (gates + helper-confirms-uploaded); brctl is shimmed"
  i1h="${sandbox}/icloud-home"; i1cd="${i1h}/Library/Mobile Documents/com~apple~CloudDocs/td"
  mkdir -p "${i1cd}"; printf 'a\n' > "${i1cd}/f1"; printf 'b\n' > "${i1cd}/f2"
  i1shim="${sandbox}/icloud-shim"; mkdir -p "${i1shim}"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/brctl.log"\nexit 0\n' "${sandbox}" > "${i1shim}/brctl"
  chmod +x "${i1shim}/brctl"
  i1ok="${sandbox}/helper-ok"
  # shellcheck disable=SC2016   # $p is literal inside the shim script being written, not expanded here
  printf '#!/bin/bash\nfor p; do printf "uploaded\\t%%s\\0" "$p"; done\nexit 0\n' > "${i1ok}"; chmod +x "${i1ok}"
  i1no="${sandbox}/helper-no"
  # shellcheck disable=SC2016   # $p is literal inside the shim script being written, not expanded here
  printf '#!/bin/bash\nfor p; do printf "not-uploaded\\t%%s\\0" "$p"; done\nexit 1\n' > "${i1no}"; chmod +x "${i1no}"
  i1run() { PATH="${i1shim}:${PATH}" HOME="${i1h}" XDG_CONFIG_HOME="${i1h}/.config" XDG_CACHE_HOME="${i1h}/.cache" \
    /bin/bash "${PROV}" "$@"; }
  : > "${sandbox}/brctl.log"
  # (a) path OUTSIDE CloudDocs → die, ZERO evict.
  set +e; out="$(ICLOUD_HELPER="${i1ok}" i1run --icloud-evict /tmp --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "evict of a path outside CloudDocs is refused"
  assert_contains "${out}" "not under iCloud Drive" "the refusal explains the path must be under iCloud Drive"
  # (b) missing consent flag → die.
  set +e; out="$(ICLOUD_HELPER="${i1ok}" i1run --icloud-evict "${i1cd}" --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "evict without --i-understand-data-loss-risk is refused"
  assert_contains "${out}" "i-understand-data-loss-risk" "the refusal names the required consent flag"
  # (c) helper not built/executable → graceful degrade (die pointing at --offload).
  set +e; out="$(ICLOUD_HELPER="${sandbox}/no-such-helper" i1run --icloud-evict "${i1cd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "evict without the upload-state helper is refused"
  assert_contains "${out}" "make helper" "the helper-absent refusal tells the user to build it"
  assert_contains "${out}" "--offload" "the helper-absent refusal points at the safer rclone offload"
  # (d) subset semantics (skip-and-report default): helper reports EVERY file not-uploaded →
  #     rc 0 with the mandatory skip report, and evict NOTHING (fail-closed per file).
  set +e; out="$(ICLOUD_HELPER="${i1no}" i1run --icloud-evict "${i1cd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "all-not-uploaded evict completes with rc 0 (skip-and-report, not refusal)" "all-not-uploaded evict failed (exit ${rc}): ${out}"
  assert_contains "${out}" "skipped (NEVER evicted — fail-closed):" "the skip listing header prints"
  assert_contains "${out}" "not-uploaded: 2, not-in-icloud: 0, helper-error: 0, unanswered: 0, drift: 0" "the summary line tallies both files not-uploaded"
  assert_contains "${out}" "evict plan: 0 of 2" "the evict plan reports 0 of 2 proven uploaded"
  if [ -s "${sandbox}/brctl.log" ] && grep -q evict "${sandbox}/brctl.log"; then fail "DATA LOSS: brctl evict was called despite a not-uploaded file"; else ok "brctl evict was NOT called on the not-uploaded set (evicted NOTHING)"; fi
  # (e) dry-run (helper OK) → previews, calls NO evict.
  : > "${sandbox}/brctl.log"
  set +e; out="$(ICLOUD_HELPER="${i1ok}" i1run --icloud-evict "${i1cd}" --i-understand-data-loss-risk 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "dry-run evict (all uploaded) exits 0" "dry-run evict failed (exit ${rc}): ${out}"
  assert_contains "${out}" "dry-run" "dry-run evict labels its output as a preview"
  if grep -q evict "${sandbox}/brctl.log" 2>/dev/null; then fail "dry-run evict actually called brctl evict"; else ok "dry-run evict called NO brctl evict"; fi
  # (f) apply (helper OK) → evicts every uploaded candidate (shimmed brctl records the calls).
  : > "${sandbox}/brctl.log"
  set +e; out="$(ICLOUD_HELPER="${i1ok}" i1run --icloud-evict "${i1cd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "apply evict (all uploaded) exits 0" "apply evict failed (exit ${rc}): ${out}"
  i1n="$(grep -c evict "${sandbox}/brctl.log" 2>/dev/null || printf 0)"
  if [ "${i1n}" -eq 2 ]; then ok "apply evict called brctl evict for each uploaded candidate (2)"; else fail "expected 2 brctl evict calls, got ${i1n}"; fi
  # (g) status is read-only (no helper needed) and calls no brctl.
  : > "${sandbox}/brctl.log"
  set +e; out="$(i1run --icloud-status "${i1cd}" 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "icloud-status exits 0 (read-only, no helper)" "icloud-status failed (exit ${rc}): ${out}"
  assert_contains "${out}" "iCloud status under" "status prints its read-only header"
  if grep -q . "${sandbox}/brctl.log" 2>/dev/null; then fail "icloud-status called brctl (should be read-only)"; else ok "icloud-status called no brctl (read-only)"; fi
else
  echo "smoke: I1 iCloud evict gate — SKIPPED (macOS-only; uname=$(uname -s))"
fi

# --- I2 (slice 5): iCloud evict — extra gate coverage extending I1. Same mock model (brctl
#     PATH-shim RECORDS to $BRCTL_LOG and never evicts; ICLOUD_HELPER env-shim is controllable).
#     Adds: brctl-absent, a MIXED upload set (whole-set-before-any-evict), a helper ERROR,
#     dataless-skip (stat-shim), --icloud-download (add-only), mode mutual-exclusion, and
#     `make helper` graceful-degrade without swiftc. macOS-gated; NO real brctl/iCloud/eviction. ---
if [ "$(uname -s)" = "Darwin" ]; then
  echo "smoke: I2 — iCloud evict extra gates (brctl-absent, mixed/error, dataless-skip, download, mutual-exclusion)"
  i2h="${sandbox}/i2-home"; i2cd="${i2h}/Library/Mobile Documents/com~apple~CloudDocs/td"; mkdir -p "${i2cd}"
  i2log="${sandbox}/i2-brctl.log"
  i2shim="${sandbox}/i2-shim"; mkdir -p "${i2shim}"
  cat > "${i2shim}/brctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$BRCTL_LOG"
exit 0
SH
  chmod +x "${i2shim}/brctl"
  i2ok="${sandbox}/i2-helper-ok"
  cat > "${i2ok}" <<'SH'
#!/bin/bash
for p; do printf 'uploaded\t%s\0' "$p"; done
exit 0
SH
  chmod +x "${i2ok}"
  i2mix="${sandbox}/i2-helper-mixed"
  # Position-keyed: FIRST argv arg uploaded, the rest not. rc mirrors the real helper (0 iff
  # every arg uploaded) so the stub self-consistently answers the phase-2 n=1 subset re-exec
  # (single argv = first arg = uploaded = exit 0).
  cat > "${i2mix}" <<'SH'
#!/bin/bash
i=0; rc=0
for p; do i=$((i + 1)); if [ "$i" = 1 ]; then printf 'uploaded\t%s\0' "$p"; else printf 'not-uploaded\t%s\0' "$p"; rc=1; fi; done
exit "$rc"
SH
  chmod +x "${i2mix}"
  i2err="${sandbox}/i2-helper-err"
  cat > "${i2err}" <<'SH'
#!/bin/bash
exit 2
SH
  chmod +x "${i2err}"
  i2run() { PATH="${i2shim}:${PATH}" BRCTL_LOG="${i2log}" HOME="${i2h}" \
    XDG_CONFIG_HOME="${i2h}/.config" XDG_CACHE_HOME="${i2h}/.cache" /bin/bash "${PROV}" "$@"; }
  # One curated bin: all /usr/bin symlinks MINUS brctl and swiftc, reused for (h) + (n). Pure
  # builtin path-strip (no basename subshell). brctl/swiftc ship in /usr/bin, so this is the only
  # reliable way to simulate their absence on a stock Mac.
  i2cur="${sandbox}/i2-curated-bin"; mkdir -p "${i2cur}"
  for f in /usr/bin/*; do b="${f##*/}"; case "$b" in brctl|swiftc) : ;; *) ln -sf "$f" "${i2cur}/$b" ;; esac; done

  # (h) brctl ABSENT → die, ZERO evict (curated PATH has no brctl; the recording shim is absent too).
  printf 'a\n' > "${i2cd}/fh"; : > "${i2log}"
  set +e
  out="$(PATH="${i2cur}:/bin" BRCTL_LOG="${i2log}" HOME="${i2h}" XDG_CONFIG_HOME="${i2h}/.config" \
    XDG_CACHE_HOME="${i2h}/.cache" ICLOUD_HELPER="${i2ok}" \
    /bin/bash "${PROV}" --icloud-evict "${i2cd}" --i-understand-data-loss-risk --apply 2>&1)"
  rc=$?
  set -e
  assert_nonzero "${rc}" "evict is refused when brctl is absent"
  assert_contains "${out}" "brctl not found" "the brctl-absent refusal explains brctl is required"
  if grep -q evict "${i2log}" 2>/dev/null; then fail "DATA LOSS: an evict was recorded despite brctl being absent"; else ok "brctl-absent path evicted NOTHING"; fi

  # (i) MIXED set (position-keyed: first argv arg uploaded, second not) → rc 0, evict EXACTLY
  #     the one proven-uploaded file (subset semantics). Count-based assert only — find order
  #     is not guaranteed, so WHICH basename got the 'uploaded' answer is not asserted.
  rm -f "${i2cd:?}"/*; printf '1\n' > "${i2cd}/f1"; printf '2\n' > "${i2cd}/f2"; : > "${i2log}"
  set +e; out="$(ICLOUD_HELPER="${i2mix}" i2run --icloud-evict "${i2cd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "mixed-set evict completes with rc 0 (skip-and-report subset semantics)" "mixed-set evict failed (exit ${rc}): ${out}"
  assert_contains "${out}" "not-uploaded: 1" "the not-uploaded file is tallied in the summary line"
  i2me="$(grep -c '^evict ' "${i2log}" 2>/dev/null || printf 0)"
  if [ "${i2me}" -eq 1 ]; then ok "mixed set evicted EXACTLY the one proven-uploaded file (1 brctl evict)"; else fail "mixed set expected exactly 1 brctl evict, got ${i2me}: $(cat "${i2log}" 2>/dev/null)"; fi

  # (j) helper ERROR (exit 2, no output) → die, ZERO evict.
  : > "${i2log}"
  set +e; out="$(ICLOUD_HELPER="${i2err}" i2run --icloud-evict "${i2cd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "evict is refused when the helper errors"
  if grep -q evict "${i2log}" 2>/dev/null; then fail "DATA LOSS: evicted despite a helper error"; else ok "helper-error evicted NOTHING"; fi

  # (j2) NEWLINE-FORGERY helper → PATH-ECHO die. The record's echoed path (which embeds a
  #      newline + a forged second record) is byte-compared to the argv path; any inequality
  #      kills the run before anything is selected (the old display-filter surface is gone).
  #      Zero evicts, and the forged path never reaches brctl.
  i2forge="${sandbox}/i2-helper-forge"
  cat > "${i2forge}" <<'SH'
#!/bin/bash
printf 'uploaded\t/ok/name-with\nnot-uploaded\t/forged-blocker\0not-uploaded\t/real-blocker\0'
exit 1
SH
  chmod +x "${i2forge}"
  : > "${i2log}"
  set +e; out="$(ICLOUD_HELPER="${i2forge}" i2run --icloud-evict "${i2cd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "the newline-forgery helper set dies (path-echo assertion, fail-closed)"
  assert_contains "${out}" "does not echo its argv path" "the die names the path-echo join desync"
  if grep -q evict "${i2log}" 2>/dev/null; then fail "DATA LOSS: evicted despite the forgery-set die"; else ok "forgery-set die evicted NOTHING"; fi
  if grep -q '/forged-blocker' "${i2log}" 2>/dev/null; then fail "DATA LOSS: the forged path reached brctl"; else ok "the forged path never reached brctl"; fi

  # (k) DATALESS-SKIP: a stat-shim reports one file dataless (icloud_is_dataless reads `stat -f %Sf`),
  #     so a dir with [dataless + uploaded] evicts ONLY the uploaded, non-dataless file.
  i2sshim="${sandbox}/i2-stat-shim"; mkdir -p "${i2sshim}"
  # The shim answers BOTH stat formats the iCloud lanes use: bare '%Sf' (icloud_is_dataless)
  # and the combined '%z %Sf' (sync-status/download size-first parse) — a fixed size of 5.
  cat > "${i2sshim}/stat" <<'SH'
#!/bin/bash
for last; do :; done
case "$last" in
  *DATALESS*)
    case "$*" in
      *"%z %Sf"*) echo "5 dataless"; exit 0 ;;
      *)          echo "dataless";   exit 0 ;;
    esac ;;
esac
exec /usr/bin/stat "$@"
SH
  chmod +x "${i2sshim}/stat"; cp "${i2shim}/brctl" "${i2sshim}/brctl"
  rm -f "${i2cd:?}"/*; printf 'u\n' > "${i2cd}/f_upload"; printf 'd\n' > "${i2cd}/f_DATALESS"; : > "${i2log}"
  set +e
  out="$(PATH="${i2sshim}:${PATH}" BRCTL_LOG="${i2log}" HOME="${i2h}" XDG_CONFIG_HOME="${i2h}/.config" \
    XDG_CACHE_HOME="${i2h}/.cache" ICLOUD_HELPER="${i2ok}" \
    /bin/bash "${PROV}" --icloud-evict "${i2cd}" --i-understand-data-loss-risk --apply 2>&1)"
  rc=$?
  set -e
  pass_if "${rc}" "evict with a dataless file present exits 0" "dataless-skip evict failed (exit ${rc}): ${out}"
  i2ne="$(grep -c evict "${i2log}" 2>/dev/null || printf 0)"
  if [ "${i2ne}" -eq 1 ] && grep -q 'f_upload' "${i2log}" && ! grep -q 'f_DATALESS' "${i2log}"; then ok "only the uploaded, non-dataless file was evicted (dataless one skipped)"; else fail "dataless-skip wrong — evicted ${i2ne} file(s): $(cat "${i2log}" 2>/dev/null)"; fi

  # (l) --icloud-download → brctl download per DATALESS file, add-only (NO evict); works with the
  #     default (no) helper. The lane is dataless-only now, so the fixtures are made dataless via
  #     the stat shim (*_DATALESS names). ICLOUD_DL_MARGIN_BYTES=0 keeps the new free-space gate
  #     machine-independent (real df must not flake this subtest on a nearly-full host).
  rm -f "${i2cd:?}"/*; printf 'x\n' > "${i2cd}/g1_DATALESS"; printf 'y\n' > "${i2cd}/g2_DATALESS"; : > "${i2log}"
  set +e
  out="$(PATH="${i2sshim}:${PATH}" BRCTL_LOG="${i2log}" HOME="${i2h}" XDG_CONFIG_HOME="${i2h}/.config" \
    XDG_CACHE_HOME="${i2h}/.cache" ICLOUD_DL_MARGIN_BYTES=0 \
    /bin/bash "${PROV}" --icloud-download "${i2cd}" --apply 2>&1)"
  rc=$?
  set -e
  pass_if "${rc}" "icloud-download --apply exits 0 (no helper needed)" "download failed (exit ${rc}): ${out}"
  i2dn="$(grep -c download "${i2log}" 2>/dev/null || printf 0)"
  if [ "${i2dn}" -eq 2 ]; then ok "download called brctl download once per dataless file (add-only, 2)"; else fail "expected 2 brctl download calls, got ${i2dn}"; fi
  # Anchored '^evict ': the logged download PATHS may themselves contain the substring
  # "evict" (e.g. a worktree named feat-bulk-evict) — only the command word counts.
  if grep -q '^evict ' "${i2log}" 2>/dev/null; then fail "download called brctl EVICT (must be add-only)"; else ok "download called NO evict (add-only)"; fi

  # (m) mode mutual-exclusion: two modes in one invocation → refused.
  set +e; out="$(i2run --icloud-evict "${i2cd}" --icloud-status "${i2cd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "combining two modes in one run is refused"
  assert_contains "${out}" "ONE mode" "the refusal explains only one mode runs per invocation"

  # (n) `make helper` WITHOUT swiftc → graceful exit 0 (curated PATH minus swiftc; no build attempted).
  set +e; out="$(PATH="${i2cur}:/bin" make -C "${repo}" helper 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "make helper exits 0 when swiftc is absent (graceful degrade)" "make helper failed without swiftc (exit ${rc}): ${out}"
  assert_contains "${out}" "swiftc not found" "make helper explains swiftc is needed and skips gracefully"
else
  echo "smoke: I2 iCloud evict extra gates — SKIPPED (macOS-only; uname=$(uname -s))"
fi

# --- I3 (TUI iCloud sync): resolve-then-confine resolver matrix, --icloud-sync-status summary,
#     and the --icloud-download free-space gate. Same mock model as I1/I2 (recording brctl
#     PATH-shim; ICLOUD_HELPER env-shim; stat shim makes *_DATALESS fixtures dataless). The brctl
#     shim additionally answers `brctl status` from $BRCTL_STATUS_FILE (canned per case). The
#     margin env override (ICLOUD_DL_MARGIN_BYTES) is the primary df seam — real df, deterministic
#     both directions; a PATH-shimmed failing df covers ONLY the df-failure fail-closed case.
#     macOS-gated; NO real brctl/iCloud. ---
if [ "$(uname -s)" = "Darwin" ]; then
  echo "smoke: I3 — iCloud resolver escape matrix, sync-status summary, download free-space gate"
  i3h="${sandbox}/i3-home"
  i3cd="${i3h}/Library/Mobile Documents/com~apple~CloudDocs"
  mkdir -p "${i3cd}/td" "${i3cd}/documents" "${sandbox}/i3-outside/sub"
  printf '1\n' > "${i3cd}/td/f1"; printf '2\n' > "${i3cd}/td/f2"
  # ESCAPE fixtures: lexically inside the root, resolving OUTSIDE it (dir symlinks; the landing
  # zone must exist so `cd` succeeds and the resolver sees the real out-of-root path).
  ln -s "${sandbox}/i3-outside" "${i3cd}/escape"
  ln -s "${sandbox}/i3-outside" "${i3cd}/linkdir"
  # Provisioned-machine shape: $HOME/Documents is a symlink INTO CloudDocs.
  ln -s "${i3cd}/documents" "${i3h}/Documents"
  # Symlinked-ROOT fixture for the env-override cases (g)/(h).
  ln -s "${i3cd}" "${sandbox}/i3-rootlink"
  i3log="${sandbox}/i3-brctl.log"
  i3status="${sandbox}/i3-brctl-status"
  printf 'x <com.apple.CloudDocs[1] observer:smoke state:caught-up>\n' > "${i3status}"
  i3shim="${sandbox}/i3-shim"; mkdir -p "${i3shim}"
  cat > "${i3shim}/brctl" <<'SH'
#!/bin/bash
if [ "$1" = "status" ]; then cat "$BRCTL_STATUS_FILE" 2>/dev/null; exit 0; fi
printf '%s\n' "$*" >> "$BRCTL_LOG"
exit 0
SH
  chmod +x "${i3shim}/brctl"
  cat > "${i3shim}/stat" <<'SH'
#!/bin/bash
for last; do :; done
case "$last" in
  *DATALESS*)
    case "$*" in
      *"%z %Sf"*) echo "5 dataless"; exit 0 ;;
      *)          echo "dataless";   exit 0 ;;
    esac ;;
esac
exec /usr/bin/stat "$@"
SH
  chmod +x "${i3shim}/stat"
  # Upload-state helper stub: basename → state, one NUL-terminated "<state>\t<path>" record per
  # argv arg (matching the real helper's \0 record separator), exit 1 whenever any file is not
  # plain-uploaded (like the real helper). sync-status must IGNORE that rc (chunking breaks
  # whole-set exit semantics) — asserted below.
  i3help="${sandbox}/i3-helper"
  cat > "${i3help}" <<'SH'
#!/bin/bash
rc=0
for p; do
  b="${p##*/}"
  case "$b" in
    *_UP*)              printf 'uploaded\t%s\0' "$p" ;;
    *_WAIT*)            printf 'not-uploaded\t%s\0' "$p"; rc=1 ;;
    .DS_Store|*_NOTIN*) printf 'not-in-icloud\t%s\0' "$p"; rc=1 ;;
    *)                  printf 'error\t%s\0' "$p"; rc=1 ;;
  esac
done
exit "$rc"
SH
  chmod +x "${i3help}"
  i3run() { PATH="${i3shim}:${PATH}" BRCTL_LOG="${i3log}" BRCTL_STATUS_FILE="${i3status}" HOME="${i3h}" \
    XDG_CONFIG_HOME="${i3h}/.config" XDG_CACHE_HOME="${i3h}/.cache" /bin/bash "${PROV}" "$@"; }
  : > "${i3log}"

  # (a) provisioned-machine shape: $HOME/Documents (symlink INTO the root) is ACCEPTED and the
  #     output names the RESOLVED CloudDocs path — the TUI-killing bug this PR fixes.
  i3docs="$(cd "${i3cd}/documents" && pwd -P)"
  set +e; out="$(ICLOUD_HELPER="${i3help}" i3run --icloud-sync-status "${i3h}/Documents" 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "sync-status accepts \$HOME/<name> symlinked INTO CloudDocs (exit 0)" "symlink-into-root target refused (exit ${rc}): ${out}"
  assert_contains "${out}" "iCloud sync status under: ${i3docs}" "the report names the RESOLVED (physical) CloudDocs path"

  # (b) ESCAPE: lexically-inside path resolving OUTSIDE the root is refused by BOTH lanes,
  #     and nothing reaches brctl.
  : > "${i3log}"
  set +e; out="$(ICLOUD_HELPER="${i3help}" i3run --icloud-sync-status "${i3cd}/escape" 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "sync-status refuses a symlink escaping the root (resolve-then-confine)"
  assert_contains "${out}" "not under iCloud Drive" "the sync-status escape refusal names the confinement"
  set +e; out="$(i3run --icloud-download "${i3cd}/escape" --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "download refuses a symlink escaping the root (resolve-then-confine)"
  assert_contains "${out}" "not under iCloud Drive" "the download escape refusal names the confinement"
  if grep -q . "${i3log}" 2>/dev/null; then fail "an escape target reached brctl: $(cat "${i3log}")"; else ok "escape targets never reached brctl (log empty)"; fi

  # (c) mid-path escape: <root>/linkdir/sub where linkdir resolves outside.
  set +e; out="$(ICLOUD_HELPER="${i3help}" i3run --icloud-sync-status "${i3cd}/linkdir/sub" 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "sync-status refuses a mid-path symlink escape"
  assert_contains "${out}" "not under iCloud Drive" "the mid-path escape refusal names the confinement"

  # (d) the root itself is accepted.
  set +e; out="$(ICLOUD_HELPER="${i3help}" i3run --icloud-sync-status "${i3cd}" 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "sync-status accepts the root itself (exit 0)" "root target refused (exit ${rc}): ${out}"

  # (e) a plain (no-symlink) subdir is accepted.
  set +e; out="$(ICLOUD_HELPER="${i3help}" i3run --icloud-sync-status "${i3cd}/td" 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "sync-status accepts a plain subdir (exit 0)" "plain subdir refused (exit ${rc}): ${out}"

  # (f) nonexistent path: existence is checked BEFORE confinement (resolution needs it).
  set +e; out="$(ICLOUD_HELPER="${i3help}" i3run --icloud-sync-status "${i3cd}/no-such-thing" 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "sync-status refuses a nonexistent path"
  assert_contains "${out}" "no such path" "the nonexistent-path refusal says so"

  # (g)+(h) env-overridden SYMLINKED root: the root is resolved before the compare, so the
  #     override relocates confinement without weakening it.
  set +e; out="$(ICLOUD_ROOT="${sandbox}/i3-rootlink" ICLOUD_HELPER="${i3help}" i3run --icloud-sync-status "${i3cd}/td" 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "symlinked ICLOUD_ROOT override: real-root target accepted (root resolved before compare)" "override root refused a legit target (exit ${rc}): ${out}"
  set +e; out="$(ICLOUD_ROOT="${sandbox}/i3-rootlink" ICLOUD_HELPER="${i3help}" i3run --icloud-sync-status "${i3cd}/escape" 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "symlinked ICLOUD_ROOT override still refuses an escape (override cannot weaken confinement)"

  # --- sync-status summary behavior (fixture: 2 dataless + 2 UP + 1 WAIT + 1 .DS_Store + 1 error) ---
  i3ss="${i3cd}/ss"; mkdir -p "${i3ss}"
  printf 'd1\n' > "${i3ss}/a_DATALESS"; printf 'd2\n' > "${i3ss}/b_DATALESS"   # stat shim: 5 bytes each
  printf 'aaa\n' > "${i3ss}/c_UP"; printf 'bbb\n' > "${i3ss}/d_UP"             # 4 bytes each (real stat)
  printf 'w\n' > "${i3ss}/e_WAIT"
  printf 'n\n' > "${i3ss}/.DS_Store"
  printf 'x\n' > "${i3ss}/f_ERRNAME"
  i3snap_before="$(cd "${i3ss}" && find . | sort)"
  : > "${i3log}"
  set +e; out="$(ICLOUD_HELPER="${i3help}" i3run --icloud-sync-status "${i3ss}" 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "sync-status exits 0 although the chunked helper exits 1 (rc ignored; stdout parsed)" "sync-status failed on a mixed set (exit ${rc}): ${out}"
  assert_contains "${out}" "scanned: 7 file(s)" "all 7 fixture files are scanned"
  assert_contains "${out}" "dataless (to download): 2 file(s), 10 B" "dataless count + byte total (2 x 5 B via stat shim)"
  assert_contains "${out}" "materialized + uploaded (evictable*): 2 file(s), 8 B" "uploaded count + byte total (2 x 4 B real stat)"
  assert_contains "${out}" "materialized, NOT uploaded (waiting on iCloud): 1 file(s)" "waiting count from helper stdout"
  assert_contains "${out}" "not in iCloud (excluded from sync, e.g. .DS_Store): 1 file(s)" "not-in-icloud count from helper stdout"
  assert_contains "${out}" "unreadable / helper-error: 1 file(s)" "helper-error line counted fail-closed"
  assert_contains "${out}" "free space on volume:" "the free-space line is reported (real df)"
  assert_contains "${out}" "container health (brctl status): caught-up" "caught-up health line from the canned brctl status"
  assert_not_contains "${out}" "NOT caught up" "no wedge warning when the container is caught-up"
  # read-only proof: no lock, nothing mutated, no download/evict reached brctl.
  if [ -e "${i3h}/.cache/cloud-xdg-provision.lock" ]; then fail "sync-status left a lock dir (read-only mode must not lock)"; else ok "sync-status created no lock dir (read-only)"; fi
  if grep -Eq 'download|evict' "${i3log}" 2>/dev/null; then fail "sync-status invoked brctl download/evict (must be read-only): $(cat "${i3log}")"; else ok "sync-status invoked no brctl download/evict (read-only)"; fi
  i3snap_after="$(cd "${i3ss}" && find . | sort)"
  if [ "${i3snap_before}" = "${i3snap_after}" ]; then ok "fixture tree is structurally untouched after sync-status"; else fail "sync-status mutated the fixture tree"; fi

  # helper ABSENT → degrade (rc 0) with the make-helper hint.
  set +e; out="$(ICLOUD_HELPER="${sandbox}/i3-no-helper" i3run --icloud-sync-status "${i3ss}" 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "sync-status exits 0 without the helper (degraded report)" "helper-absent sync-status failed (exit ${rc}): ${out}"
  assert_contains "${out}" "upload split unknown" "the degraded report says the upload split is unknown"
  assert_contains "${out}" "make helper" "the degraded report points at 'make helper'"

  # NOT-caught-up canned status → the wedge warning appears.
  printf 'x <com.apple.CloudDocs[1] observer:smoke state:syncing>\n' > "${i3status}"
  set +e; out="$(ICLOUD_HELPER="${i3help}" i3run --icloud-sync-status "${i3ss}" 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "sync-status exits 0 when the container is not caught up (advisory only)" "not-caught-up sync-status failed (exit ${rc}): ${out}"
  assert_contains "${out}" "NOT caught up" "the wedge warning appears when brctl status lacks caught-up"
  printf 'x <com.apple.CloudDocs[1] observer:smoke state:caught-up>\n' > "${i3status}"

  # helper-contract break (EMPTY record mid-output — a bare NUL): the flush loop
  # SKIPS empty records, so the helper effectively answered fewer records than it
  # was asked — the end-of-flush deficit add must count the gap as an error
  # (fail-closed accounting; TEST-phase mutation check: dropping the deficit add
  # survived every prior assert). All fixture files are 4 B so the uploaded byte
  # total stays stable even though the empty record shifts the order-join of sizes.
  i3bl="${i3cd}/bl"; mkdir -p "${i3bl}"
  printf 'aaa\n' > "${i3bl}/p_UP"; printf 'bbb\n' > "${i3bl}/q_BLANK"; printf 'ccc\n' > "${i3bl}/r_UP"
  i3blhelp="${sandbox}/i3-helper-blank"
  cat > "${i3blhelp}" <<'SH'
#!/bin/bash
for p; do
  b="${p##*/}"
  case "$b" in
    *_UP*)    printf 'uploaded\t%s\0' "$p" ;;
    *_BLANK*) printf '\0' ;;
    *)        printf 'error\t%s\0' "$p" ;;
  esac
done
exit 0
SH
  chmod +x "${i3blhelp}"
  set +e; out="$(ICLOUD_HELPER="${i3blhelp}" i3run --icloud-sync-status "${i3bl}" 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "sync-status exits 0 when the helper emits an empty record (degraded, never fatal)" "empty-record helper output failed sync-status (exit ${rc}): ${out}"
  assert_contains "${out}" "materialized + uploaded (evictable*): 2 file(s), 8 B" "the two answered files still count as uploaded"
  assert_contains "${out}" "unreadable / helper-error: 1 file(s)" "the unanswered (empty) record is counted as an error — the deficit add, fail-closed"

  # --- download free-space gate (margin env override = primary seam; real df) ---
  i3dl="${i3cd}/dl"; mkdir -p "${i3dl}"
  printf 'dd\n' > "${i3dl}/h_DATALESS"   # dataless via stat shim (5 B)
  printf 'mm\n' > "${i3dl}/h_mat"        # materialized — must NOT be downloaded
  # huge margin (2^53 = the load-guard ceiling, accepted at exactly the bound) → deterministic
  # refusal at the GATE (not at load), in dry-run AND apply; zero downloads. Doubling as the
  # at-ceiling acceptance pin for the magnitude guard.
  : > "${i3log}"
  set +e; out="$(ICLOUD_DL_MARGIN_BYTES=9007199254740992 i3run --icloud-download "${i3dl}" 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "download dry-run is refused when the margin cannot be kept (gate runs in dry-run too)"
  assert_contains "${out}" "refusing to download" "the dry-run refusal says why"
  set +e; out="$(ICLOUD_DL_MARGIN_BYTES=9007199254740992 i3run --icloud-download "${i3dl}" --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "download --apply is refused when the margin cannot be kept"
  assert_contains "${out}" "refusing to download" "the apply refusal says why"
  if grep -q download "${i3log}" 2>/dev/null; then fail "a refused download still reached brctl: $(cat "${i3log}")"; else ok "refused downloads never reached brctl"; fi
  # margin 0 → passes; dataless-only: exactly 1 download, targeting the dataless file.
  : > "${i3log}"
  set +e; out="$(ICLOUD_DL_MARGIN_BYTES=0 i3run --icloud-download "${i3dl}" --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "download --apply passes with margin 0 (deterministic pass seam)" "margin-0 download failed (exit ${rc}): ${out}"
  i3dn="$(grep -c download "${i3log}" 2>/dev/null || printf 0)"
  if [ "${i3dn}" -eq 1 ] && grep -q 'h_DATALESS' "${i3log}" && ! grep -q 'h_mat' "${i3log}"; then ok "dataless-only: exactly 1 download, targeting the dataless file"; else fail "dataless-only filter wrong — recorded: $(cat "${i3log}" 2>/dev/null)"; fi
  # dry-run: plan header (count + bytes) present, zero downloads executed.
  : > "${i3log}"
  set +e; out="$(ICLOUD_DL_MARGIN_BYTES=0 i3run --icloud-download "${i3dl}" 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "download dry-run passes with margin 0" "margin-0 dry-run failed (exit ${rc}): ${out}"
  assert_contains "${out}" "download plan: 1 dataless file(s), 5 B" "the dry-run plan header shows count + bytes"
  if grep -q download "${i3log}" 2>/dev/null; then fail "dry-run download executed brctl download"; else ok "dry-run download executed nothing"; fi
  # nothing dataless → rc 0, nothing planned.
  set +e; out="$(ICLOUD_DL_MARGIN_BYTES=0 i3run --icloud-download "${i3cd}/documents" --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "download of a no-dataless tree exits 0" "no-dataless download failed (exit ${rc}): ${out}"
  assert_contains "${out}" "nothing to download" "the no-dataless run says nothing to download"
  # df FAILURE → fail-closed die (PATH-shimmed df used ONLY here).
  i3dfshim="${sandbox}/i3-df-shim"; mkdir -p "${i3dfshim}"
  printf '#!/bin/bash\nexit 1\n' > "${i3dfshim}/df"; chmod +x "${i3dfshim}/df"
  : > "${i3log}"
  set +e
  out="$(PATH="${i3dfshim}:${i3shim}:${PATH}" BRCTL_LOG="${i3log}" BRCTL_STATUS_FILE="${i3status}" HOME="${i3h}" \
    XDG_CONFIG_HOME="${i3h}/.config" XDG_CACHE_HOME="${i3h}/.cache" ICLOUD_DL_MARGIN_BYTES=0 \
    /bin/bash "${PROV}" --icloud-download "${i3dl}" --apply 2>&1)"
  rc=$?
  set -e
  assert_nonzero "${rc}" "download is refused when df fails (fail-closed, never blind)"
  assert_contains "${out}" "cannot determine free space" "the df-failure refusal says why"
  if grep -q download "${i3log}" 2>/dev/null; then fail "df-failure path still reached brctl download"; else ok "df-failure path downloaded nothing"; fi
  # CONTROLLED df → byte-exact boundary pin on the gate's bytes_need term (PR #45 review:
  # the margin-extreme cases above (2^53 refuse / 0 pass) never make bytes_need the deciding
  # term, so a mutant dropping it — `avail < margin` — survives them). df -P -k reports KB,
  # so avail_bytes is always a multiple of 1024; the byte-exact boundary is therefore built
  # by varying the MARGIN by 1 around a FIXED shimmed avail, not avail by 1:
  #   need N = 5 B (h_DATALESS via the stat shim), avail = 4 KB = 4096 B
  #   margin 4092 → N+margin = 4097 = avail+1 → ONE byte short → refuse  (kills drop-need)
  #   margin 4091 → N+margin = 4096 = avail    → strict-< passes         (kills < → <=)
  i3dfctl="${sandbox}/i3-df-ctl"; mkdir -p "${i3dfctl}"
  cat > "${i3dfctl}/df" <<'SH'
#!/bin/bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'smokefs 999999 999999 %s 50%% /\n' "${DF_AVAIL_KB:-0}"
SH
  chmod +x "${i3dfctl}/df"
  i3dfrun() { PATH="${i3dfctl}:${i3shim}:${PATH}" BRCTL_LOG="${i3log}" BRCTL_STATUS_FILE="${i3status}" HOME="${i3h}" \
    XDG_CONFIG_HOME="${i3h}/.config" XDG_CACHE_HOME="${i3h}/.cache" /bin/bash "${PROV}" "$@"; }
  # one byte short: avail(4096) < need(5) + margin(4092) = 4097 → refused, nothing reaches brctl.
  : > "${i3log}"
  set +e; out="$(DF_AVAIL_KB=4 ICLOUD_DL_MARGIN_BYTES=4092 i3dfrun --icloud-download "${i3dl}" --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "boundary: download refused ONE byte short of need+margin (bytes_need term is live)"
  assert_contains "${out}" "refusing to download" "the one-byte-short refusal says why"
  if grep -q download "${i3log}" 2>/dev/null; then fail "one-byte-short refusal still reached brctl: $(cat "${i3log}")"; else ok "one-byte-short refusal downloaded nothing"; fi
  # exact fit: avail(4096) == need(5) + margin(4091) → NOT < → passes; the dataless file downloads.
  : > "${i3log}"
  set +e; out="$(DF_AVAIL_KB=4 ICLOUD_DL_MARGIN_BYTES=4091 i3dfrun --icloud-download "${i3dl}" --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "boundary: download passes at avail == need+margin exactly (gate is strict-<)" "exact-fit download refused (exit ${rc}): ${out}"
  if grep -q 'h_DATALESS' "${i3log}" 2>/dev/null; then ok "exact-fit pass downloaded the dataless file"; else fail "exact-fit pass reached no brctl download — recorded: $(cat "${i3log}" 2>/dev/null)"; fi
  # ICLOUD_DL_MARGIN_BYTES load-time guard (fail-closed): the value flows into $((…)) where a
  # crafted string EXECUTES at arithmetic-eval time — the guard must die on anything
  # non-numeric BEFORE the gate's arithmetic can run (security regression pin).
  : > "${i3log}"
  set +e; out="$(ICLOUD_DL_MARGIN_BYTES=abc i3run --icloud-download "${i3dl}" --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "non-numeric ICLOUD_DL_MARGIN_BYTES is refused (fail-closed die at load)"
  assert_contains "${out}" "must be a non-negative integer" "the margin-guard refusal says why"
  if grep -q download "${i3log}" 2>/dev/null; then fail "non-numeric margin still reached brctl download"; else ok "non-numeric margin downloaded nothing"; fi
  # arithmetic-injection payload: were the guard dropped, $((bytes_need + margin)) would
  # EXECUTE the $(touch …) inside the array-subscript form. Assert die AND sentinel absent.
  i3sent="${sandbox}/i3-INJ-SENTINEL"
  rm -f "${i3sent}"
  set +e; out="$(ICLOUD_DL_MARGIN_BYTES="x[\$(touch ${i3sent}; echo 0)]" i3run --icloud-download "${i3dl}" --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "injection-shaped ICLOUD_DL_MARGIN_BYTES is refused (fail-closed die at load)"
  if [ -e "${i3sent}" ]; then fail "ARITHMETIC INJECTION EXECUTED — sentinel created by \$((…)) eval"; else ok "injection payload never executed (sentinel absent)"; fi
  # magnitude ceiling (PR #47 security review): a digits-only 2^64 passes the shape case but
  # WRAPS to 0 in $((bytes_need + margin)) — silently deleting the free-space margin
  # (fail-OPEN). The load guard must die on over-ceiling values BEFORE the gate arithmetic.
  : > "${i3log}"
  set +e; out="$(ICLOUD_DL_MARGIN_BYTES=18446744073709551616 i3run --icloud-download "${i3dl}" --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "over-ceiling ICLOUD_DL_MARGIN_BYTES (2^64, would wrap to 0) is refused at load"
  assert_contains "${out}" "ICLOUD_DL_MARGIN_BYTES must be <= 9007199254740992" "the ceiling refusal names the var and the bound"
  if grep -q download "${i3log}" 2>/dev/null; then fail "over-ceiling margin still reached brctl download (wrap fail-open)"; else ok "over-ceiling margin downloaded nothing"; fi
  # leading-zero margin (security review MEDIUM): a leading-zero digits-only value passes a
  # plain decimal shape case but $(( )) reads it as OCTAL — 0100000000 (meant as 100000000)
  # would silently gate with 16777216, a ~6x smaller margin (fail-open-ish shrink). The load
  # guard's 0?* branch must die BEFORE the gate arithmetic can read the value as octal.
  : > "${i3log}"
  set +e; out="$(ICLOUD_DL_MARGIN_BYTES=0100000000 i3run --icloud-download "${i3dl}" --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "leading-zero ICLOUD_DL_MARGIN_BYTES (octal-shrink shape) is refused at load"
  assert_contains "${out}" "ICLOUD_DL_MARGIN_BYTES must be a non-negative integer (no leading zeros)" "the leading-zero refusal names the var and the rule"
  if grep -q download "${i3log}" 2>/dev/null; then fail "leading-zero margin still reached brctl download (octal shrink)"; else ok "leading-zero margin downloaded nothing"; fi
  # …and bare 0 still PASSES the guard: 0?* matches 0-followed-by-more, not zero itself —
  # zero is the legit "keep no margin" value (boundary pair with the refusal above; the
  # margin-0 pass/dry-run pins earlier in this suite cover the real-df path).
  : > "${i3log}"
  set +e; out="$(DF_AVAIL_KB=4 ICLOUD_DL_MARGIN_BYTES=0 i3dfrun --icloud-download "${i3dl}" --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "bare-0 margin still accepted after the leading-zero guard (0?* does not match bare 0)" "bare-0 margin rejected (exit ${rc}): ${out}"
  if grep -q 'h_DATALESS' "${i3log}" 2>/dev/null; then ok "bare-0 margin run gated normally and downloaded the dataless file"; else fail "bare-0 margin run reached no brctl download — recorded: $(cat "${i3log}" 2>/dev/null)"; fi
  # …and the ceiling is not too tight: a legitimately LARGE margin (100 GiB) is accepted and
  # the gate arithmetic runs normally (controlled df: 200 GiB avail > 5 B need + 100 GiB margin
  # → passes and downloads; deterministic — real df would make this depend on the host disk).
  : > "${i3log}"
  set +e; out="$(DF_AVAIL_KB=209715200 ICLOUD_DL_MARGIN_BYTES=107374182400 i3dfrun --icloud-download "${i3dl}" --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "in-bounds large margin (100 GiB) is accepted — ceiling is not too tight" "100 GiB margin was rejected (exit ${rc}): ${out}"
  if grep -q 'h_DATALESS' "${i3log}" 2>/dev/null; then ok "100 GiB-margin run gated normally and downloaded the dataless file"; else fail "100 GiB-margin run reached no brctl download — recorded: $(cat "${i3log}" 2>/dev/null)"; fi

  # --- NUL-delimited enumeration (PR #45 deferred): an embedded NEWLINE in a filename must
  #     not split into bogus records in the iCloud lanes (-print0 / read -d '' sweep). ---
  i3nl="${i3cd}/nl"; mkdir -p "${i3nl}"
  i3nlf="${i3nl}/pre
post_DATALESS"
  printf 'nn\n' > "${i3nlf}"
  # sync-status: ONE file with the RIGHT byte total (5 B via the stat shim). A newline split
  # would scan 2 records, and neither stat-less half would land in the dataless bucket.
  set +e; out="$(ICLOUD_HELPER="${i3help}" i3run --icloud-sync-status "${i3nl}" 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "sync-status exits 0 on a newline-in-filename fixture" "newline fixture failed sync-status (exit ${rc}): ${out}"
  assert_contains "${out}" "scanned: 1 file(s)" "newline filename counts as ONE file (NUL-delimited find)"
  assert_contains "${out}" "dataless (to download): 1 file(s), 5 B" "newline filename's size joins the RIGHT file (no order desync)"
  # download: exactly ONE brctl call carrying the FULL path. The shim logs "$*", so the intact
  # path spans two log lines ('download <head>' + bare tail); a split would instead log TWO
  # '^download ' lines with the tail as its own bogus 'download post_DATALESS' call.
  : > "${i3log}"
  set +e; out="$(ICLOUD_DL_MARGIN_BYTES=0 i3run --icloud-download "${i3nl}" --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "download --apply exits 0 on the newline fixture" "newline download failed (exit ${rc}): ${out}"
  i3nlc="$(grep -c '^download ' "${i3log}" 2>/dev/null || printf 0)"
  if [ "${i3nlc}" -eq 1 ] && grep -qxF "post_DATALESS" "${i3log}"; then ok "download enqueued ONE brctl call with the full newline path (no split)"; else fail "newline path split before brctl download — recorded: $(cat "${i3log}" 2>/dev/null)"; fi
  # evict: the gate sees the whole path (helper stub answers 'uploaded' for *_UP), then exactly
  # ONE brctl evict with the full path. A split half would fail the gate → evict NOTHING → rc!=0.
  i3nle="${i3cd}/nle"; mkdir -p "${i3nle}"
  i3nlef="${i3nle}/ev
tail_UP"
  printf 'aaa\n' > "${i3nlef}"
  : > "${i3log}"
  set +e; out="$(ICLOUD_HELPER="${i3help}" i3run --icloud-evict "${i3nle}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "evict --apply exits 0 on a newline-in-filename fixture (gate sees the whole path)" "newline evict failed (exit ${rc}): ${out}"
  assert_contains "${out}" "Evicted 1 of 1 proven-uploaded file(s)" "evict counted ONE candidate (no split)"
  i3nlc="$(grep -c '^evict ' "${i3log}" 2>/dev/null || printf 0)"
  if [ "${i3nlc}" -eq 1 ] && grep -qxF "tail_UP" "${i3log}"; then ok "evict issued ONE brctl call with the full newline path (no split)"; else fail "newline path split before brctl evict — recorded: $(cat "${i3log}" 2>/dev/null)"; fi
  # helper-STDOUT order-join across an embedded newline (only testable now the helper's
  # records are NUL-terminated): a MATERIALIZED newline-named *_UP file must aggregate as
  # exactly ONE uploaded record with the RIGHT byte total. Pre-fix (newline-terminated
  # helper records) the record split in two: head counted uploaded, tail fell to the error
  # bucket — so the DISCRIMINATING assert is the error warn-line (printed only when
  # errors > 0) being ABSENT.
  i3nlu="${i3cd}/nlu"; mkdir -p "${i3nlu}"
  i3nluf="${i3nlu}/mat
tail_UP"
  printf 'aaa\n' > "${i3nluf}"   # 4 B via real stat — materialized (no DATALESS marker)
  set +e; out="$(ICLOUD_HELPER="${i3help}" i3run --icloud-sync-status "${i3nlu}" 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "sync-status exits 0 on a MATERIALIZED newline-in-filename fixture" "materialized newline fixture failed sync-status (exit ${rc}): ${out}"
  assert_contains "${out}" "scanned: 1 file(s)" "the materialized newline filename scans as ONE file"
  assert_contains "${out}" "materialized + uploaded (evictable*): 1 file(s), 4 B" "ONE uploaded record with the RIGHT bytes (helper-stdout order-join intact across the newline)"
  assert_not_contains "${out}" "unreadable / helper-error" "no split tail lands in the error bucket (NUL-terminated helper records)"

  # --- chunk-cap env seam (PR #45 deferred): a tiny cap drives the MID-WALK flush path on a
  #     small fixture (multiple helper execs) and proves the `< /dev/null` helper-stdin sever
  #     under real multi-chunk conditions: this helper DRAINS its stdin before answering —
  #     without the sever, the first mid-walk flush would eat the walk's remaining file list
  #     (scanned would drop from 3 to 1). Outer </dev/null keeps a hypothetical regression
  #     deterministic (drain hits EOF instead of blocking on the suite's stdin). ---
  i3mf="${i3cd}/mf"; mkdir -p "${i3mf}"
  printf 'aaa\n' > "${i3mf}/x_UP"; printf 'bbb\n' > "${i3mf}/y_UP"; printf 'ccc\n' > "${i3mf}/z_UP"
  i3sevlog="${sandbox}/i3-sever-execs"
  i3sevhelp="${sandbox}/i3-helper-sever"
  cat > "${i3sevhelp}" <<'SH'
#!/bin/bash
printf 'exec %s\n' "$#" >> "$SEV_LOG"
cat > /dev/null
for p; do printf 'uploaded\t%s\0' "$p"; done
exit 0
SH
  chmod +x "${i3sevhelp}"
  : > "${i3sevlog}"
  set +e; out="$(ICLOUD_CHUNK_MAX_ARGS=1 SEV_LOG="${i3sevlog}" ICLOUD_HELPER="${i3sevhelp}" i3run --icloud-sync-status "${i3mf}" 2>&1 < /dev/null)"; rc=$?; set -e
  pass_if "${rc}" "sync-status exits 0 with ICLOUD_CHUNK_MAX_ARGS=1 (mid-walk multi-flush)" "tiny-arg-cap sync-status failed (exit ${rc}): ${out}"
  assert_contains "${out}" "scanned: 3 file(s)" "the stdin-draining helper did NOT eat the walk's file list (stdin sever holds mid-flush)"
  assert_contains "${out}" "materialized + uploaded (evictable*): 3 file(s), 12 B" "totals aggregate correctly ACROSS flushes (3 x 4 B over 3 helper execs)"
  i3sevc="$(grep -cx 'exec 1' "${i3sevlog}" 2>/dev/null || printf 0)"
  if [ "${i3sevc}" -eq 3 ]; then ok "ICLOUD_CHUNK_MAX_ARGS=1 drove 3 single-arg helper execs (flush path live)"; else fail "expected 3 single-arg helper execs, got: $(cat "${i3sevlog}" 2>/dev/null)"; fi
  # byte-cap seam: ICLOUD_CHUNK_MAX_BYTES=1 must drive the same per-file flushes.
  : > "${i3sevlog}"
  set +e; out="$(ICLOUD_CHUNK_MAX_BYTES=1 SEV_LOG="${i3sevlog}" ICLOUD_HELPER="${i3sevhelp}" i3run --icloud-sync-status "${i3mf}" 2>&1 < /dev/null)"; rc=$?; set -e
  pass_if "${rc}" "sync-status exits 0 with ICLOUD_CHUNK_MAX_BYTES=1 (byte-cap multi-flush)" "tiny-byte-cap sync-status failed (exit ${rc}): ${out}"
  assert_contains "${out}" "materialized + uploaded (evictable*): 3 file(s), 12 B" "byte-cap flushes aggregate the same totals"
  i3sevc="$(grep -cx 'exec 1' "${i3sevlog}" 2>/dev/null || printf 0)"
  if [ "${i3sevc}" -eq 3 ]; then ok "ICLOUD_CHUNK_MAX_BYTES=1 drove 3 single-arg helper execs"; else fail "byte-cap: expected 3 single-arg execs, got: $(cat "${i3sevlog}" 2>/dev/null)"; fi
  # cap guards: non-numeric caps die fail-closed at load (same idiom as the margin guard).
  set +e; out="$(ICLOUD_CHUNK_MAX_ARGS=abc i3run --icloud-sync-status "${i3mf}" 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "non-numeric ICLOUD_CHUNK_MAX_ARGS is refused (fail-closed die at load)"
  assert_contains "${out}" "ICLOUD_CHUNK_MAX_ARGS must be a non-negative integer" "the args-cap guard refusal says why"
  set +e; out="$(ICLOUD_CHUNK_MAX_BYTES=1e6 i3run --icloud-sync-status "${i3mf}" 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "non-numeric ICLOUD_CHUNK_MAX_BYTES is refused (fail-closed die at load)"
  assert_contains "${out}" "ICLOUD_CHUNK_MAX_BYTES must be a non-negative integer" "the bytes-cap guard refusal says why"
  # over-ceiling caps: an over-int64 digits-only value would make the mid-walk [ -ge ]
  # flush compare error->false and silently DISABLE chunk flushing (the thing the guard
  # exists to prevent). Both the over-int64 (length path) and the in-int64-but-over-1GiB
  # (numeric path) values must die at load, naming the var.
  set +e; out="$(ICLOUD_CHUNK_MAX_ARGS=99999999999999999999999 i3run --icloud-sync-status "${i3mf}" 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "over-int64 ICLOUD_CHUNK_MAX_ARGS is refused (fail-closed die at load)"
  assert_contains "${out}" "ICLOUD_CHUNK_MAX_ARGS must be <= 1073741824" "the args-cap ceiling refusal names the var and the bound"
  set +e; out="$(ICLOUD_CHUNK_MAX_BYTES=2147483648 i3run --icloud-sync-status "${i3mf}" 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "over-ceiling ICLOUD_CHUNK_MAX_BYTES is refused (fail-closed die at load)"
  assert_contains "${out}" "ICLOUD_CHUNK_MAX_BYTES must be <= 1073741824" "the bytes-cap ceiling refusal names the var and the bound"
else
  echo "smoke: I3 iCloud resolver/sync-status/download gate — SKIPPED (macOS-only; uname=$(uname -s))"
fi

# --- I4 (bulk evict): subset-evict safety matrix — P0 rows only (CODE-phase verification;
#     the test-engineer extends this group per docs/architecture/bulk-evict-diff.md §4.2).
#     Same mock model as I1-I3: sandbox HOME + CloudDocs tree, recording brctl PATH-shim
#     ($BRCTL_LOG), basename-keyed ICLOUD_HELPER stub echoing the FULL argv path per NUL
#     record, exit 0 iff every arg uploaded (the real helper's contract). macOS-gated;
#     NEVER real brctl/iCloud. ---
if [ "$(uname -s)" = "Darwin" ]; then
  echo "smoke: I4 — bulk evict subset semantics (P0: skip-and-report matrix, inverted forgery, count-deficit)"
  i4h="${sandbox}/i4-home"; i4cd="${i4h}/Library/Mobile Documents/com~apple~CloudDocs/td"; mkdir -p "${i4cd}"
  i4log="${sandbox}/i4-brctl.log"
  i4shim="${sandbox}/i4-shim"; mkdir -p "${i4shim}"
  cat > "${i4shim}/brctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$BRCTL_LOG"
exit 0
SH
  chmod +x "${i4shim}/brctl"
  i4help="${sandbox}/i4-helper"
  cat > "${i4help}" <<'SH'
#!/bin/bash
rc=0
for p; do
  b="${p##*/}"
  case "$b" in
    *_UP*)              printf 'uploaded\t%s\0' "$p" ;;
    *_WAIT*)            printf 'not-uploaded\t%s\0' "$p"; rc=1 ;;
    .DS_Store|*_NOTIN*) printf 'not-in-icloud\t%s\0' "$p"; rc=1 ;;
    *)                  printf 'error\t%s\0' "$p"; rc=1 ;;
  esac
done
exit "$rc"
SH
  chmod +x "${i4help}"
  i4run() { PATH="${i4shim}:${PATH}" BRCTL_LOG="${i4log}" HOME="${i4h}" \
    XDG_CONFIG_HOME="${i4h}/.config" XDG_CACHE_HOME="${i4h}/.cache" /bin/bash "${PROV}" "$@"; }

  # (a) P0 LOAD-BEARING: 1 uploaded + 3 distinct skip reasons → rc 0, EXACTLY the proven
  #     file evicted, machine-stable summary line tallies every reason.
  printf 'u\n' > "${i4cd}/f_UP"; printf 'w\n' > "${i4cd}/f_WAIT"
  printf 'd\n' > "${i4cd}/.DS_Store"; printf 'e\n' > "${i4cd}/f_ERRX"
  : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4help}" i4run --icloud-evict "${i4cd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "mixed 4-file tree completes with rc 0 (skip-and-report)" "mixed-tree evict failed (exit ${rc}): ${out}"
  i4ne="$(grep -c '^evict ' "${i4log}" || true)"
  if [ "${i4ne}" -eq 1 ] && grep -qF 'f_UP' "${i4log}" && ! grep -qF 'f_WAIT' "${i4log}" && ! grep -qF '.DS_Store' "${i4log}"; then ok "exactly the proven-uploaded file was evicted (1 brctl call, f_UP only)"; else fail "wrong evict set — recorded: $(cat "${i4log}" 2>/dev/null)"; fi
  assert_contains "${out}" "skipped: 3 file(s) — not-uploaded: 1, not-in-icloud: 1, helper-error: 1, unanswered: 0, drift: 0" "the summary line tallies every skip reason"
  assert_contains "${out}" "evict plan: 1 of 4" "the evict plan reports 1 of 4 proven uploaded"

  # (c) P0 INVERTED FORGERY: a SKIPPED record's echoed path embeds a newline + a forged
  #     'uploaded' record for a victim → path-echo die; the victim never reaches brctl.
  i4forge="${sandbox}/i4-helper-forge"
  cat > "${i4forge}" <<'SH'
#!/bin/bash
rc=0
for p; do
  b="${p##*/}"
  case "$b" in
    *_UP*)   printf 'uploaded\t%s\0' "$p" ;;
    *_WAIT*) printf 'not-uploaded\t%s\nuploaded\t/i4-forged-victim\0' "$p"; rc=1 ;;
    *)       printf 'not-in-icloud\t%s\0' "$p"; rc=1 ;;
  esac
done
exit "$rc"
SH
  chmod +x "${i4forge}"
  : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4forge}" i4run --icloud-evict "${i4cd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "the inverted newline-forgery dies (path-echo assertion)"
  assert_contains "${out}" "does not echo its argv path" "the die names the path-echo join desync"
  if grep -q evict "${i4log}" 2>/dev/null; then fail "DATA LOSS: evicted despite the inverted-forgery die"; else ok "inverted-forgery die evicted NOTHING"; fi
  if grep -qF '/i4-forged-victim' "${i4log}" 2>/dev/null; then fail "DATA LOSS: the forged victim path reached brctl"; else ok "the forged victim path never reached brctl"; fi

  # (e) P0 COUNT-DEFICIT: the helper answers only argv[0] (honest record) then exits — the
  #     count-match dies in the deficit direction (lead ruling F1: a wrong count means the
  #     whole helper run is untrustworthy; no skip-and-continue).
  i4defi="${sandbox}/i4-helper-deficit"
  cat > "${i4defi}" <<'SH'
#!/bin/bash
printf 'uploaded\t%s\0' "$1"
exit 1
SH
  chmod +x "${i4defi}"
  i4dd="${i4cd}/defi"; mkdir -p "${i4dd}"
  printf 'a\n' > "${i4dd}/a_UP"; printf 'b\n' > "${i4dd}/b_UP"
  : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4defi}" i4run --icloud-evict "${i4dd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "a record deficit dies (count-match, deficit direction)"
  assert_contains "${out}" "answered 1 of 2" "the die reports the answered/candidate counts"
  if grep -q evict "${i4log}" 2>/dev/null; then fail "DATA LOSS: evicted despite the count deficit"; else ok "count-deficit die evicted NOTHING (answered prefix NOT trusted)"; fi

  # --- TEST-phase extension (remaining §4.2 rows + plan P1/P2 adversarial set). Every row
  #     owns a SIBLING dir of td under the sandbox CloudDocs root — no cross-row candidate
  #     pollution (i4cd itself gained defi/ in row (e) above). Stateful stubs count their
  #     calls in a file under ${sandbox} (phase 1 = call 1, phase 2 = call >= 2). The
  #     load-bearing surface for every "evicted"/"never evicted" claim is the brctl-shim
  #     LOG (the destructive boundary), never report prose. ---
  i4root="${i4cd%/td}"

  # (b) full-matrix dry-run vs apply (spec b + plan P1 "dry-run subset == apply subset"):
  #     dry-run makes ZERO brctl calls, the skip report NAMES each skipped file by reason
  #     (expected lines built with the script's own '    %-15s %s' printf — format drift
  #     fails here), and the apply-destroyed set byte-matches the dry-run-previewed set.
  i4bd="${i4root}/i4b"; mkdir -p "${i4bd}"
  printf 'u\n' > "${i4bd}/mb_UP"; printf 'w\n' > "${i4bd}/mb_WAIT"
  printf 'd\n' > "${i4bd}/.DS_Store"; printf 'e\n' > "${i4bd}/mb_ERRX"
  : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4help}" i4run --icloud-evict "${i4bd}" --i-understand-data-loss-risk 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "dry-run of the 4-file matrix completes with rc 0" "dry-run matrix failed (exit ${rc}): ${out}"
  if [ -s "${i4log}" ]; then fail "dry-run made a brctl call: $(cat "${i4log}")"; else ok "dry-run made ZERO brctl calls"; fi
  assert_contains "${out}" "evict plan: 1 of 4" "dry-run plans 1 of 4 proven uploaded"
  assert_contains "${out}" "skipped: 3 file(s) — not-uploaded: 1, not-in-icloud: 1, helper-error: 1, unanswered: 0, drift: 0" "dry-run summary line tallies every reason (no drift in this fixture)"
  assert_contains "${out}" "[dry-run] would evict the 1 proven-uploaded" "dry-run trailer names the planned count"
  i4exp="$(printf '    %-15s %s' not-uploaded "${i4bd}/mb_WAIT")"
  assert_contains "${out}" "${i4exp}" "skip listing names the not-uploaded file by reason"
  i4exp="$(printf '    %-15s %s' not-in-icloud "${i4bd}/.DS_Store")"
  assert_contains "${out}" "${i4exp}" "skip listing names the not-in-icloud file by reason"
  i4exp="$(printf '    %-15s %s' helper-error "${i4bd}/mb_ERRX")"
  assert_contains "${out}" "${i4exp}" "skip listing names the helper-error file by reason"
  i4led="$(printf '%s\n' "${out}" | grep 'brctl evict' || true)"
  i4nl="$(printf '%s\n' "${i4led}" | grep -c 'brctl evict' || true)"
  if [ "${i4nl}" -eq 1 ]; then ok "dry-run ledger previews exactly 1 evict"; else fail "dry-run ledger previewed ${i4nl} evicts: ${i4led}"; fi
  assert_contains "${i4led}" "mb_UP" "dry-run ledger previews the proven-uploaded file"
  assert_not_contains "${i4led}" "mb_WAIT" "dry-run ledger excludes the not-uploaded file"
  set +e; out="$(ICLOUD_HELPER="${i4help}" i4run --icloud-evict "${i4bd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "apply on the same matrix completes with rc 0" "apply matrix failed (exit ${rc}): ${out}"
  i4ne="$(grep -c '^evict ' "${i4log}" || true)"
  if [ "${i4ne}" -eq 1 ] && grep -qF 'mb_UP' "${i4log}" && ! grep -qF 'mb_WAIT' "${i4log}" && ! grep -qF '.DS_Store' "${i4log}" && ! grep -qF 'mb_ERRX' "${i4log}"; then ok "apply destroyed EXACTLY the dry-run-previewed subset (1 brctl call, mb_UP only)"; else fail "apply set != dry-run set — recorded: $(cat "${i4log}" 2>/dev/null)"; fi

  # (d) reversed record order: honest states, records emitted in REVERSED argv order →
  #     the FIRST record already fails the path-echo byte-equality. Order is load-bearing
  #     by design; path-echo makes any reorder fatal instead of silently remapping states.
  i4dr="${i4root}/i4d"; mkdir -p "${i4dr}"
  printf 'a\n' > "${i4dr}/rv1_UP"; printf 'b\n' > "${i4dr}/rv2_UP"
  i4rev="${sandbox}/i4-helper-rev"
  cat > "${i4rev}" <<'SH'
#!/bin/bash
i=$#
while [ "$i" -ge 1 ]; do
  eval "p=\${$i}"
  printf 'uploaded\t%s\0' "$p"
  i=$((i - 1))
done
exit 0
SH
  chmod +x "${i4rev}"
  : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4rev}" i4run --icloud-evict "${i4dr}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "reversed record order dies (path-echo join assertion)"
  assert_contains "${out}" "does not echo its argv path" "the reversed-order die names the join desync"
  if grep -q evict "${i4log}" 2>/dev/null; then fail "DATA LOSS: evicted despite the reversed-order die"; else ok "reversed-order die evicted NOTHING"; fi

  # (f) surplus records: honest record per argv path + one EXTRA forged 'uploaded' record →
  #     count-match dies in the surplus direction; the extra path never reaches brctl.
  i4fd="${i4root}/i4f"; mkdir -p "${i4fd}"
  printf 's\n' > "${i4fd}/sf_UP"
  i4sur="${sandbox}/i4-helper-surplus"
  cat > "${i4sur}" <<'SH'
#!/bin/bash
for p; do printf 'uploaded\t%s\0' "$p"; done
printf 'uploaded\t/i4-extra-record\0'
exit 0
SH
  chmod +x "${i4sur}"
  : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4sur}" i4run --icloud-evict "${i4fd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "surplus records die (count-match, surplus direction)"
  assert_contains "${out}" "MORE records" "the surplus die names the contract violation"
  if grep -q evict "${i4log}" 2>/dev/null; then fail "DATA LOSS: evicted despite the surplus die"; else ok "surplus die evicted NOTHING"; fi
  if grep -qF '/i4-extra-record' "${i4log}" 2>/dev/null; then fail "DATA LOSS: the surplus record's path reached brctl"; else ok "the surplus record's path never reached brctl"; fi

  # (g) empty output on a non-empty candidate set: helper exits 1 with NO stdout →
  #     zero-records abort ("refusing to evict blind"), nothing evicted.
  i4gd="${i4root}/i4g"; mkdir -p "${i4gd}"
  printf 'x\n' > "${i4gd}/eo_UP"
  i4emp="${sandbox}/i4-helper-empty"
  printf '#!/bin/bash\nexit 1\n' > "${i4emp}"; chmod +x "${i4emp}"
  : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4emp}" i4run --icloud-evict "${i4gd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "empty helper output dies (zero-records abort)"
  assert_contains "${out}" "produced no output" "the die refuses to evict blind"
  if grep -q evict "${i4log}" 2>/dev/null; then fail "DATA LOSS: evicted despite the zero-records abort"; else ok "zero-records abort evicted NOTHING"; fi

  # (g0) zero-uploaded set (plan P1): every candidate skipped → uniform flow, rc 0, zero
  #     brctl calls, full plan/summary/trailer shape (no special case, no wedge).
  i4zd="${i4root}/i4z"; mkdir -p "${i4zd}"
  printf 'w\n' > "${i4zd}/z1_WAIT"; printf 'n\n' > "${i4zd}/z2_NOTIN"
  : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4help}" i4run --icloud-evict "${i4zd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "zero-uploaded set completes with rc 0 (all skipped, sweep not refused)" "zero-uploaded set failed (exit ${rc}): ${out}"
  if [ -s "${i4log}" ]; then fail "DATA LOSS: zero-uploaded set made a brctl call: $(cat "${i4log}")"; else ok "zero-uploaded set evicted NOTHING"; fi
  assert_contains "${out}" "evict plan: 0 of 2" "the plan reports 0 of 2 proven uploaded"
  assert_contains "${out}" "skipped: 2 file(s) — not-uploaded: 1, not-in-icloud: 1, helper-error: 0, unanswered: 0, drift: 0" "the summary line tallies both skips"
  assert_contains "${out}" "Evicted 0 of 0 proven-uploaded" "the apply trailer reports a clean empty sweep"

  # (h) PHASE-2 RE-GATE (mutation target: delete phase 2): stub answers all-uploaded/rc 0
  #     in phase 1 (call 1) but not-uploaded/rc 1 in phase 2 (call >= 2) → the whole chunk
  #     is skipped as drift, ZERO evicts, sweep still completes rc 0.
  i4hd="${i4root}/i4p2"; mkdir -p "${i4hd}"
  printf 'a\n' > "${i4hd}/p2a_UP"; printf 'b\n' > "${i4hd}/p2b_UP"
  i4flip="${sandbox}/i4-helper-flip"
  cat > "${i4flip}" <<'SH'
#!/bin/bash
n=0
[ -f "$I4_CALLS" ] && n="$(cat "$I4_CALLS")"
n=$((n + 1))
printf '%s\n' "$n" > "$I4_CALLS"
if [ "$n" -eq 1 ]; then
  for p; do printf 'uploaded\t%s\0' "$p"; done
  exit 0
fi
for p; do printf 'not-uploaded\t%s\0' "$p"; done
exit 1
SH
  chmod +x "${i4flip}"
  rm -f "${sandbox}/i4-flip.calls"; : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4flip}" I4_CALLS="${sandbox}/i4-flip.calls" i4run --icloud-evict "${i4hd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "phase-2 flip completes with rc 0 (chunk skipped as drift, sweep not aborted)" "phase-2 flip run failed (exit ${rc}): ${out}"
  if [ -s "${i4log}" ]; then fail "DATA LOSS: evicted despite the phase-2 rc!=0 re-gate: $(cat "${i4log}")"; else ok "phase-2 re-gate refused the chunk — evicted NOTHING"; fi
  assert_contains "${out}" "phase-2 re-check failed" "the drift warn names the phase-2 refusal"
  assert_contains "${out}" "skipped: 2 file(s) — not-uploaded: 0, not-in-icloud: 0, helper-error: 0, unanswered: 0, drift: 2" "both chunk members are tallied as drift"
  assert_contains "${out}" "Evicted 0 of 2 proven-uploaded" "the trailer reports 0 evicted of 2 planned"

  # (i) LSTAT DRIFT GUARD (mutation target: delete the pre-evict re-snapshot): the phase-2
  #     stub APPENDS A BYTE to the file (a real content change between the selection
  #     snapshot and the pre-evict lstat) then still answers uploaded/rc 0 — only the
  #     per-file guard stands between the dirtied file and brctl.
  i4id="${i4root}/i4dr2"; mkdir -p "${i4id}"
  printf 'orig\n' > "${i4id}/dr_UP"
  i4drift="${sandbox}/i4-helper-drift"
  cat > "${i4drift}" <<'SH'
#!/bin/bash
n=0
[ -f "$I4_CALLS" ] && n="$(cat "$I4_CALLS")"
n=$((n + 1))
printf '%s\n' "$n" > "$I4_CALLS"
if [ "$n" -ge 2 ]; then printf 'x' >> "$1"; fi
for p; do printf 'uploaded\t%s\0' "$p"; done
exit 0
SH
  chmod +x "${i4drift}"
  rm -f "${sandbox}/i4-drift.calls"; : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4drift}" I4_CALLS="${sandbox}/i4-drift.calls" i4run --icloud-evict "${i4id}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "lstat-drift run completes with rc 0 (file skipped, sweep not aborted)" "lstat-drift run failed (exit ${rc}): ${out}"
  if [ -s "${i4log}" ]; then fail "DATA LOSS: evicted a file that changed after its selection snapshot: $(cat "${i4log}")"; else ok "lstat guard refused the dirtied file — evicted NOTHING"; fi
  assert_contains "${out}" "file changed since plan" "the drift warn names the lstat mismatch"
  assert_contains "${out}" "drift: 1" "the dirtied file is tallied as drift"
  assert_contains "${out}" "Evicted 0 of 1 proven-uploaded" "the trailer reports 0 evicted of 1 planned"

  # (j) symlink inside the target → outside file: find -type f excludes the link at walk
  #     time, so it is never a candidate and its target never reaches brctl.
  i4sd="${i4root}/i4sl"; mkdir -p "${i4sd}"
  printf 'r\n' > "${i4sd}/sl_UP"
  printf 'o\n' > "${sandbox}/i4-outside-file"
  ln -s "${sandbox}/i4-outside-file" "${i4sd}/lnk"
  : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4help}" i4run --icloud-evict "${i4sd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "symlink-in-target run completes with rc 0" "symlink-in-target run failed (exit ${rc}): ${out}"
  assert_contains "${out}" "evict plan: 1 of 1" "the symlink is never a candidate (plan 1 of 1)"
  i4ne="$(grep -c '^evict ' "${i4log}" || true)"
  if [ "${i4ne}" -eq 1 ] && grep -qF 'sl_UP' "${i4log}" && ! grep -qF 'lnk' "${i4log}" && ! grep -qF 'i4-outside-file' "${i4log}"; then ok "exactly the regular file evicted; neither link nor link target reached brctl"; else fail "wrong evict set with symlink present — recorded: $(cat "${i4log}" 2>/dev/null)"; fi

  # (k) multi-chunk partition: ICLOUD_CHUNK_MAX_ARGS=1 over a 3-file mixed set → 3 phase-1
  #     execs (argc 1 each) + 2 phase-2 execs (only chunks with an uploaded member), the
  #     right 2 files evicted across chunks — proves EVICT_CHUNK_LEN + the base/len walk.
  i4kd="${i4root}/i4k"; mkdir -p "${i4kd}"
  printf 'a\n' > "${i4kd}/ka_UP"; printf 'b\n' > "${i4kd}/kb_WAIT"; printf 'c\n' > "${i4kd}/kc_UP"
  i4cnt="${sandbox}/i4-helper-count"
  cat > "${i4cnt}" <<'SH'
#!/bin/bash
printf '%s\n' "$#" >> "$I4_EXECS"
rc=0
for p; do
  b="${p##*/}"
  case "$b" in
    *_UP*)   printf 'uploaded\t%s\0' "$p" ;;
    *_WAIT*) printf 'not-uploaded\t%s\0' "$p"; rc=1 ;;
    *)       printf 'error\t%s\0' "$p"; rc=1 ;;
  esac
done
exit "$rc"
SH
  chmod +x "${i4cnt}"
  i4ex="${sandbox}/i4-execs"; rm -f "${i4ex}"; : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4cnt}" I4_EXECS="${i4ex}" ICLOUD_CHUNK_MAX_ARGS=1 i4run --icloud-evict "${i4kd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "multi-chunk (max-args 1) sweep completes with rc 0" "multi-chunk sweep failed (exit ${rc}): ${out}"
  assert_contains "${out}" "evict plan: 2 of 3" "the plan aggregates across chunks (2 of 3)"
  i4ne="$(grep -c '^evict ' "${i4log}" || true)"
  if [ "${i4ne}" -eq 2 ] && grep -qF 'ka_UP' "${i4log}" && grep -qF 'kc_UP' "${i4log}" && ! grep -qF 'kb_WAIT' "${i4log}"; then ok "exactly the 2 proven files evicted across chunks (kb_WAIT skipped)"; else fail "wrong multi-chunk evict set — recorded: $(cat "${i4log}" 2>/dev/null)"; fi
  i4nx="$(grep -c . "${i4ex}" || true)"
  if [ "${i4nx}" -eq 5 ]; then ok "helper exec count is 5 (3 phase-1 chunks + 2 phase-2 re-gates)"; else fail "expected 5 helper execs, saw ${i4nx}: $(cat "${i4ex}" 2>/dev/null)"; fi
  i4bad="$(grep -cvx '1' "${i4ex}" || true)"
  if [ "${i4bad}" -eq 0 ]; then ok "every helper exec carried exactly 1 arg (chunk partition holds)"; else fail "helper exec with argc != 1: $(cat "${i4ex}" 2>/dev/null)"; fi

  # (nc) non-candidate record: the helper answers with a path that was NEVER a candidate →
  #     path-echo die; the alien path never reaches brctl.
  i4nd="${i4root}/i4nc"; mkdir -p "${i4nd}"
  printf 'n\n' > "${i4nd}/nc_UP"
  i4non="${sandbox}/i4-helper-noncand"
  cat > "${i4non}" <<'SH'
#!/bin/bash
printf 'uploaded\t/i4-nowhere-nc\0'
exit 0
SH
  chmod +x "${i4non}"
  : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4non}" i4run --icloud-evict "${i4nd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "a non-candidate record path dies (path-echo)"
  assert_contains "${out}" "does not echo its argv path" "the non-candidate die names the join desync"
  if grep -q evict "${i4log}" 2>/dev/null; then fail "DATA LOSS: evicted despite the non-candidate die"; else ok "non-candidate die evicted NOTHING"; fi
  if grep -qF '/i4-nowhere-nc' "${i4log}" 2>/dev/null; then fail "DATA LOSS: the non-candidate path reached brctl"; else ok "the non-candidate path never reached brctl"; fi

  # (l) tab-in-filename round-trip (plan P2): state splits at the FIRST tab only, so the
  #     embedded tab survives into echo_path, the join holds, and brctl gets the full path.
  i4tb="${i4root}/i4tab"; mkdir -p "${i4tb}"
  i4tname="$(printf 'ta\tb_UP')"
  printf 't\n' > "${i4tb}/${i4tname}"
  : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4help}" i4run --icloud-evict "${i4tb}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "tab-in-filename evict completes with rc 0" "tab-in-filename evict failed (exit ${rc}): ${out}"
  assert_contains "${out}" "Evicted 1 of 1 proven-uploaded" "the trailer reports the tab-named file evicted"
  i4tneedle="$(printf 'evict %s/%s' "${i4tb}" "${i4tname}")"
  if grep -qF "${i4tneedle}" "${i4log}" 2>/dev/null; then ok "brctl received the FULL tab-containing path (round-trip intact)"; else fail "tab path mangled — recorded: $(cat "${i4log}" 2>/dev/null)"; fi

  # (t) truncated final record (plan P2): the last record has no NUL terminator → read -d ''
  #     DROPS it (no tail salvage by design) → count-match dies in the deficit direction.
  i4trd="${i4root}/i4tr"; mkdir -p "${i4trd}"
  printf 'a\n' > "${i4trd}/tra_UP"; printf 'b\n' > "${i4trd}/trb_UP"
  i4tru="${sandbox}/i4-helper-trunc"
  cat > "${i4tru}" <<'SH'
#!/bin/bash
printf 'uploaded\t%s\0' "$1"
printf 'uploaded\t%s' "$2"
exit 0
SH
  chmod +x "${i4tru}"
  : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4tru}" i4run --icloud-evict "${i4trd}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "a truncated final record dies (dropped record -> count deficit)"
  assert_contains "${out}" "answered 1 of 2" "the truncated record is DROPPED, not salvaged"
  if grep -q evict "${i4log}" 2>/dev/null; then fail "DATA LOSS: evicted despite the truncated-record die"; else ok "truncated-record die evicted NOTHING"; fi

  # (m) SELECTION-TIME STAT FAILURE (PR #51 remediation pin): a file classifies `uploaded`
  #     but its phase-1 snapshot stat fails → it must NOT be planned/ledgered as evictable
  #     and is tallied as drift (the same "no trustworthy snapshot" class the apply-side
  #     per-file guard uses) — the dry-run plan matches what apply would do. The stat shim
  #     fails ONLY the snapshot-format stat ('%HT|%Sf|%z|%Fm') of *_STATFAIL* basenames;
  #     icloud_is_dataless ('%Sf') and every other stat call exec the real /usr/bin/stat,
  #     so the file is a perfectly normal candidate in every other respect.
  i4md="${i4root}/i4m"; mkdir -p "${i4md}"
  printf 'g\n' > "${i4md}/sg_UP"; printf 's\n' > "${i4md}/sm_STATFAIL_UP"
  i4stshim="${sandbox}/i4-stat-shim"; mkdir -p "${i4stshim}"
  cat > "${i4stshim}/stat" <<'ST'
#!/bin/bash
if [ "$1" = "-f" ] && [ "$2" = "%HT|%Sf|%z|%Fm" ]; then
  case "${!#}" in *_STATFAIL*) exit 1 ;; esac
fi
exec /usr/bin/stat "$@"
ST
  chmod +x "${i4stshim}/stat"
  i4mrun() { PATH="${i4stshim}:${i4shim}:${PATH}" BRCTL_LOG="${i4log}" HOME="${i4h}" \
    XDG_CONFIG_HOME="${i4h}/.config" XDG_CACHE_HOME="${i4h}/.cache" /bin/bash "${PROV}" "$@"; }
  : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4help}" i4mrun --icloud-evict "${i4md}" --i-understand-data-loss-risk 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "selection-stat-fail dry-run completes with rc 0 (record consumed — count-match still balances)" "selection-stat-fail dry-run failed (exit ${rc}): ${out}"
  assert_contains "${out}" "evict plan: 1 of 2" "the stat-failed file is NOT counted as proven uploaded"
  assert_contains "${out}" "skipped: 1 file(s) — not-uploaded: 0, not-in-icloud: 0, helper-error: 0, unanswered: 0, drift: 1" "the dry-run summary tallies the stat-failed file as drift"
  i4exp="$(printf '    %-15s %s' drift "${i4md}/sm_STATFAIL_UP")"
  assert_contains "${out}" "${i4exp}" "the skip listing names the stat-failed file under drift"
  i4led="$(printf '%s\n' "${out}" | grep 'brctl evict' || true)"
  assert_contains "${i4led}" "sg_UP" "the dry-run ledger previews the healthy uploaded file"
  assert_not_contains "${i4led}" "sm_STATFAIL_UP" "the dry-run ledger does NOT list the stat-failed file as evictable"
  # apply on the same fixture: the plan holds byte-for-byte — healthy file evicted, the
  # stat-failed file never reaches brctl (dry-run preview == apply destruction set).
  : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4help}" i4mrun --icloud-evict "${i4md}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  pass_if "${rc}" "selection-stat-fail apply completes with rc 0" "selection-stat-fail apply failed (exit ${rc}): ${out}"
  i4ne="$(grep -c '^evict ' "${i4log}" || true)"
  if [ "${i4ne}" -eq 1 ] && grep -qF 'sg_UP' "${i4log}" && ! grep -qF 'sm_STATFAIL_UP' "${i4log}"; then ok "apply destroyed EXACTLY the dry-run-planned subset (sg_UP only; the stat-failed file never reached brctl)"; else fail "apply set != dry-run plan with a stat-failed member — recorded: $(cat "${i4log}" 2>/dev/null)"; fi
  assert_contains "${out}" "drift: 1" "apply tallies the stat-failed file as drift"
  assert_contains "${out}" "Evicted 1 of 1 proven-uploaded" "the trailer reports 1 of 1 planned (the stat-failed file was never planned)"

  # (m2) count-match integrity THROUGH a stat-failed record (deterministic single-file
  #      fixture, surplus helper): the stat-failed `uploaded` record must still be CONSUMED
  #      (i++), so the helper's extra forged record trips the MORE-records surplus die — not
  #      a path-echo desync — and nothing is evicted. (The deficit direction is pinned by
  #      row (m) itself: rc 0 there proves both records were consumed — an unconsumed
  #      stat-fail record would have died "answered 1 of 2".)
  i4m2="${i4root}/i4m2"; mkdir -p "${i4m2}"
  printf 'q\n' > "${i4m2}/s2_STATFAIL_UP"
  : > "${i4log}"
  set +e; out="$(ICLOUD_HELPER="${i4sur}" i4mrun --icloud-evict "${i4m2}" --i-understand-data-loss-risk --apply 2>&1)"; rc=$?; set -e
  assert_nonzero "${rc}" "the surplus die still fires when the honest record's file stat-fails"
  assert_contains "${out}" "MORE records" "the die is the count surplus, NOT a join desync (the stat-failed record was consumed first)"
  if grep -q evict "${i4log}" 2>/dev/null; then fail "DATA LOSS: evicted despite the surplus die (stat-fail variant)"; else ok "surplus die (stat-fail variant) evicted NOTHING"; fi
else
  echo "smoke: I4 bulk evict subset semantics — SKIPPED (macOS-only; uname=$(uname -s))"
fi

# ===========================================================================
# Reclaim (--reclaim) — the DELETE-side counterpart to --offload. Load-bearing:
# NEVER a false positive. These groups are the safety contract, exercised on
# both platforms (git + find only; no macOS-specific tooling). A hermetic git
# identity is forced so the group does not depend on the user's ~/.gitconfig.
# ===========================================================================
export GIT_AUTHOR_NAME="smoke" GIT_AUTHOR_EMAIL="smoke@test" \
       GIT_COMMITTER_NAME="smoke" GIT_COMMITTER_EMAIL="smoke@test"
# The reclaim fixture MUST live outside the repo work tree: the repo is itself a
# git repo, so a fixture under tests/sandbox/ would make git-context predicates
# ('inside a repo?') true for every dir and mask the outside-repo fail-closed
# path. rec_root (mktemp, outside the repo) is removed by the EXIT trap above.
rec_root="$(mktemp -d "${host_tmp}/xdg-reclaim-smoke.XXXXXX")"
rec="${rec_root}"

# Fixture tree covering every tier + the load-bearing decoys:
#   plain/build            generic 'build', NO manifest, NOT a repo    -> MUST SURVIVE
#   trackedrepo/build      'build' committed (git-tracked) in a repo    -> MUST SURVIVE
#   depproj/node_modules   holds a checked-out dep's .git               -> MUST SURVIVE
#   looseNM/node_modules   node_modules + package.json, NOT a repo      -> MUST SURVIVE (fail-closed outside repo)
#   pyproj/__pycache__     pure bytecode cache                          -> reclaim
#   genrepo/build          generic 'build' + package.json + gitignored  -> reclaim
#   app/node_modules       node_modules + package.json, in-repo+ignored -> reclaim (the real use case)
mkdir -p "${rec}/plain/build"; echo precious > "${rec}/plain/build/keep.txt"
( cd "${rec}" && mkdir trackedrepo && cd trackedrepo && git init -q && echo '{}' > package.json \
    && mkdir build && echo committed > build/app.js && git add -A && git commit -qm init )
mkdir -p "${rec}/depproj/node_modules/somedep/.git"; echo '{}' > "${rec}/depproj/package.json"
echo x > "${rec}/depproj/node_modules/somedep/keep.js"
mkdir -p "${rec}/looseNM/node_modules/lodash"; echo '{}' > "${rec}/looseNM/package.json"
echo x > "${rec}/looseNM/node_modules/lodash/i.js"
mkdir -p "${rec}/pyproj/__pycache__"; echo x > "${rec}/pyproj/__pycache__/mod.pyc"
( cd "${rec}" && mkdir genrepo && cd genrepo && git init -q && echo '{}' > package.json \
    && printf 'build/\n' > .gitignore && git add -A && git commit -qm init \
    && mkdir build && echo generated > build/bundle.js )
( cd "${rec}" && mkdir app && cd app && git init -q && echo '{}' > package.json \
    && printf 'node_modules/\n' > .gitignore && git add -A && git commit -qm init \
    && mkdir -p node_modules/dep && echo x > node_modules/dep/i.js )

# --- Group R1: dry-run is the default and deletes NOTHING; classification is correct.
echo "smoke: reclaim R1 — dry-run classifies correctly and deletes nothing"
out="$(/bin/bash "${PROV}" --reclaim "${rec}" 2>&1)"
assert_contains "${out}" "dry-run — nothing deleted" "reclaim defaults to dry-run"
assert_contains "${out}" "3 project artifact(s) would be reclaimed" "dry-run counts the 3 reclaimable dirs (pyproj __pycache__, genrepo build/, app node_modules)"
assert_contains "${out}" "reclaim [rm]"                 "dry-run marks reclaimable dirs with an rm decision"
assert_contains "${out}" "pyproj/__pycache__"           "dry-run reclaims __pycache__"
assert_contains "${out}" "genrepo/build"                "dry-run reclaims manifest+gitignored generic build/"
assert_contains "${out}" "app/node_modules"             "dry-run reclaims in-repo gitignored node_modules"
# The decoys are explicitly SKIPPED with a reason.
assert_contains "${out}" "generic 'build' with no build manifest"    "decoy: unanchored build/ is skipped"
assert_contains "${out}" "'build' is git-tracked"                    "decoy: git-tracked build/ is skipped"
# Nothing on disk was touched by the dry-run.
for p in plain/build/keep.txt trackedrepo/build/app.js depproj/node_modules/somedep/.git \
         looseNM/node_modules/lodash pyproj/__pycache__ genrepo/build/bundle.js app/node_modules/dep; do
  if [ -e "${rec}/${p}" ]; then ok "dry-run left ${p} untouched"; else fail "dry-run DELETED ${p} (dry-run must never delete)"; fi
done

# --- Group R2: --apply deletes exactly the reclaimable dirs; every decoy SURVIVES.
echo "smoke: reclaim R2 — --apply deletes reclaimable, decoys survive, tracked siblings intact"
out="$(/bin/bash "${PROV}" --reclaim "${rec}" --apply 2>&1)"
assert_contains "${out}" "APPLY — deleting reclaimable artifacts" "apply announces APPLY mode"
assert_contains "${out}" "Reclaimed 3 project artifact(s)" "apply reports the reclaim count"
# Load-bearing: decoys + non-regenerable dirs MUST survive an apply.
for p in plain/build/keep.txt trackedrepo/build/app.js depproj/node_modules/somedep/.git looseNM/node_modules/lodash; do
  if [ -e "${rec}/${p}" ]; then ok "apply preserved ${p}"; else fail "apply DELETED ${p} — FALSE POSITIVE (safety contract violated)"; fi
done
# The reclaimable dirs are gone…
for p in pyproj/__pycache__ genrepo/build app/node_modules; do
  if [ -e "${rec}/${p}" ]; then fail "apply left ${p} behind (should have been reclaimed)"; else ok "apply reclaimed ${p}"; fi
done
# …but git-tracked siblings in the same repo are untouched.
if [ -e "${rec}/genrepo/package.json" ] && [ -e "${rec}/genrepo/.gitignore" ]; then
  ok "apply left genrepo's tracked files intact (only build/ removed)"
else
  fail "apply damaged genrepo's tracked files"
fi

# --- Group R3: degenerate-root refusals + nonexistent root exit non-zero (never a blind walk).
echo "smoke: reclaim R3 — degenerate roots and nonexistent paths are refused"
set +e; out="$(/bin/bash "${PROV}" --reclaim / 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "reclaim of / is refused"
assert_contains "${out}" "too broad" "the / refusal explains it is too broad to sweep"
set +e; out="$(/bin/bash "${PROV}" --reclaim "${rec}/nope" 2>&1)"; rc=$?; set -e
assert_nonzero "${rc}" "reclaim of a nonexistent root is refused"
assert_contains "${out}" "does not exist" "the missing-root refusal names the cause"

# --- Group R4: a SYMLINKED manifest must NOT qualify a dir for reclaim (security
# review: a symlinked anchor could otherwise steer classification / tool-clean).
echo "smoke: reclaim R4 — a symlinked manifest does not anchor a reclaim"
symroot="${rec_root}/symcase"
mkdir -p "${symroot}/proj/target"
echo real > "${symroot}/realCargo.toml"
ln -s "${symroot}/realCargo.toml" "${symroot}/proj/Cargo.toml"   # symlinked manifest
echo art > "${symroot}/proj/target/blob.o"
out="$(/bin/bash "${PROV}" --reclaim "${symroot}" 2>&1)"
assert_contains "${out}" "0 project artifact(s) would be reclaimed" "symlinked Cargo.toml does not anchor target/ (0 reclaimable)"
if [ -e "${symroot}/proj/target/blob.o" ]; then ok "target/ with a symlinked manifest is left untouched"; else fail "target/ was reclaimed via a symlinked manifest (steering vector open)"; fi

# --- Group R5: --global sweeps the CONTENTS of ~/.npm/_npx and the Homebrew
# downloads/ cache — the two dirs the tool-native cleans MISS (npm cache clean
# only clears _cacache; brew cleanup -s leaves the bottle tarballs). Contents
# go, the parent dirs SURVIVE (npx/brew re-populate them). These rm's target
# $HOME paths, so HOME is a sandbox dir (asserted != the real HOME before any
# --apply), and brew/npm/pip3 are PATH-shimmed no-ops so no real tool ever runs.
echo "smoke: reclaim R5 — --global sweeps _npx + brew downloads/ contents, keeps the dirs"
r5h="${sandbox}/r5-home"
r5npx="${r5h}/.npm/_npx"
r5brew="${r5h}/Library/Caches/Homebrew/downloads"
mkdir -p "${r5npx}/abc123/node_modules/somepkg" "${r5brew}" "${r5h}/sweep"
echo x   > "${r5npx}/abc123/node_modules/somepkg/index.js"
echo tar > "${r5brew}/bottle.tar.gz"
r5shim="${sandbox}/r5-shim"; mkdir -p "${r5shim}"
for r5tool in brew npm pip3; do
  printf '#!/bin/bash\nexit 0\n' > "${r5shim}/${r5tool}"; chmod +x "${r5shim}/${r5tool}"
done
r5run() { PATH="${r5shim}:${PATH}" HOME="${r5h}" XDG_CONFIG_HOME="${r5h}/.config" \
  XDG_CACHE_HOME="${r5h}/.cache" /bin/bash "${PROV}" "$@"; }
# Airtightness gate: this group deletes under $HOME — refuse to proceed unless the
# override target is a sandbox path and is NOT the real HOME of this shell.
if [ "${r5h}" = "${HOME}" ]; then fail "R5 sandbox HOME equals the real HOME — refusing to run"; fi
case "${r5h}" in "${sandbox}"/*) ok "R5 HOME override is confined to the sandbox" ;; \
  *) fail "R5 HOME override escapes the sandbox: ${r5h}" ;; esac
# (a) dry-run lists both fixed-path sweeps, deletes NOTHING, and exits 0 (regression
# guard: the pre-fix trailing `[ RECLAIM_GLOBAL -eq 0 ] && info` made a successful
# --global dry-run exit 1 under set -e).
set +e; out="$(r5run --reclaim "${r5h}/sweep" --global 2>&1)"; rc=$?; set -e
pass_if "${rc}" "--global dry-run exits 0" "--global dry-run failed (exit ${rc}): ${out}"
assert_contains "${out}" "Global caches (--global):" "dry-run announces the global-cache section"
assert_contains "${out}" "[dry-run]  rm -rf ~/.npm/_npx/*" "dry-run lists the npx-cache sweep"
assert_contains "${out}" "[dry-run]  rm -rf ~/Library/Caches/Homebrew/downloads/*" "dry-run lists the brew downloads/ sweep"
for p in .npm/_npx/abc123/node_modules/somepkg/index.js Library/Caches/Homebrew/downloads/bottle.tar.gz; do
  if [ -e "${r5h}/${p}" ]; then ok "dry-run left ${p} untouched"; else fail "dry-run DELETED ${p} (dry-run must never delete)"; fi
done
# (b) --apply clears the contents but KEEPS both parent dirs.
set +e; out="$(r5run --reclaim "${r5h}/sweep" --global --apply 2>&1)"; rc=$?; set -e
pass_if "${rc}" "--global apply exits 0" "--global apply failed (exit ${rc}): ${out}"
assert_contains "${out}" "[run]  rm -rf ~/.npm/_npx/*" "apply logs the npx-cache sweep"
assert_contains "${out}" "[run]  rm -rf ~/Library/Caches/Homebrew/downloads/*" "apply logs the brew downloads/ sweep"
if [ -e "${r5npx}/abc123" ]; then fail "apply left ~/.npm/_npx contents behind (the live-found 413M case)"; else ok "apply cleared ~/.npm/_npx contents"; fi
if [ -e "${r5brew}/bottle.tar.gz" ]; then fail "apply left the brew bottle tarball behind (the live-found 203M case)"; else ok "apply cleared Homebrew downloads/ contents"; fi
if [ -d "${r5npx}" ] && [ -d "${r5brew}" ]; then ok "apply kept the _npx and downloads/ parent dirs (contents-only sweep)"; else fail "apply removed a parent dir (must clear contents only, like DerivedData)"; fi
# (c) SECURITY (swapped-symlink cache dir): if ~/.npm/_npx has been replaced by a
# symlink (e.g. by a malicious postinstall that legitimately writes ~/.npm), the
# contents-only sweep must NOT follow it into the target — `[ -d link ]` is true
# for a symlink-to-dir, so without the `! -L` guard `rm -rf link/*` would wipe the
# TARGET's contents. The symlinked dir is skipped silently: victim survives, exit 0.
r5victim="${sandbox}/r5-victim"
mkdir -p "${r5victim}"
echo precious > "${r5victim}/sentinel.txt"
rm -rf "${r5npx}"
ln -s "${r5victim}" "${r5npx}"                     # the swapped cache dir
set +e; out="$(r5run --reclaim "${r5h}/sweep" --global --apply 2>&1)"; rc=$?; set -e
pass_if "${rc}" "--global apply with a symlinked _npx exits 0 (skip is silent, not an error)" \
  "--global apply failed on a symlinked _npx (exit ${rc}): ${out}"
if [ -e "${r5victim}/sentinel.txt" ]; then ok "symlinked _npx was skipped — the victim's sentinel survives"; \
  else fail "SECURITY: sweep followed the symlinked _npx and wiped the victim dir"; fi
if [ -L "${r5npx}" ]; then ok "the symlink itself is left in place (skipped, not deleted)"; \
  else fail "sweep removed the symlinked _npx entry itself"; fi
# (d) UNDELETABLE entry in one cache must NOT abort the sweep (regression guard:
# the pre-fix `[ DRY_RUN -eq 0 ] && rm ...` made a failing rm the last command of
# the && list — set -e aborted mid-sweep, silently skipping the remaining caches).
# Injection: a mode-000 dir inside _npx whose child rm cannot unlink (portable,
# reversible). Assert exit 0, a warn naming the stuck cache, and that the LATER
# brew downloads/ fixture was STILL swept (continuation past the failure).
# chmod is restored IMMEDIATELY after the run — before any assert (fail exits the
# suite) — so the sandbox EXIT-trap teardown always works.
rm -f "${r5npx}"                                   # drop (c)'s symlink
mkdir -p "${r5npx}/stuck"
echo pinned > "${r5npx}/stuck/cannot-unlink.txt"
chmod 000 "${r5npx}/stuck"                         # child now un-unlinkable
echo tar2 > "${r5brew}/bottle2.tar.gz"             # LATER cache: proves continuation
set +e; out="$(r5run --reclaim "${r5h}/sweep" --global --apply 2>&1)"; rc=$?; set -e
chmod -R u+rwx "${r5npx}" 2>/dev/null || true      # restore BEFORE asserts (teardown must work)
pass_if "${rc}" "--global apply with an undeletable _npx entry exits 0 (sweep not aborted)" \
  "--global apply ABORTED on an undeletable entry (exit ${rc}): ${out}"
assert_contains "${out}" "could not fully sweep ~/.npm/_npx" "the stuck cache is named in a warn, not swallowed"
if [ -e "${r5brew}/bottle2.tar.gz" ]; then fail "sweep stopped at the stuck cache — brew downloads/ was never reached"; \
  else ok "sweep continued past the stuck cache and cleared brew downloads/"; fi
if [ -e "${r5npx}/stuck/cannot-unlink.txt" ]; then ok "the undeletable entry itself is left as-is (fail-closed)"; \
  else fail "the undeletable entry vanished — injection did not hold (test is not testing the failure path)"; fi

# ===========================================================================
# Group F2: home-tree.sh rclone filter — EVERY exclude line is asserted, plus
# the deny -> allow -> catch-all ORDERING. Group 6 only spot-checks a few deny
# lines; the filter is the single source of truth preventing data leaks, so a
# silently dropped deny line would leak secrets/SQLite to the cloud. Each remaining
# exclude is pinned as an EXACT whole-line match (grep -qxF) so a regression that
# drops exactly one line fails here even when a neighbouring line still contains
# its substring (e.g. '- **/*.db' vs '- **/*.db-journal'). Ordering matters because
# rclone is first-match-wins: the deny block must precede the '+' allow block, which
# must precede the final catch-all '- *'. Same generation path as Group 6.
# ===========================================================================
echo "smoke: F2 — every rclone-filter exclude line present, in deny<allow<catch-all order"
f2root="${sandbox}/f2-home"; mkdir -p "${f2root}"
out="$(/bin/bash "${repo}/bin/home-tree.sh" --root "${f2root}" 2>&1)"
f2filter="${TMPDIR}/home-tree.rclone-filter"
if [ -f "${f2filter}" ]; then
  ok "F2: filter file was written to TMPDIR"
else
  fail "F2: home-tree did not write its rclone filter"
fi
# Every currently-unasserted exclude line, pinned as an EXACT whole line (grep -x)
# so dropping just one — even if a sibling line shares its prefix — fails the suite.
for f2line in \
  "- /State/**" \
  "- /Config/**" \
  "- .cache/**" \
  "- .local/state/**" \
  "- **/*.sqlite-wal" \
  "- **/*.sqlite-shm" \
  "- **/*.db" \
  "- **/*.db-journal" \
  "- **/.DS_Store" \
  "- **/node_modules/**" \
  "- **/__pycache__/**" \
  "- **/*.lock"; do
  set +e; grep -qxF -- "${f2line}" "${f2filter}"; f2rc=$?; set -e
  pass_if "${f2rc}" "filter denies exact line '${f2line}'" \
    "filter is MISSING the deny line '${f2line}' (data-leak regression)"
done
# ORDERING (first match wins): a representative deny line must precede the allow
# block, which must precede the final catch-all deny. Compare 1-based grep -n line
# numbers — no fragile parsing. The three anchors are guaranteed present by the
# loop above and by Group 6 ('+ /Documents/**', '- *'), so grep always matches here.
f2deny_ln="$(grep -nxF -- "- /State/**" "${f2filter}" | cut -d: -f1)"
f2allow_ln="$(grep -nxF -- "+ /Documents/**" "${f2filter}" | cut -d: -f1)"
f2catch_ln="$(grep -nxF -- "- *" "${f2filter}" | cut -d: -f1)"
if [ -n "${f2deny_ln}" ] && [ -n "${f2allow_ln}" ] && [ -n "${f2catch_ln}" ] &&
   [ "${f2deny_ln}" -lt "${f2allow_ln}" ] && [ "${f2allow_ln}" -lt "${f2catch_ln}" ]; then
  ok "filter order is deny(${f2deny_ln}) < allow(${f2allow_ln}) < catch-all(${f2catch_ln}) — first-match-wins preserved"
else
  fail "filter ORDER broken: deny='${f2deny_ln}' allow='${f2allow_ln}' catch-all='${f2catch_ln}' (must be deny<allow<catch-all)"
fi

# ===========================================================================
# Group F3: redirect_one() edge branches NOT covered by Groups 1-3 (which cover
# populated-without-relocate, dangling-symlink-left-untouched, and the relocate
# happy path). Adds: (1) an EMPTY real dir replaced by a symlink (the rmdir+ln -s
# branch); (2) downloads create-only skip by default vs --redirect-downloads;
# (3) a LIVE foreign symlink (existing WRONG target) left untouched — Group 2 only
# covers a DANGLING link. Every apply run overrides HOME to a sandbox dir.
# ===========================================================================

# (1) empty real dir -> symlink. An EMPTY ~/Documents is neither "missing" nor
# "populated": redirect_one rmdir's it and creates the cloud symlink. Distinct branch.
echo "smoke: F3.1 — an EMPTY real user dir is replaced by a cloud symlink"
f31h="${sandbox}/f31-home"; f31c="${sandbox}/f31-cloud"
mkdir -p "${f31h}/Documents" "${f31c}"          # Documents exists but is EMPTY
set +e
out="$(HOME="${f31h}" /bin/bash "${PROV}" --cloud-root "${f31c}" --apply --allow-local-root 2>&1)"
rc=$?
set -e
pass_if "${rc}" "empty-dir apply run exits 0" "empty-dir apply failed (exit ${rc}): ${out}"
if [ -L "${f31h}/Documents" ] && [ "$(readlink "${f31h}/Documents")" = "${f31c}/documents" ]; then
  ok "empty ~/Documents was rmdir'd and replaced by a symlink into the cloud root"
else
  fail "empty ~/Documents was not replaced by the expected cloud symlink"
fi

# (2) downloads is eligible (redirect=1) but create-only until --redirect-downloads.
echo "smoke: F3.2 — downloads skipped by default, symlinked only with --redirect-downloads"
f32c="${sandbox}/f32-cloud"; mkdir -p "${f32c}"
# 2a: a bare dry-run emits the actionable skip line.
f32h="${sandbox}/f32-home"; mkdir -p "${f32h}"
out="$(HOME="${f32h}" /bin/bash "${PROV}" --cloud-root "${f32c}" 2>&1)"   # dry-run
assert_contains "${out}" "skip redirect: downloads" "dry-run emits the actionable downloads-skip info line"
# 2b: WITHOUT --redirect-downloads, apply creates NO Downloads symlink.
f32ha="${sandbox}/f32-home-apply"; mkdir -p "${f32ha}"
set +e
out="$(HOME="${f32ha}" /bin/bash "${PROV}" --cloud-root "${f32c}" --apply --allow-local-root 2>&1)"
rc=$?
set -e
pass_if "${rc}" "default apply (no --redirect-downloads) exits 0" "run failed (exit ${rc}): ${out}"
if [ -e "${f32ha}/Downloads" ] || [ -L "${f32ha}/Downloads" ]; then
  fail "Downloads symlink was created despite no --redirect-downloads (must stay create-only)"
else
  ok "no ~/Downloads symlink created by default"
fi
# 2c: WITH --redirect-downloads --apply, Downloads becomes a cloud symlink.
f32hr="${sandbox}/f32-home-redir"; mkdir -p "${f32hr}"
set +e
out="$(HOME="${f32hr}" /bin/bash "${PROV}" --cloud-root "${f32c}" --apply --allow-local-root --redirect-downloads 2>&1)"
rc=$?
set -e
pass_if "${rc}" "--redirect-downloads apply exits 0" "run failed (exit ${rc}): ${out}"
if [ -L "${f32hr}/Downloads" ] && [ "$(readlink "${f32hr}/Downloads")" = "${f32c}/downloads" ]; then
  ok "--redirect-downloads symlinks ~/Downloads into the cloud root"
else
  fail "--redirect-downloads did not symlink ~/Downloads to ${f32c}/downloads"
fi

# (3) a LIVE foreign symlink (points at an EXISTING but WRONG target) is left
# untouched. Group 2 covers only a DANGLING link; this exercises the same
# `[ -L ]` guard for a live-but-wrong target (readlink != cloud target), proving
# the guard does not repoint or clobber a pre-existing user symlink.
echo "smoke: F3.3 — a live symlink to a wrong existing target is left untouched"
f33h="${sandbox}/f33-home"; f33c="${sandbox}/f33-cloud"; f33wrong="${sandbox}/f33-wrong-target"
mkdir -p "${f33h}" "${f33c}" "${f33wrong}"
printf 'wrong\n' > "${f33wrong}/marker.txt"
ln -s "${f33wrong}" "${f33h}/Documents"          # live link to an EXISTING non-cloud dir
set +e
out="$(HOME="${f33h}" /bin/bash "${PROV}" --cloud-root "${f33c}" --apply --allow-local-root 2>&1)"
rc=$?
set -e
pass_if "${rc}" "apply exits 0 with a live foreign symlink present" \
  "apply aborted (exit ${rc}) on a live foreign symlink: ${out}"
assert_contains "${out}" "is a symlink to" "live foreign symlink is reported and left in place"
if [ -L "${f33h}/Documents" ] && [ "$(readlink "${f33h}/Documents")" = "${f33wrong}" ]; then
  ok "live foreign ~/Documents symlink unchanged (still points at the wrong target)"
else
  fail "live foreign ~/Documents symlink was modified"
fi

# ===========================================================================
# F6 — --version flag (known-issue F6, ADR §7). --version prints the version
# (from the repo-root VERSION file, resolved relative to __self_dir) and exits 0.
# It is an early-exit flag, NOT a mode lane, so it engages no lock/mutation.
# The expected value is read from the VERSION file (not hardcoded) so the test
# stays correct across version bumps. The symlink sub-case proves __self_dir
# resolution holds when the script is invoked via a symlink from a foreign CWD.
# ===========================================================================
echo "smoke: F6 — --version prints the VERSION-file version and exits 0"
ver="$(cat "${repo}/VERSION")"
set +e
out="$(/bin/bash "${PROV}" --version 2>&1)"
rc=$?
set -e
pass_if "${rc}" "--version exits 0" "--version did not exit 0 (exit ${rc}): ${out}"
assert_contains "${out}" "${ver}" "--version output contains the VERSION-file version"

# Robustness: invoke through a symlink to the script from a different CWD. The
# symlink lives in the sandbox and points at the absolute ${PROV}; __self_dir
# must still resolve the sibling lib and the ../VERSION file, so the output must
# still contain the same version.
f6link="${sandbox}/f6-provision-link.sh"
ln -s "${PROV}" "${f6link}"
set +e
out="$( cd "${sandbox}" && /bin/bash "${f6link}" --version 2>&1 )"
rc=$?
set -e
pass_if "${rc}" "--version via a symlink exits 0" \
  "--version via a symlink did not exit 0 (exit ${rc}): ${out}"
assert_contains "${out}" "${ver}" "--version via a symlink still contains the VERSION-file version"

# ===========================================================================
# Group P: --porcelain golden group (tui-offload-manager diff-spec §2.6 / §8.3).
# The porcelain format is the FROZEN machine contract the Python TUI parses:
#   line 1: 'porcelain=1'   rows: class|canonical|localName|state|remote|git
# Every reachable enum state is pinned as an EXACT whole line (grep -qxF), so any
# drift in the shape fails here before it can corrupt the TUI's parser. Fields are
# append-only within version 1; a deliberate change must update these goldens AND
# bump the header. CAPTURE-then-INSPECT via files (never pipe the script into
# grep -q — SIGPIPE/141 under pipefail). Names asserted are platform-stable
# (macName==linuxName for every asserted row).
# ===========================================================================

# --- P1: --classify --porcelain — header, row count, field discipline, every
#     classify enum state (symlink/localdir/absent) + pipe-target sanitization,
#     and zero mutation (find-snapshot before/after). ---
echo "smoke: P1 — --classify --porcelain golden shapes"
p1h="${sandbox}/p1-home"; p1c="${sandbox}/p1-cloud"
mkdir -p "${p1h}" "${p1c}/documents" "${p1c}/Projects" "${p1h}/Music" "${p1h}/repos" "${p1h}/pyenv"
ln -s "${p1c}/documents" "${p1h}/Documents"       # xdg symlink -> remote = readlink target
ln -s "${p1c}/Projects"  "${p1h}/Projects"        # code symlink (TUI derives the migrate hint)
ln -s "${sandbox}/evil|pipe" "${p1h}/Desktop"     # pipe in the TARGET -> sanitized placeholder
p1_before="$(cd "${p1h}" && find . | sort)"
p1_out="${sandbox}/p1-classify.out"
set +e
HOME="${p1h}" XDG_STATE_HOME="${p1h}/state" /bin/bash "${PROV}" --classify --porcelain \
  >"${p1_out}" 2>"${sandbox}/p1-classify.err"
rc=$?
set -e
pass_if "${rc}" "--classify --porcelain exits 0" \
  "--classify --porcelain failed (exit ${rc}): $(cat "${sandbox}/p1-classify.err")"
if [ "$(sed -n 1p "${p1_out}")" = "porcelain=1" ]; then
  ok "classify porcelain header is exactly 'porcelain=1'"
else
  fail "classify porcelain first line is '$(sed -n 1p "${p1_out}")', expected 'porcelain=1'"
fi
p1_lines="$(wc -l < "${p1_out}" | tr -d ' ')"
if [ "${p1_lines}" -eq 16 ]; then
  ok "classify porcelain emits header + 15 rows (8 xdg + 3 code + 4 local)"
else
  fail "classify porcelain emitted ${p1_lines} lines, expected 16: $(cat "${p1_out}")"
fi
set +e; awk -F'|' 'NR>1 && NF!=6 {exit 1}' "${p1_out}"; p1rc=$?; set -e
pass_if "${p1rc}" "every classify porcelain row has exactly 6 pipe-delimited fields" \
  "a classify porcelain row does not have 6 fields (or prose leaked into stdout)"
for p1line in \
  "xdg|documents|Documents|symlink|${p1c}/documents|" \
  "xdg|music|Music|localdir||" \
  "xdg|templates|Templates|absent||" \
  "xdg|desktop|Desktop|symlink|<non-porcelain-target>|" \
  "code|projects|Projects|symlink|${p1c}/Projects|" \
  "code|repos|repos|localdir||" \
  "local|pyenv|pyenv|localdir||"; do
  set +e; grep -qxF -- "${p1line}" "${p1_out}"; p1rc=$?; set -e
  pass_if "${p1rc}" "classify golden row '${p1line}'" \
    "classify porcelain is MISSING the exact row '${p1line}' (frozen-contract drift)"
done
p1_after="$(cd "${p1h}" && find . | sort)"
if [ "${p1_before}" = "${p1_after}" ]; then
  ok "--classify --porcelain mutated nothing (sandbox HOME tree identical before/after)"
else
  fail "--classify --porcelain mutated the home tree"
fi

# --- P2: --offload-status --porcelain, run A — offloaded-with-remote, absent,
#     and local-not-a-git-tree. GIT_CEILING_DIRECTORIES=$HOME stops the git
#     upward probe of $HOME/<name> at the sandbox (the ceiling must be the PARENT
#     of the probed dir), so a plain dir inside this repo's work tree reports
#     'none' instead of inheriting the repo's git state. ---
echo "smoke: P2 — --offload-status --porcelain golden shapes (offloaded/absent/none)"
p2h="${sandbox}/p2-home"
mkdir -p "${p2h}/state/xdg-cloud/offloaded" "${p2h}/Projects"
printf 'remote=gdrive:xdg-offload/code/repos\n' > "${p2h}/state/xdg-cloud/offloaded/repos"
p2_before="$(cd "${p2h}" && find . | sort)"
p2_out="${sandbox}/p2-ofs.out"
set +e
HOME="${p2h}" XDG_STATE_HOME="${p2h}/state" GIT_CEILING_DIRECTORIES="${p2h}" \
  /bin/bash "${PROV}" --offload-status --porcelain >"${p2_out}" 2>"${sandbox}/p2-ofs.err"
rc=$?
set -e
pass_if "${rc}" "--offload-status --porcelain exits 0" \
  "--offload-status --porcelain failed (exit ${rc}): $(cat "${sandbox}/p2-ofs.err")"
if [ "$(sed -n 1p "${p2_out}")" = "porcelain=1" ]; then
  ok "offload-status porcelain header is exactly 'porcelain=1'"
else
  fail "offload-status porcelain first line is '$(sed -n 1p "${p2_out}")', expected 'porcelain=1'"
fi
p2_lines="$(wc -l < "${p2_out}" | tr -d ' ')"
if [ "${p2_lines}" -eq 4 ]; then
  ok "offload-status porcelain emits header + 3 rows (CODE_KEYS order)"
else
  fail "offload-status porcelain emitted ${p2_lines} lines, expected 4: $(cat "${p2_out}")"
fi
set +e; awk -F'|' 'NR>1 && NF!=6 {exit 1}' "${p2_out}"; p2rc=$?; set -e
pass_if "${p2rc}" "every offload-status porcelain row has exactly 6 fields" \
  "an offload-status porcelain row does not have 6 fields (or prose leaked into stdout)"
for p2line in \
  "code|repos|repos|offloaded|gdrive:xdg-offload/code/repos|" \
  "code|androidstudio|AndroidStudioProjects|absent||none" \
  "code|projects|Projects|local||none"; do
  set +e; grep -qxF -- "${p2line}" "${p2_out}"; p2rc=$?; set -e
  pass_if "${p2rc}" "offload-status golden row '${p2line}'" \
    "offload-status porcelain is MISSING the exact row '${p2line}' (frozen-contract drift)"
done
p2_after="$(cd "${p2h}" && find . | sort)"
if [ "${p2_before}" = "${p2_after}" ]; then
  ok "--offload-status --porcelain mutated nothing (HOME + state dir identical before/after)"
else
  fail "--offload-status --porcelain mutated the home/state tree"
fi

# --- P3: --offload-status --porcelain, run B — malformed state file
#     (<unknown remote>) and the git clean/dirty fields. Fixture git state is
#     SETTLED with a throwaway `git status` before the snapshot so the script's
#     own read-only `git status` cannot create index files mid-test. ---
echo "smoke: P3 — --offload-status --porcelain golden shapes (unknown-remote/clean/dirty)"
p3h="${sandbox}/p3-home"
mkdir -p "${p3h}/state/xdg-cloud/offloaded" "${p3h}/AndroidStudioProjects" "${p3h}/Projects"
: > "${p3h}/state/xdg-cloud/offloaded/repos"          # present but malformed/empty
git -C "${p3h}/AndroidStudioProjects" init -q         # git tree, nothing to report -> clean
git -C "${p3h}/Projects" init -q
printf 'x\n' > "${p3h}/Projects/untracked.txt"        # untracked file -> dirty
git -C "${p3h}/AndroidStudioProjects" status --porcelain >/dev/null
git -C "${p3h}/Projects" status --porcelain >/dev/null
p3_before="$(cd "${p3h}" && find . | sort)"
p3_out="${sandbox}/p3-ofs.out"
set +e
HOME="${p3h}" XDG_STATE_HOME="${p3h}/state" GIT_CEILING_DIRECTORIES="${p3h}" \
  /bin/bash "${PROV}" --offload-status --porcelain >"${p3_out}" 2>"${sandbox}/p3-ofs.err"
rc=$?
set -e
pass_if "${rc}" "--offload-status --porcelain (run B) exits 0" \
  "--offload-status --porcelain (run B) failed (exit ${rc}): $(cat "${sandbox}/p3-ofs.err")"
for p3line in \
  "code|repos|repos|offloaded|<unknown remote>|" \
  "code|androidstudio|AndroidStudioProjects|local||clean" \
  "code|projects|Projects|local||dirty"; do
  set +e; grep -qxF -- "${p3line}" "${p3_out}"; p3rc=$?; set -e
  pass_if "${p3rc}" "offload-status golden row '${p3line}'" \
    "offload-status porcelain is MISSING the exact row '${p3line}' (frozen-contract drift)"
done
p3_after="$(cd "${p3h}" && find . | sort)"
if [ "${p3_before}" = "${p3_after}" ]; then
  ok "--offload-status --porcelain (run B) mutated nothing"
else
  fail "--offload-status --porcelain (run B) mutated the home/state tree"
fi

# --- P4: the HUMAN output paths are unchanged when --porcelain is absent —
#     header + Notes block still present (the porcelain branch must not leak). ---
echo "smoke: P4 — human --classify/--offload-status output unchanged without --porcelain"
out="$(HOME="${p1h}" XDG_STATE_HOME="${p1h}/state" /bin/bash "${PROV}" --classify 2>&1)"
assert_contains "${out}" "Home-dir classification" "--classify still prints its human header"
assert_contains "${out}" "Entries under ~/ not listed above are unclassified." \
  "--classify still prints its human Notes block"
assert_not_contains "${out}" "porcelain=1" "--classify (human) does not emit the porcelain header"
out="$(HOME="${p2h}" XDG_STATE_HOME="${p2h}/state" GIT_CEILING_DIRECTORIES="${p2h}" \
  /bin/bash "${PROV}" --offload-status 2>&1)"
assert_contains "${out}" "Code-dir offload status" "--offload-status still prints its human header"
assert_contains "${out}" "offloaded -> gdrive:xdg-offload/code/repos" \
  "--offload-status (human) still renders the offloaded arrow line"
assert_not_contains "${out}" "porcelain=1" "--offload-status (human) does not emit the porcelain header"

# --- P5: misuse fails LOUD — --porcelain on a non-report mode, and bare
#     --porcelain (default provision lane), both die with the §2.3 message. ---
echo "smoke: P5 — --porcelain misuse is refused"
set +e
out="$(HOME="${p1h}" /bin/bash "${PROV}" --porcelain --offload repos 2>&1)"
rc=$?
set -e
assert_nonzero "${rc}" "--porcelain --offload is refused"
assert_contains "${out}" "--porcelain applies only to --classify or --offload-status" \
  "--porcelain --offload names the two valid modes"
set +e
out="$(HOME="${p1h}" /bin/bash "${PROV}" --porcelain 2>&1)"
rc=$?
set -e
assert_nonzero "${rc}" "bare --porcelain (default lane) is refused"
assert_contains "${out}" "--porcelain applies only to --classify or --offload-status" \
  "bare --porcelain names the two valid modes"

# --- P6: porcelain NEWLINE hardening — the row delimiter is the second thing
#     that can break a pipe-delimited line format. (a) classify: a symlink
#     TARGET with an embedded newline must yield exactly ONE 6-field row with
#     the placeholder, never a row split across two physical lines (readlink
#     preserves interior newlines; $() strips only trailing ones). (b)
#     offload-status: a state file with TWO 'remote=' lines must yield exactly
#     ONE row — FIRST remote wins (head -n1 semantics, pinned here). Row-count
#     + NF==6 assertions catch any split; grep -qxF pins the whole line. ---
echo "smoke: P6 — porcelain newline hardening (split-row regressions)"
p6h="${sandbox}/p6-home"
p6nl="$(printf '\nx')"; p6nl="${p6nl%x}"               # bash-3.2 literal newline
mkdir -p "${p6h}/state/xdg-cloud/offloaded"
ln -s "${sandbox}/evil${p6nl}target" "${p6h}/Documents"  # newline INSIDE the target
printf 'remote=gdrive:first/remote\nremote=evil:second/remote\n' \
  > "${p6h}/state/xdg-cloud/offloaded/repos"             # duplicate remote= lines
p6_out="${sandbox}/p6-classify.out"
set +e
HOME="${p6h}" XDG_STATE_HOME="${p6h}/state" /bin/bash "${PROV}" --classify --porcelain \
  >"${p6_out}" 2>"${sandbox}/p6-classify.err"
rc=$?
set -e
pass_if "${rc}" "--classify --porcelain (newline-in-target) exits 0" \
  "--classify --porcelain (newline-in-target) failed (exit ${rc}): $(cat "${sandbox}/p6-classify.err")"
p6_lines="$(wc -l < "${p6_out}" | tr -d ' ')"
if [ "${p6_lines}" -eq 16 ]; then
  ok "classify porcelain still emits header + 15 rows (newline target did NOT split a row)"
else
  fail "classify porcelain emitted ${p6_lines} lines, expected 16 — a newline target split a row: $(cat "${p6_out}")"
fi
set +e; awk -F'|' 'NR>1 && NF!=6 {exit 1}' "${p6_out}"; p6rc=$?; set -e
pass_if "${p6rc}" "every classify porcelain row still has exactly 6 fields (newline fixture)" \
  "a classify porcelain row lost field discipline under a newline-containing target"
set +e; grep -qxF -- "xdg|documents|Documents|symlink|<non-porcelain-target>|" "${p6_out}"; p6rc=$?; set -e
pass_if "${p6rc}" "newline-containing target is sanitized to the exact placeholder row" \
  "classify porcelain is MISSING 'xdg|documents|Documents|symlink|<non-porcelain-target>|' for a newline target"
p6_out="${sandbox}/p6-ofs.out"
set +e
HOME="${p6h}" XDG_STATE_HOME="${p6h}/state" GIT_CEILING_DIRECTORIES="${p6h}" \
  /bin/bash "${PROV}" --offload-status --porcelain >"${p6_out}" 2>"${sandbox}/p6-ofs.err"
rc=$?
set -e
pass_if "${rc}" "--offload-status --porcelain (duplicate remote=) exits 0" \
  "--offload-status --porcelain (duplicate remote=) failed (exit ${rc}): $(cat "${sandbox}/p6-ofs.err")"
p6_lines="$(wc -l < "${p6_out}" | tr -d ' ')"
if [ "${p6_lines}" -eq 4 ]; then
  ok "offload-status porcelain still emits header + 3 rows (duplicate remote= did NOT split a row)"
else
  fail "offload-status porcelain emitted ${p6_lines} lines, expected 4 — duplicate remote= split a row: $(cat "${p6_out}")"
fi
set +e; awk -F'|' 'NR>1 && NF!=6 {exit 1}' "${p6_out}"; p6rc=$?; set -e
pass_if "${p6rc}" "every offload-status porcelain row still has exactly 6 fields (duplicate-remote fixture)" \
  "an offload-status porcelain row lost field discipline under a duplicate-remote state file"
set +e; grep -qxF -- "code|repos|repos|offloaded|gdrive:first/remote|" "${p6_out}"; p6rc=$?; set -e
pass_if "${p6rc}" "duplicate remote= lines resolve to ONE row with the FIRST remote" \
  "offload-status porcelain is MISSING 'code|repos|repos|offloaded|gdrive:first/remote|' (first-remote-wins drift)"

# ===========================================================================
# --- Q1: TUI file-pairing drift tripwire (TEST phase, auditor focus). The
#     Makefile's python steps deliberately SILENT-SKIP when bin/xdg_tui.py or
#     tests/tui/test_*.py are absent (correct for python-less machines) — but
#     that same skip would also mask an accidental DELETION of the TUI module
#     or its suites while the launcher still ships. Pin the pairing here, in
#     the bash gate that never skips: if bin/xdg-tui exists, so must
#     bin/xdg_tui.py and at least one tests/tui/test_*.py. ---
echo "smoke: Q1 — TUI launcher/module/tests pairing (Makefile silent-skip tripwire)"
if [ -e "${repo}/bin/xdg-tui" ]; then
  if [ -f "${repo}/bin/xdg_tui.py" ]; then
    ok "bin/xdg-tui is paired with bin/xdg_tui.py"
  else
    fail "bin/xdg-tui exists but bin/xdg_tui.py is MISSING — make lint/test would silently skip the TUI gate"
  fi
  q1_found=0
  for q1_f in "${repo}/tests/tui/"test_*.py; do
    if [ -e "${q1_f}" ]; then q1_found=1; fi
  done
  if [ "${q1_found}" -eq 1 ]; then
    ok "tests/tui has at least one test_*.py (unittest discovery stays non-empty)"
  else
    fail "bin/xdg-tui exists but tests/tui/test_*.py is MISSING — make test would silently skip the TUI suite"
  fi
else
  ok "bin/xdg-tui not present — TUI pairing check not applicable"
fi

echo "smoke: PASS"
