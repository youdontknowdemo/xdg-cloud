# DevOps / Shell Review — cloud-xdg-provision

**Reviewer:** pact-devops-engineer
**Task:** #6
**Scope:** `bin/cloud-xdg-provision.sh`, `bin/home-tree.sh`, `Makefile`, `hooks/pre-commit`, `.shellcheckrc`
**Working dir:** `/Users/administrator/repos/xdg-cloud`
**Method:** static audit + shellcheck (0.11.0) + sandboxed dry-run/apply/relocate/idempotency execution.
**Review host bash:** 5.3.15 (real bash 3.2 unavailable — 3.2 claims verified by construct-audit, not execution).

---

## Verdict

**No BLOCKING issues.** This is unusually clean shell. The destructive paths are
safe-by-default, idempotent, and ordered correctly. Findings below are MINOR
(should-fix, none gate the PR) and FUTURE (nice-to-have / document). I deliberately
tried to break the relocate sequence, the quoting under spaces, the dangling-symlink
path, and the bash 3.2 claim — all held.

---

## Verified strengths (adversarial tests that passed)

| Claim under test | Result |
|---|---|
| **Bash 3.2 compatibility** | HOLDS. No assoc arrays / `mapfile` / `<()` / `[[ ]]` / `${v^}` / `$'...'` / namerefs. `home-tree.sh` uses only indexed arrays + `+=()` append — both bash 3.1+, hence 3.2-safe. `cloud-xdg-provision.sh` uses zero arrays. Capitalization is done with `tr` (lines 153-156) precisely to avoid the bash-4 `${1^}`. |
| **shellcheck enable=all** | Clean (exit 0) with repo config. Without the disables: 229 findings, **all** exactly the 5 documented codes (SC2250/2292/2312/2310/2249), **all info/style severity, zero error/warning**. The `.shellcheckrc` disables are honest — they hide style noise, not bugs. |
| **DRY_RUN safety** | Default dry-run created **0** filesystem entries (verified). Destructive ops double-gated: `--apply` AND (`--relocate`/`--sync`). |
| **Idempotency** | Second `--apply` → 8 `ok:` lines, exit 0, symlinks unchanged. |
| **Spaces in `$CLOUD_ROOT`** | Default macOS path is `…/My Drive` (has a space). Apply created correct symlinks; every expansion that touches the path is quoted. Verified end-to-end. |
| **`relocate_dir` failure safety** | Ordering is copy → move-aside → symlink (cloud-xdg:253-257) — the correct safe order. Injected a read-only cloud dst: `set -e` aborted mid-run, **original data survived intact**, dotfiles copied (`rsync -a`). |
| **Dangling-symlink `set -e` trap** | The documented hazard (cloud-xdg:216-224) works: a dangling local symlink is left untouched, run exits 0 instead of aborting on `ln -s`'s "File exists". |
| **`local`-masking gotcha avoided** | `redirect_one` declares `local …` then assigns on a separate statement (cloud-xdg:196-199), so a failing `field()` is NOT masked by `local`'s exit code. Correct. |
| **pre-commit fail-loud** | Missing shellcheck → exit 1 (no silent pass). `exec make lint` propagates shellcheck's non-zero → commit blocked. |
| **`make test` smoke suite** | PASS (exit 0). |

---

## MINOR (should fix — non-blocking)

