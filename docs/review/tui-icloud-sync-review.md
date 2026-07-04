# Peer Review Synthesis — PR #45: TUI iCloud sync

> Reviewed 2026-07-04 by 4 parallel reviewers: architect, test-engineer,
> devops (bash), security. Security returned **REQUEST-CHANGES** on a real
> command-injection sink; after remediation (commit 2e53198) the same reviewer
> re-reviewed and returned **APPROVE**. Final state: all four clear.

## The blocking finding (resolved before merge)

**[MAJOR → resolved] Arithmetic-eval command injection via `ICLOUD_DL_MARGIN_BYTES`.**
The margin env var flowed unvalidated into `$(( bytes_need + ICLOUD_DL_MARGIN_BYTES ))`.
bash re-evaluates a variable's *value* as an arithmetic expression, so an
array-subscript-with-command-substitution executed at eval time — the security
reviewer verified `ICLOUD_DL_MARGIN_BYTES='bytes_need[$(touch /tmp/PWNED; echo 0)]'`
created the file. Under the tool's stated env-trust model this didn't expand the
trust boundary (`$ICLOUD_HELPER` is already exec'd directly), but it was a latent
injection sink inconsistent with the digits-only guards five lines away.

**Fix (2e53198)**: a load-time, mode-independent, fail-closed digits-only guard
(`case … ''|*[!0-9]*) die`) placed after the `:=` default and before every consumer.
Re-review confirmed: runs on every invocation (verified it dies even on `--classify`),
full bypass matrix holds (leading `±`, whitespace, hex, unicode digits, backticks all
die), original exploit no longer creates its sentinel. Two residual NITs (octal `010`,
64-bit overflow on a ~19-digit self-supplied value) carry no injection/trust-boundary
risk — noted, not fixed.

## Also remediated pre-merge

| Finding | Reviewer | Resolution |
|---------|----------|------------|
| [MAJOR] Free-space gate's `bytes_need` term unpinned — a regression to `avail < margin` survived the suite (only margin extremes were tested) | test | Controlled-df boundary subtest (avail = need+margin∓1); mutation-verified killing the drop-`bytes_need` and `-lt`→`-le` mutants |
| [MINOR] Download-loop `brctl` inherits the file-list stdin (same class as the helper fix) | devops, architect | `< /dev/null` on the loop's `brctl download` |
| [MINOR] Spec §2.3 didn't reflect the as-built `< /dev/null` helper sever | architect | Diff-spec reconciled (227de63) with an as-built note covering the margin guard + both stdin severs |

## Agreements (what the panel verified clean)

- **Resolve-then-confine is correct on both sides** — root and target each canonicalized
  before the prefix compare; the devops reviewer's hands-on probes (trailing slashes,
  symlinked-parent files both directions, root==target) all held; escape-matrix cases
  (b) lexically-in-resolves-out and (g) symlinked-root are each mutation-verified to kill
  their named regression.
- **Evict byte-untouched** — proven by function-body hash, not prose.
- **ICLOUD_ROOT override cannot cause destruction outside CloudDocs** — download is
  dataless-only (no-op elsewhere), evict requires per-file uploaded-confirmation
  (fail-closed elsewhere); fail-closed preserved on empty/unresolvable root.
- **Wrap-don't-bypass intact** — all policy (confinement, gate, dataless filter) in bash;
  the TUI diff is exactly one ACTIONS row + two ops_for_entry edits; no consent/interrupt/
  porcelain/executor changes.
- **Degrade-vs-die posture consistent** — sync-status warns and returns 0 on helper/brctl/df
  trouble; download dies fail-closed. rc taxonomy (0/1) matches PR #43's interpret_result.

## Deferred (accepted, non-blocking)

- Newline-in-filename desyncs the sync-status size order-join (read-only report accuracy
  only; counts stay fail-closed via the deficit add). Shared repo idiom; a NUL-delimited
  sweep is the real fix — backlog.
- Chunk-cap env seam (`ICLOUD_CHUNK_MAX_BYTES/_ARGS`) would let a small-fixture test drive
  the mid-walk-flush path directly (the stdin sever is currently proven by ruling + the
  helper being argv-only, not by a triggered-flush test) — backlog.
- Octal/overflow margin quirks (security NITs); `df` column heuristic vs a `%`-terminated
  mount name (needs mount privilege); `icloud_fmt_bytes` awk double precision > 2^53.
- `brctl status` caught-up token verified on macOS 15.7.8 only — health is advisory.

## Conflicts

None. The devops and architect reviewers independently flagged the download-loop stdin
consistency gap; test and security independently converged on the gate/margin surface.

## Gate at review close

`make lint` clean; `make test`: smoke PASS (562 assertions incl. I3 boundary + injection
subtests) + 87 python tests OK. Original injection exploit re-run: dies, no sentinel.
