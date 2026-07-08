# Peer Review Synthesis — PR #51: bulk skip-and-report evict

> Reviewed 2026-07-08 by 4 parallel reviewers: security (adversarial), test,
> devops (bash), architect. **All four: APPROVE-WITH-NITS. Zero blockers.**
> This is the highest-stakes change in the project — data destruction with the
> safety mechanism replaced (exit-code gate → parsed-stdout proven-subset).

## The hard invariant held — verified four independent ways

**No path reaches `brctl evict` without individual `uploaded` proof, and the
evict target always comes from the find-derived array, never helper stdout.**

- **Security** proved target provenance by exhaustive mutation-site sweep: `EVICT_SET+=`
  has exactly one site fed only by `EVICT_CHUNK`, which has one site fed only by
  find-derived candidates; both `brctl evict` sites draw `$c` from `EVICT_SET`.
  Walked the `${rec%%tab*}`/`${rec#*tab}` split against adversarial bytes (tab, embedded
  newline, reorder, duplicate) — all die or skip, none selects.
- **Test** independently reproduced the **6/6 mutation kill** (delete phase-2 re-gate,
  path-echo, count-match ×2, lstat guard, zero-records abort → each reds a committed test)
  and resolved the TEST-phase attribution doubt: path-echo has **three** independent kill
  sites (I4 c, I4 d red on its deletion even with the earlier I2 j2 assertion commented out).
  Confirmed every load-bearing row asserts on the **brctl-shim log** (the syscall boundary),
  not report prose.
- **Devops** hand-traced the `EVICT_CHUNK_LEN` phase-2 partition (3-chunk example) — no
  off-by-one; `base += len` runs on both branches, empty flush appends nothing, so
  `sum(len) == #EVICT_SET`. Confirmed bash-3.2 strictness on every new line.
- **Architect** confirmed the as-built matches the diff-spec §2 bodies byte-for-byte (only
  delta: a spec-sanctioned shellcheck-disable comment) and that phase-1 completes entirely
  before any evict, so the F1 count-mismatch die is always "Nothing was evicted" — no
  die-after-partial-evict sequence exists.

## Findings → resolution (remediated pre-merge, commit 28f1963)

| # | Severity | Finding (reviewers) | Resolution |
|---|----------|---------------------|------------|
| 1 | MINOR | A file whose **selection-time stat fails** (`snap=""`) was counted "proven uploaded" in the dry-run plan though apply drift-skips it — over-promises a destruction preview (security + devops, same finding) | Phase-1 classify now tallies it as `drift` and excludes it from the plan; dry-run == apply. Pinned by new I4(m)/(m2) |
| 2 | MINOR | Stale all-or-nothing safety-contract banner (maintainer hazard: a "restore" could rip out the re-gate) | Banner rewritten to the as-built proven-subset contract |
| 3 | NIT | Smoke `grep -c '^evict '` zero-match double-emit in a DATA-LOSS test | `\|\| true` idiom |
| 4 | LOW | README described the behavior change but not the **exit-code** change | Explicit exit-code callout added |
| 5 | LOW | Diff-spec said `%Sf` "may be empty" — actually prints `-` (dash) | Corrected + noted the byte-compare is symmetric either way |

## Accepted residue (documented, not fixed)

- **TOCTOU intermediate-directory symlink swap** (security MINOR): the re-confine `case`
  guards `$c` corruption, not a parent-dir symlink swap in the phase-2→evict window. Requires
  a same-user attacker (who can destroy data directly) staging a metadata-identical decoy
  (`touch -r` replicates ns-mtime). Narrowed by phase-2 rc==0 seconds earlier + ns-mtime
  compare; covered by the consent gate. True fix is the verb-taking helper
  (`evictUbiquitousItem`) — recorded as future work. Now documented in the diff-spec.
- **Terminal escape sequences** in attacker-named files echoed to the report (security NIT):
  display-only, never parsed, consistent with every pre-existing status lane — whole-repo
  concern, out of scope.
- **phase-2 structural helper failure** shows the drift message (security NIT): fail-closed
  (chunk skipped); worst case one confusing "re-run" message, and phase 1 dies on the same
  condition next run.
- **Untested fail-closed drift sub-branches** + report ordering (test LOW): all pure
  skip/display paths that can only under-evict, never destroy.
- **Sibling `\|\| printf 0` double-emit** at 7 other smoke sites (devops LOW): same latent nit,
  out of this PR's scope — follow-up sweep.

## Conflicts

None. Security and devops independently landed on the same selection-stat-fail finding; the
other findings were disjoint. The one design-level question (architect #3: die blast radius
under chunking) resolved to "correct as-built" on inspection — phases are sequential across
the whole set, so a deficit never dies after a partial eviction.

## Environment note

The devops reviewer hit host ENOSPC during mutation runs — **the machine is at 93% disk
(~990Mi free)**. Ironic for this toolkit; not a code issue, but worth the user's attention
(the offload / reclaim / evict lanes exist precisely for this).

## Gate at review close

`make lint` clean; `make helper` recompiles clean; `make test`: smoke PASS (686 assertions
incl. I4 + the new selection-stat-fail rows) + 87 python tests. Mutation merge gate 6/6.
