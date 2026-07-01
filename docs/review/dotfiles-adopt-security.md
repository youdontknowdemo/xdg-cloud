# Security Review — dotfiles-adopt (PR #27)

**Reviewer:** pact-security-engineer (adversarial)
**Scope:** `cmd_dotfiles_adopt` + `dotfiles_path_is_managed`, `bin/cloud-xdg-provision.sh`
**Branch:** `feature/dotfiles-adopt`
**Threat model:** User runs `--dotfiles-remote <url> --apply` against an **untrusted/malicious**
dotfiles repo. Attacker fully controls tracked paths, tracked content, and repo config.
**Method:** Empirical — built fixture bare repos with crafted tree objects (`git mktree` accepts
`..`/`.` tree entries) and replicated the exact aside `mv` loop and `git checkout --work-tree=$HOME`
against a sandbox `$HOME`. All claims below were reproduced on the review machine unless noted.

---

## SECURITY REVIEW SUMMARY
- **Blocking: 1**
- **Minor: 2**
- **Future: 2**
- **Overall assessment: FAIL** (one work-tree escape must be fixed before merge)

The design's core invariant — *"never clobber a user file; on failure `$HOME` is UNTOUCHED"* — is
**violated for a malicious remote**: the collision-aside step operates on files **outside `$HOME`**
using attacker-controlled path strings, and it runs *before* the checkout that would otherwise fail.

---

## FINDING 1 — BLOCKING: Work-tree escape via aside `mv` on attacker-controlled `../` path
**Location:** `bin/cloud-xdg-provision.sh:1607-1620` (PASS B aside loop), enabled by
`dotfiles_path_is_managed` top-component-only check at `:1513`.

**Issue.** The tracked-path list comes straight from the attacker's repo
(`dotfiles_git ls-tree -r --name-only HEAD`, `:1582`). A malicious repo can ship a tracked path
containing `..` (git's own `git add`/`update-index` reject `..`, but a hand-built tree via
`git mktree`/`fast-import` does not — **verified**: a bare clone enumerates `../evil` verbatim).
The aside loop then does, with no confinement:

```sh
abs="$HOME/$p"                       # p="../evil"  =>  abs="$HOME/../evil"  (OUTSIDE $HOME)
if [ -e "$abs" ] || [ -L "$abs" ]; then
  ...
  mkdir -p "$(dirname "$abs")"
  mv "$abs" "$bak"                   # renames a file that lives OUTSIDE the work-tree
fi
```

**Why the guards don't catch it.** PASS A (`:1588-1601`) calls `dotfiles_path_is_managed`, which
inspects only the **top** path component: `top="${rel%%/*}"`. For `../evil`, `top=".."`, which
matches no managed lane, so PASS A does **not** die — the path sails through to PASS B.

**Attack vector (verified).**
1. Attacker publishes a repo whose HEAD tree contains `../evil` (or `../../<path>`, `../<sibling>/…`).
2. Victim runs `--dotfiles-remote <url> --apply`.
3. PASS A: `../evil` not flagged (top=`..`). PASS B: `abs="$HOME/../evil"`; if that path exists,
   `mv` **relocates it outside `$HOME`** to `…/evil.pre-dotfiles-<stamp>`.
   Empirical result: a file planted at `$HOME/../evil` was renamed outside the sandbox work-tree —
   **`*** ASIDE ESCAPE CONFIRMED ***`**.
4. `git checkout` later rejects `../evil` (`error: invalid path`) and adopt dies — **but the aside
   already fired**, so the destructive out-of-tree `mv` persists (asides are intentionally retained).

**Impact / honest severity framing.** This is a **relocation / integrity-DoS** primitive, not
arbitrary-content-write-outside-`$HOME` (git's checkout confinement blocks writing `../` content —
see "What git already blocks"). Blast radius is bounded by the invoking user's own permissions
(`guard_not_root` refuses root, `:1651`/`1034`). Reachable targets: any existing file the user can
rename via a relative path above `$HOME` — e.g. on macOS `../Shared/…` (`/Users/Shared`, commonly
writable), sibling-user assets on a shared box, or anything the user owns above `$HOME`. A malicious
repo can silently move/break such files (SSH material, other tooling state) while *appearing* to
merely "fail to adopt." It directly violates the feature's advertised "`$HOME` UNTOUCHED on failure"
guarantee.

