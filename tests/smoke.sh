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
# managed-repo dry-run names the WOULD-REFUSE offender.
set +e; out="$(adrun "${d20h}" --dotfiles-remote "${adopt_msrc}" 2>&1)"; set -e
assert_contains "${out}" "WOULD REFUSE" "dry-run flags a managed offender as WOULD REFUSE"

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

echo "smoke: PASS"
