# Shell-Implementation Review — dotfiles ADOPT (PR #27, `feature/dotfiles-adopt`)

**Reviewer:** devops (adversarial peer pass on own code) · **Scope:** `git diff main...feature/dotfiles-adopt`
bash-3.2 correctness, collision-enumeration robustness, error/cleanup completeness, mktemp portability,
shellcheck. Severity: **Blocking** / **Minor** / **Future**.

---

## Summary

The clobber-safety core is sound: two-pass (managed pre-scan dies before any aside), **no `-f`/`--force`
on checkout** (grep-verified), aside-before-checkout with the #5b uniquifier (`-e`||`-L`, never overwrites
an aside), symlink colliders move the LINK, refuse-clobber + resolve-rc-before-mutation + clone-fail-cleanup
all correct. **No data-loss path found** — the no-force checkout is a true backstop.

One real robustness finding (M1) in the collision enumeration, plus two minors. None is a clobber/data-loss.

---

## M1 — [Minor, robustness; borderline Blocking-for-completeness] `ls-tree --name-only` C-quotes exotic filenames → pre-aside misses the collider

**Where:** `cmd_dotfiles_adopt` (and the dry-run preview): `tracked="$(dotfiles_git ls-tree -r --name-only HEAD …)"`
then `while IFS= read -r p`.

**Problem:** `git ls-tree -r --name-only` **C-quotes** any path containing non-ASCII bytes, control chars,
a double-quote, or a backslash — wrapping it in `"…"` with octal/backslash escapes. Verified:

```
$ git ls-tree -r --name-only HEAD
a normal.txt              # spaces are NOT quoted — handled fine
"caf\303\251.txt"         # café.txt  → C-quoted
"has\"quote.txt"          # has"quote.txt → C-quoted
```

My loop reads the literal quoted string, so `$HOME/$p` becomes `$HOME/"caf\303\251.txt"` — a path that does
not exist. Consequence for a repo tracking such a file **that also exists locally**:
- PASS B pre-aside checks the wrong path → **asides nothing**.
- checkout (no `--force`) then targets the *real* `café.txt`, sees the local one → **refuses** → adopt dies
  `"adopt incomplete … asides retained"`.

**Verified end-to-end:** local `café.txt`=`LOCAL-KEEP` + remote `café.txt` → adopt exits 1, **local file NOT
clobbered** (still `LOCAL-KEEP`), no aside made. So: **NO data loss** (no-force is the backstop), but the
"pre-aside makes checkout always succeed cleanly" guarantee breaks for exotic-named colliders, and the dry-run
preview prints the wrong (quoted) path. A literal-newline filename is C-quoted too (so it won't split the
read into two paths — but it's still mis-parsed).

**Fix (low-cost, robust):** enumerate NUL-delimited and read with a NUL delimiter — no C-quoting at all:
```sh
tracked="$(dotfiles_git ls-tree -r -z --name-only HEAD 2>/dev/null || true)"
# then in each loop:
while IFS= read -r -d '' p; do …; done <<EOF
$tracked
EOF
```
Caveat for the fixer: a `here-doc` appends a trailing newline; with `-d ''` the final (empty) record after the
last NUL is read as `""` and skipped by the existing `[ -z "$p" ] && continue`. `read -d` exists in bash 3.2.
Verify the three loops (dry-run preview, PASS A managed-scan, PASS B aside) all switch together.

**Severity call:** Minor — no clobber/data-loss (design backstop holds), affects only exotic filenames (rare
for dotfiles). But because this is a Risk=4 review whose thesis is "pre-aside makes never-clobber *provable*",
the gap in the pre-aside is worth closing; a strict reviewer could call it Blocking-for-completeness.

## M2 — [Minor] checkout-fail message claims "asides retained" even when zero asides were made

**Where:** the `if ! dotfiles_git checkout` branch: it always dies with `"asides retained"`, but in the M1
failure mode (collider missed → checkout refuses) **no asides exist**. Misleading in exactly the case a user
would be debugging. Suggest gating the "asides retained" line on `[ -n "$aside_list" ]` (the branch already
has `[ -n "$aside_list" ] && { warn "Files moved aside…"; … }` for the list — extend that to the wording).

## M3 — [Minor/Future] dry-run temp dir leaks on interrupt

**Where:** dry-run preview: `tmp="$(mktemp -d …)"` … `rm -rf "$tmp"`. On the normal path the temp is removed,
but `DOTFILES_ADOPT_ACTIVE` is **not** set during dry-run and the master `cleanup_handler` doesn't know about
`$tmp`, so a SIGINT/kill between `mktemp` and `rm` leaves an `xdg-adopt.XXXXXX` dir in `$TMPDIR`. Low impact
(temp dir, self-evidently named). Options: trap-tracked temp var, or accept as Future.

---

## Confirmed-correct (adversarially checked, no finding)

- **No `--force`/`-f`/`reset --hard`** anywhere (only the dry-run's informational "(NO --force)" string).
- **set -e footguns:** `dotfiles_path_is_managed` ends explicit `return 1`; `[ -n "$aside_list" ] && {…}`
  in the checkout-fail branch is not the last statement (a `die` follows) so a false left side can't trip set-e.
- **here-doc-not-pipe** for PASS A / PASS B loops → `managed`, `aside_list`, the trap flag, and `die` all run
  in the PARENT shell (a pipe would subshell them). Correct.
- **die-inside-`$()`** avoided: `tracked` captured with `|| true`; `dotfiles_resolve_rc` sets a global + dies
  in the parent (reused unmodified).
- **#5b uniquifier** `while [ -e "$bak" ] || [ -L "$bak" ]` catches a dangling-symlink aside; **symlink
  colliders** `mv` the link (verified: target untouched); managed-lane symlinks are refused earlier.
- **Spaces in filenames** are handled (ls-tree does not quote them; `IFS= read -r` + quoted `"$HOME/$p"`).
- **mktemp** `mktemp -d "${TMPDIR:-/tmp}/xdg-adopt.XXXXXX"` is BSD(macOS)+GNU compatible; failure `|| die`.
- **`ADOPT_ACTIVE` reset before the managed-refuse die** (the coder's noted deviation) is correct — prevents a
  misleading trap message after the clone was removed and no asides were made.
- **shellcheck** clean (`make lint` rc=0); `SC2086` disables on keyset loops are intentional and correct.
- **Protected surfaces** unchanged (offload/drop, `offload_repos_in`, `dotfiles_install_rc_source` internals,
  home-tree/lib); the `dotfiles_write_aliases` extraction is byte-preserving (D1/D6 green).

---

## Recommendation

Land after **M1** (the `-z` enumeration fix) — it closes the one gap in the pre-aside completeness guarantee at
low cost. **M2** is a one-line message fix, ideally bundled with M1. **M3** is Future. No Blocking data-loss
issue; the no-force backstop is verified to prevent clobber even when the pre-aside misses a collider.