**Why Blocking (not Minor):** (a) fully attacker-controlled input reaches a destructive filesystem
op **outside the work-tree**; (b) it breaks a load-bearing, explicitly-advertised safety invariant;
(c) the sibling lane already demonstrates the correct guard, so the fix is trivial and low-risk.

**Recommended fix (report-only — do not implement here).** Reject unsafe tracked paths in PASS A
(the same loop that already scans every path, so `$HOME` stays fully untouched on refusal). Treat a
tracked path as hostile if it is absolute, equals `..`, or contains a `..` component or a leading
`./`/`.` component. Minimal shell check per path `$p`:

```sh
case "/$p/" in
  */../*|/./*|//*) die "refusing tracked path '$p' — path traversal / non-confined";;
esac
```

Additionally (defense in depth) confine each aside target the way `dotfiles_guard_path` (`:1418`)
already does for `--dotfiles-track`:
`case "$abs" in "$HOME"/*) : ;; *) die "…outside \$HOME" ;;` — but note a bare `case "$abs"` on the
*unresolved* string still matches `$HOME/../evil` (it literally begins with `$HOME/`); confinement
must be on the **realpath**, or better, reject `..` lexically as above **before** forming `abs`.
The lexical reject is the primary fix; realpath-confinement is the backstop.

**Note the asymmetry that caused this:** `--dotfiles-track` → `dotfiles_guard_path` (`:1417-1419`)
DOES confine to `$HOME`. `cmd_dotfiles_adopt`'s aside loop does not. Adopt is the *higher-risk* lane
(it ingests a whole foreign repo) yet has the *weaker* guard.

---

## FINDING 2 — MINOR: Managed-lane guard bypass via case-variant path (macOS case-insensitive FS)
**Location:** `dotfiles_path_is_managed` `:1518/:1523/:1528` — `[ "$top" = "$nm" ]` is a
**case-sensitive** shell string compare.

**Issue.** On a case-insensitive volume (the macOS default boot volume, where `$HOME` lives),
`documents` and `Documents` name the **same** directory, but the guard's compare is case-sensitive.
A tracked path `documents/evil` yields `top="documents"`, which `!=` the managed lane name
`Documents`, so PASS A does not flag it — yet the FS resolves it into the real managed `Documents`
lane. Unlike `../` and `./` (both rejected by `git checkout` — verified `error: invalid path`),
`documents/evil` is a lexically valid path git will happily check out.

**Attack vector.** Malicious repo tracks `documents/evil` (or `.SSH/…`, `desktop/…`, any
case-variant of a managed lane). PASS A misses it; PASS B asides the user's real `Documents` file
(case-insensitive match); checkout plants attacker content into the managed lane — defeating the
guard whose entire job is "refuse repos that fight the managed lanes."

**Verification caveat (empirical honesty).** The review machine's `/var/folders` temp volume turned
out to be **case-sensitive**, so `documents/` and `Documents/` materialized as *distinct* dirs and
the collision did not reproduce there. The guard's case-sensitive operator is confirmed by code
(`:1518`); the FS-fold behavior is the standard macOS default-volume property. Severity kept at
**Minor**: confined to `$HOME` (no escape), FS-dependent, and requires the case-variant to also be a
real managed lane.

**Recommended fix.** Normalize case before compare on case-insensitive platforms (lowercase both
`top` and `nm`), or canonicalize the target and re-test membership. Report-only.

---

## FINDING 3 — MINOR: `dotfiles_path_is_managed` is top-component-only (guard is shallow)
**Location:** `:1513` `top="${rel%%/*}"`.

**Issue.** The managed-lane guard reasons only about the first component. This is the enabling
weakness behind Finding 1 (`..` top) and is fragile for any future lane logic that needs to reason
about nested targets. It is not independently exploitable for a *write* (git checkout rejects `..`
and `.` components), so it is Minor on its own — but it is the shared root cause. The Finding-1 fix
(lexical `..`/absolute reject) closes the exploitable portion; hardening the guard to reason about
the resolved path would make it robust rather than incidentally-safe.

