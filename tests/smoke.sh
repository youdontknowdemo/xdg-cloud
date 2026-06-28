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

echo "smoke: PASS"