### M1 — `make install` is broken inside a git worktree
`Makefile:20` guards with `test -d .git`, and `Makefile:22` does
`ln -sf ../../hooks/pre-commit .git/hooks/pre-commit`. In a **git worktree** (which
this project's own PACT workflow uses), `.git` is a *file*, not a directory, so:
- `test -d .git` → false → install aborts with the misleading message "requires a git repo".
- even if bypassed, hooks for a worktree live under the main repo's commondir, not `.git/hooks/`.

Impact: anyone running `make install` from a worktree or submodule checkout cannot
wire the hook. Fix: detect both file and dir (`test -e .git`) and resolve the hooks
path via `git rev-parse --git-path hooks` instead of hardcoding `.git/hooks`.

### M2 — Dry-run output is not copy-paste-safe for paths with spaces
`run()` prints the command via `"$*"` unquoted (cloud-xdg:85-86; home-tree:56-61).
The **default** macOS cloud root `…/My Drive` contains a space, so a dry-run line
renders as `ln -s …/My Drive/documents …` — a user who copies that line to run it
manually gets word-split breakage. The actual execution path uses `"$@"` and is
correct; only the *displayed* command is misleading. Fix: display with `printf '%q '`
per arg (bash 3.2-safe) so the echoed command is faithful.

### M3 — `make install` silently clobbers an existing pre-commit hook
`ln -sf … .git/hooks/pre-commit` (Makefile:22) replaces any pre-existing
`.git/hooks/pre-commit` (a real hook, or a chained multiplexer) with no backup or
warning. Fix: if the target exists and is not already our symlink, warn / back it up.

### M4 — Multiple Google Drive mounts → silent first-match
`cloud-xdg:141-143` and `home-tree:123-125` glob `…/CloudStorage/GoogleDrive-*` and
take the **first** match with a `My Drive`. With two Google accounts mounted, the
script silently picks one. Fix: if the glob matches >1, warn and require `--cloud-root`.

### M5 — Predictable filter filename in shared tmp (defer detail to security)
`home-tree:48` `FILTER_FILE="${TMPDIR:-/tmp}/home-tree.rclone-filter"` is a fixed
name written with `cat > "$FILTER_FILE"` (home-tree:156), which follows a pre-existing
symlink. On a multi-user box with a shared `/tmp`, this is a minor symlink-clobber /
predictable-path surface. Low severity (sticky-bit `/tmp`, content is non-secret), but
flagging for **security-engineer** to weigh — consider `mktemp` for the filter file.

---

## FUTURE (optional / document)

- **F1 — `field()` subprocess fan-out** (cloud-xdg:170): `printf | cut` spawns 2
  processes per field; `redirect_one` calls it 5×/line. Trivial at 9 entries; would
  matter only if `OFFLOAD_SET` grows large. A single `IFS='|' read` per line would
  remove it (and stays 3.2-safe).
- **F2 — pre-commit lints all tracked scripts, not staged content** (hooks/pre-commit:9):
  `make lint` runs shellcheck over the working tree globs, not the staged index. It can
  block on a pre-existing issue in an untouched file, or pass staged content that
  differs from the working tree. Acceptable for a small repo; document the intent.
- **F3 — hook gates lint only, not `make test`** (hooks/pre-commit): smoke/idempotency
  tests are not run pre-commit (a speed choice). Worth one line in CONTRIBUTING so it's
  a known boundary, not a gap.
- **F4 — `mkdir -p` over a pre-existing *dangling* symlink is platform-divergent**
  (home-tree:143-145): macOS `mkdir -p` on a dangling symlink emits a stderr error but
  exits 0; GNU coreutils creates the target through the link. Only reachable if a user
  layers `home-tree.sh` on a HOME already provisioned by `cloud-xdg-provision.sh` (two
  distinct strategies). Normal standalone runs of each are clean (verified). Note the
  scripts are alternatives, not meant to be combined.
- **F5 — dry-run still `die`s on macOS without a Drive mount** (cloud-xdg:144): you
  can't preview the plan without either a real mount or `--cloud-root`. Consider letting
  dry-run proceed with a placeholder so users can see the mapping before mounting.
- **F6 — `--max-delete N` not validated numeric** (home-tree:96,210,225): a non-numeric
  value is passed straight to rclone, which errors later with a less obvious message.
  A guard would fail faster with a clearer message.
- **F7 — `VERSION := $(shell cat VERSION)`** (Makefile:5) runs on *every* invocation
  including `lint`/`test`; harmless, but emits a `cat` error to stderr if `VERSION` is
  missing even when the target doesn't need it. Make it lazy (`=`) or scope it to the
  `version` target.

---

## set -euo pipefail interaction audit (requested focus)

- **`run()` does NOT swallow exit codes** (cloud-xdg:84-87; home-tree:55-62): in apply
  mode `"$@"` is the final command, so `run`'s status == the command's status; `set -e`
  fires on failure as intended.
- **Piped `while IFS= read` loops** (cloud-xdg:187,270,319): the loop body runs in a
  subshell (RHS of pipe); `set -e` is inherited and `pipefail` propagates a body failure
  back to the pipeline, so a failing `redirect_one`/`mkdir` correctly aborts `main`. No
  silent errexit suppression. Note the standard side effect — variables set in the loop
  don't escape — which the code does not rely on.
- **`[ -z "$line" ] && continue`** (multiple): safe under `set -e` — the failing `&&`
  list is not the "final command after the last &&", so errexit does not trigger.
- **`if mount="$(find_macos_drive_mount)"`** (home-tree:278): function-in-condition
  deliberately disables errexit for that call and handles the non-zero branch; the
  SC2310 disable in `.shellcheckrc` is justified for exactly this.

---

## shellcheck raw findings (for the record)

```
$ shellcheck bin/*.sh hooks/pre-commit tests/*.sh        # with repo .shellcheckrc
EXIT 0   (no findings)

$ shellcheck --enable=all --norc bin/*.sh hooks/pre-commit tests/*.sh
EXIT 1   229 findings — ALL of:
   167  SC2250 (style)  prefer ${braces}
    43  SC2292 (style)  prefer [[ ]] over [ ]   ← scripts intentionally target [ ]
    18  SC2312 (info)   invoke separately to avoid masking return value
     2  SC2310 (info)   function in condition disables set -e (handled deliberately)
     2  SC2249 (style)  case without default branch
   → 0 error, 0 warning. The 5 disabled codes == the 5 documented in .shellcheckrc.
```

---

## Recommendation

Approve from the shell/DevOps angle. M1 (worktree `make install`) is the most
worthwhile fix because this project's own workflow uses worktrees; M2 is a small,
high-value correctness fix for the dry-run UX given spaces are the default path.
Everything else is polish.