**Recommended fix.** Pair the name-based check with a realpath-confinement check
(`abs` must resolve under `$HOME` and not be `.dotfiles`), mirroring `dotfiles_guard_path`.

---

## FINDING 4 — FUTURE: Aside uniquifier is TOCTOU-racy; `mv` overwrites
**Location:** `:1611-1614`.

**Issue.** `while [ -e "$bak" ] || [ -L "$bak" ]; do …; done` picks a free `.pre-dotfiles-<stamp>[.n]`
name, then `mv "$abs" "$bak"`. Between the existence check and the `mv`, a **local** attacker sharing
write access to the target directory could create `$bak`; `mv` (no `-n`) then overwrites it. The
stamp is `date +%Y%m%d-%H%M%S` (second-granularity, predictable). Outside the malicious-repo threat
model (needs a local co-attacker), hence **Future**, but worth `mv -n` / `O_EXCL`-style creation or a
mkstemp-based unique name.

---

## FINDING 5 — FUTURE: clone relies on git's default protocol allow-list
**Location:** `:1555` (dry-run) / `:1574` (apply) — `git clone --bare "$url"`.

**Assessment (mostly reassuring).**
- **No shell injection:** `$url` is passed as a single argv element to `git clone`; it is never
  `eval`'d or word-split into a shell. Verified by code.
- **`ext::` transport blocked:** `git clone --bare "ext::sh -c '…'"` returned
  `fatal: transport 'ext' not allowed` on default config — **verified** (no command execution).
- **Residual:** the script does not *explicitly* pin `protocol.allow` / `GIT_ALLOW_PROTOCOL`, so it
  inherits git's defaults. Those defaults are safe today; a hardened deployment could set
  `-c protocol.ext.allow=never -c protocol.allow=never` (allowing only https/ssh/file) to be
  version-independent. **Future** hardening, not a current vuln.

---

## Vectors checked and found SAFE (with the mechanism that protects them)
- **`git checkout --work-tree` writing `../` content outside `$HOME`** — **blocked by git**:
  `error: invalid path '../evil'`, checkout aborts atomically (work-tree left empty; `.bashrc` not
  written either). Verified.
- **`./`-leading path write** (`./Documents/evil`) — **blocked by git**: `error: invalid path`. Verified.
- **Symlink-parent write-through** (tracked symlink `sub`→outside + tracked `sub/file`) — **blocked
  by git**: `You have both sub and sub/file` / `D sub`, nothing written to the symlink target.
  Verified.
- **Hook / code execution on bare clone + checkout** — **safe**: `git clone --bare` provisions only
  `*.sample` hooks; remote hooks are not repo content and are not transferred; `core.hooksPath` is
  local config, not cloned (verified none set). Additionally, any tracked path under `.dotfiles/…`
  (which would write into the live git-dir/hooks, since git-dir=`$HOME/.dotfiles`) is caught by
  PASS A's explicit `[ "$top" = ".dotfiles" ] && return 0` (`:1514`). Verified by logic + tree test.
- **`*.pre-dotfiles-<stamp>` naming abuse** — **safe against overwrite**: the `while [ -e "$bak" ]`
  uniquifier appends `.n` rather than clobbering an existing aside (the race in Finding 4 is a
  separate, local-only concern).
- **`--dotfiles-track` lane** — **not in scope but noted as the correct pattern**: it confines with
  `case "$abs" in "$HOME"/*) : ;; *) die` (`:1418`), which adopt should mirror.

---

## Bottom line for the lead
One **BLOCKING** work-tree escape (Finding 1): a malicious remote's `../`-tracked path drives a
destructive `mv` outside `$HOME` through the aside loop, because the managed-lane guard only checks
the top path component and the aside loop has none of the `$HOME`-confinement that the sibling
`--dotfiles-track` lane already uses. Fix is a lexical reject of `..`/absolute/`.`-leading tracked
paths inside PASS A (before any mutation), optionally backed by realpath-confinement of each aside
target. Everything git itself mediates (content-write escape, symlink parent, `.`-paths, ext::,
hooks) is already safe. **Do NOT merge until Finding 1 is fixed.** Reported, not fixed, per role.

