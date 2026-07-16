# Peer Review Synthesis — PR #57: repo-park / repo-restore

> Reviewed 2026-07-15 by 2 reviewers: security (adversarial), devops (bash).
> Both: **APPROVE-WITH-NITS. Zero blockers.** The concurrent auditor was skipped
> (single coder, exact lab-verified diff-spec) with the destructive `rm` covered
> here by a dedicated adversarial security review, as stated at CODE dispatch.

## The hard properties held (security-verified, could not be bypassed)

`repo-park` deletes a working tree + objects and is **sourced into interactive shells**,
so three properties are sacrosanct: never delete outside the repo toplevel, never delete
without `--apply`, never exit/kill the user's shell. The security reviewer attacked all
three and found no bypass:

- **Delete confinement** — every `rm` routes through `_repo_park_rm`'s degenerate-path
  `case` + strict `"$top"/*` confinement; targets are canonicalized (`pwd -P`) absolute
  paths. Symlink-to-HOME, trailing-slash HOME, `/`, subdir (toplevel mismatch), bare repo,
  linked worktree, submodule, empty-arg — **all refuse** (sandbox-confirmed). TEST
  independently mutation-verified the `$HOME` guard (deleting the case arm → deletes the
  fake HOME, both dry-run and apply).
- **Dry-run default** — no mutation without `--apply`; `-f` is orthogonal (proven).
- **Shell-survival** — the only `exit` is behind the executed-not-sourced guard; no
  `trap`/`set -`/`shopt`; all vars `local`; cwd/IFS untouched. Config values (remote
  names/URLs/refspecs with metacharacters) are inert data — every git call quotes its args,
  no `eval`/backtick, **no command injection**.

## Findings → resolution (remediated pre-merge, commit 4884ce0)

Both reviewers **independently** converged on the same MEDIUM:

| # | Severity | Finding | Resolution |
|---|----------|---------|------------|
| 1 | MEDIUM (both) | `_repo_park_rm`'s `*..*` guard matched `..` as a **substring** — a legit working-tree file named `a..b` / `data..backup` aborted the whole park (fail-closed, but unusable on such repos) | Pattern → `*/../*\|*/..\|../*` (traversal-**component** match; `$top` is `pwd -P`-canonical so `..` there is only ever a filename). `a..b` now parks; `../escape` still refused. Pinned by PK11. |
| 2 | MEDIUM (devops) | `xdgcloud.parked=1` marker written **before** the delete loop → a mid-delete abort stranded it, and the idempotency probe then false-reported "already parked" | All bookkeeping moved to **after** the delete loop + `git init`; marker set iff park fully completed. Pinned by PK12 + a chmod-000 mid-delete abort probe. |

## Accepted / disclosed (not fixed — documented follow-ups)

- **Remote name interpolated into `sed`/`grep -E`** in restore's branch-detection fallback
  (LOW, both): a remote named with regex metacharacters misroutes detection to `main`/`master`.
  No injection (git args quoted); only reachable when both the explicit `[branch]` arg and the
  `parkedBranch` marker are absent, and remote names are conventionally `origin`. Inherited from
  the tested alias. Follow-up.
- **Tag-only / reflog-only commits** deleted without `-f` (disclosed blind spot in the header):
  `rev-list --branches --not --remotes` covers branch commits (unpushed branches → refused), but
  tag-only/reflog-only objects aren't counted. Documented as a v1 limitation.
- **Exec-guard is bash-only** (LOW): running the file directly under zsh/dash defines functions
  and exits harmlessly; only the `/bin/bash` execution path is pinned. Note-only.
- **restore fetches only the first remote** (NIT): availability wart; all remotes are kept in
  `.git/config` so the branch is still recoverable. Follow-up.
- Narrowed restore-on-partial semantics after fix #2 (coder-flagged): a partially-parked repo
  with a still-valid HEAD is now (correctly) treated as a live repo by restore, and the abort
  message's `git checkout -f HEAD` recovery is the right one. Fail-safe.

## Conflicts

None. The two reviewers converged on the same two findings.

## Gate at review close

`make lint` clean; `make test`: smoke PASS (PK1–PK12, incl. the mutation-verified $HOME guard,
multi-refspec byte-for-byte round-trip, parked-branch, stash refusal, and the new `a..b` +
marker-ordering pins) + 87 python. Both reviewers ran the gate independently.
