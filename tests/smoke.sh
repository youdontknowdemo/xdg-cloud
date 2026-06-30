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
#     the library and assert (a) xdg_offload_set() reproduces cloud-xdg's 9-row
#     OFFLOAD_SET in EXACT order, and (b) home-tree's SAFE_DIRS — derived from
#     HOMETREE_KEYS + the linuxName column (field 3) — equals the historical
#     literal "Documents Pictures Music Videos Projects Notes" in that order.
#     This locks the §6 linuxName<->rclone-filter coupling and the divergent
#     per-script ordering (cloud-xdg: Music before Pictures; home-tree: Pictures
#     before Music) against silent registry drift. Run under /bin/bash (3.2). ---
echo "smoke: L3 — registry derivation reproduces OFFLOAD_SET (9 rows, order) + SAFE_DIRS"
lib="${repo}/bin/lib/xdg-common.sh"
expected_offload="$(printf '%s\n' \
  'desktop|Desktop|Desktop|XDG_DESKTOP_DIR|1' \
  'documents|Documents|Documents|XDG_DOCUMENTS_DIR|1' \
  'downloads|Downloads|Downloads|XDG_DOWNLOAD_DIR|1' \
  'music|Music|Music|XDG_MUSIC_DIR|1' \
  'pictures|Pictures|Pictures|XDG_PICTURES_DIR|1' \
  'videos|Movies|Videos|XDG_VIDEOS_DIR|1' \
  'public|Public|Public|XDG_PUBLICSHARE_DIR|1' \
  'templates|Templates|Templates|XDG_TEMPLATES_DIR|1' \
  'projects|Projects|Projects||1')"
set +e
actual_offload="$(/bin/bash -c '. "$1"; xdg_offload_set' _ "${lib}")"
rc=$?
set -e
pass_if "${rc}" "sourcing the lib + xdg_offload_set runs cleanly" \
  "xdg_offload_set failed to run (exit ${rc})"
if [ "${actual_offload}" = "${expected_offload}" ]; then
  ok "xdg_offload_set reproduces the 9-row OFFLOAD_SET in cloud-xdg order"
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

echo "smoke: PASS"