---

# VERIFY-ONLY RE-REVIEW (Task #74) — fix for Finding 1 (devops-coder Task #73, staged)

**Method:** read the staged diff (`git diff --cached`), re-ran the original `../evil` exploit and new
edge cases against the fixed logic in throwaway sandboxes.

## VERDICT: PASS — the Blocking work-tree escape (Finding 1) is CLOSED. No new issue introduced.

### Evidence
1. **Primary escape CLOSED.** New `dotfiles_path_is_unsafe()` rejects `/*|..|../*|./*|*/../*|*/..`.
   Re-ran the crafted `../evil` bare repo: PASS A now accumulates it as unsafe and **dies before any
   aside/mv** (scan reads the NUL tempfile in the parent shell, then `rm -rf` the clone). The planted
   `$HOME/../evil` was **intact, not relocated** — previously "ASIDE ESCAPE CONFIRMED", now closed.
2. **Glob set complete.** Battery of traversal forms (`..`, `../x`, `a/../b`, `a/b/..`, `/etc/x`,
   `a/../../b`, `a/..//b`, `..//x`) all REFUSED; innocent names that merely *contain* dots
   (`..evil`, `evil..`, `a..b`, `sub/..hidden`, `x/.../y`) correctly ALLOWED — a `..` only traverses
   when it is a whole component bounded by `/` or string ends, which the four `..` patterns cover.
   `.` and `a/.` are allowed but harmless (resolve within `$HOME`; `git ls-tree -r` cannot emit a `.`
   file entry and `git checkout` rejects a `.` component anyway).
3. **PASS A is fail-closed before mutation.** Full-list accumulate-then-die; unsafe + managed scanned
   together; on any offender it `rm -f tracked_file; rm -rf $DOTFILES_DIR` and dies — no `mv` reachable.
4. **realpath backstop catches the symlinked-intermediate escape** the lexical check can't see.
   For an innocent `link/evil` where `$HOME/link` is a symlink to outside `$HOME`, PASS B computes
   `parent_real="$(cd "$(dirname "$abs")" && pwd -P)"` and dies because it is not `$home_real[/*]`,
   **before mv** — verified the outside file stayed intact. Both `home_real` and `parent_real` use
   `pwd -P`, so macOS `/var`→`/private/var` canonicalization matches on both sides (no false miss).
   (A symlink that is itself the *final* component is moved as the LINK, staying in `$HOME` — safe.)
5. **NUL enumeration prevents missed colliders.** `ls-tree -r -z --name-only` + `read -r -d ''` +
   tempfile preserves raw bytes; the old `--name-only` C-quotes non-ASCII names
   (`"sub/caf\303\251.txt"`) which would fail `[ -e "$HOME/$p" ]` and silently skip the aside.
   Verified `-z` yields the true path; count correct.
6. **Case-fold managed bypass CLOSED (old Finding 2).** `_dotfiles_lc` (tr-based, bash-3.2-safe)
   lowercases both sides; `documents`, `DOCUMENTS`, `DocuMents` all now REFUSE against `Documents`.

### No new issues
- `tracked_file` (mktemp) is removed on every exit path (PASS A die, PASS B backstop die, normal).
- Dry-run gained the same unsafe check → preview parity with apply.
- New RC-wiring guard (skip sentinel append when the adopted repo tracks `$RC_TARGET`) avoids
  dirtying a tracked rc; no security impact.
- SC2094 suppressions are cosmetic and correct (write fully completes before the reads).

### Residual (unchanged, NOT gate blockers — previously filed)
- Finding 4 (aside uniquifier TOCTOU) and Finding 5 (rely on git default protocol allow-list) remain
  **Future**; both require a local co-attacker / are covered by safe git defaults. The backstop's own
  resolve-then-mv is the same class of local race — out of the malicious-repo threat model. Not
  required for merge.

**Merge gate:** the Blocking finding is resolved. Cleared from a security standpoint.
