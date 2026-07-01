# Architect Design-Coherence Review — PR #27 (dotfiles adopt)

**Reviewer:** pact-architect · **Date:** 2026-07-01 · **Branch:** `feature/dotfiles-adopt`
**Scope:** `git diff main...feature/dotfiles-adopt` (bin/cloud-xdg-provision.sh +186; smoke +168; doc +333)
**Angle:** implementation vs my spec (`dotfiles-adopt-diff.md`) + coherence with the merged
init/track/status + offload lanes. Severity: **Blocking / Minor / Future**.

## Verdict: APPROVE (no Blocking findings)

The implementation faithfully realizes the spec and the lead's two-pass refinement. The
load-bearing property — **never clobber a user file** — holds end-to-end and is provable.

---

## What I verified (all correct)

- **Two-pass ordering (correct + minimal).** PASS A scans the FULL tracked list (`ls-tree -r
  --name-only HEAD`) and, on ANY managed-lane hit, `rm -rf`s the fresh clone + dies naming **all**
  offenders → `$HOME` fully untouched. PASS B pre-asides every collider, THEN checks out. The two
  passes are *required* (must know all managed offenders before any `mv`), so the double scan is
  intentional, not a smell.
- **Never-clobber is provable.** Every existing tracked path is moved aside before checkout;
  `checkout` runs with **no `-f`/`--force`**, so it can only write now-absent paths. If a collider
  somehow remained, `checkout` fails (no force) → checkout-fail die, still no clobber. Aside
  uniquifier uses `-e` OR `-L` (catches dangling symlinks); an existing aside is never overwritten.
- **Symlink + nested colliders handled.** `[ -e ] || [ -L ]` asides a symlink collider by moving the
  LINK (not its target). Nested paths under a managed dir (e.g. `Documents/foo`) are caught by the
  top-component check in `dotfiles_path_is_managed`. `.config/*` is correctly NOT managed (trackable).
- **`die` reaches the parent; flags/lists accumulate in the parent.** Both PASS A and PASS B are
  here-doc-fed (`done <<EOF … EOF`), not `printf | while`, so `managed`/`aside_list` accumulate and
  `die` terminates the script (not a subshell). `tracked` is captured with `|| true` (no `die` in `$()`).
- **`dotfiles_path_is_managed` is set-e-safe** (ends with explicit `return 1`; matches used in `if`).
- **Extraction is behavior-preserving.** `dotfiles_write_aliases` is the byte-identical alias block
  lifted out of `cmd_dotfiles_init`; init now calls it. `dotfiles_install_rc_source` is **unmodified**
  (diff shows only the new function added after it, plus init's call site). Init D1/D6 smoke should stay green.
- **Lane coherence.** Uses `set_mode` (one-lane), `begin_mutating_mode`, `--apply`/dry-run gating,
  `DOTFILES_*` naming, and adds exactly one branch to the SINGLE master `cleanup_handler` (bash-3.2
  one-handler rule) — consistent with the offload/migrate/relocate windows.
- **dry-run** temp-clones to `mktemp -d`, previews the exact would-aside + would-refuse list, touches
  nothing under `$HOME`, and `rm -rf`s the temp unconditionally.
- **Smoke coverage present** (D13): collider→aside (original preserved), managed-lane repo refused
  (`$HOME` untouched), `.dotfiles`-exists → refuse. Good — matches the failure matrix.

---

## Findings

### Minor

- **M1 — Doc/impl divergence on `DOTFILES_ADOPT_ACTIVE` arming.** The committed spec (§5 line ~204,
  §9) says the flag is *"armed ONLY around aside+checkout"* (narrow). The implementation arms it at
  **clone** (`STAGE="clone"`) and instead **resets `=0` before every deliberate `die`** (clone-fail,
  managed-refusal, checkout-fail) — a broad-arm + reset-before-die approach.
  Both are safe: no deliberate `die` fires a spurious "INTERRUPTED" (each resets first), and the impl's
  version additionally covers a *signal during clone* (bonus). But the doc and code now describe
  different strategies. **Recommend: update the doc (§5 clone block + §9 bullet) to match the impl's
  broad-arm + reset-before-die**, since the impl is safe and strictly more protective. Sub-nit: the
  `STAGE="clone"` recovery line says *"a PARTIAL clone if it stopped during 'clone'"* — once clone has
  succeeded and we're in config/PASS-A with `STAGE` still `clone`, that wording is slightly inaccurate
  (harmless — the advice "rm -rf then retry" is still correct).
  *This is a documentation-consistency finding, not a code defect.*

- **M2 — apply-mode clone/checkout/mv are bare `git`, not wrapped in `run()`.** The offload lane routes
  mutations through `run()` for a `[run] …` audit line; adopt calls `git clone`/`dotfiles_git checkout`/
  `mv` directly (dry-run prints its own plan). This is *consistent with the merged dotfiles lane*
  (`cmd_dotfiles_init` uses bare `dotfiles_git config` alongside `run git init`), so it's a low-priority
  consistency nit. Optional: `if ! run git clone --bare …` would add the audit line while keeping the
  failure branch.

### Future

- **F1 — empty-remote adopt.** If the remote bare repo has no commits, `ls-tree HEAD` yields nothing
  (`|| true`), PASS A/B no-op, and `dotfiles_git checkout` then fails (no HEAD) → the checkout-fail
  path dies "adopt incomplete", leaving a valid-but-empty `~/.dotfiles`. Odd but low-impact (adopting
  an empty repo is a `--dotfiles-init` use case). Consider detecting an empty/HEAD-less clone and
  treating it as init-like success, or documenting that adopt requires a non-empty repo.

- **F2 — `rm -rf "$DOTFILES_DIR"` has no degenerate-path guard.** `DOTFILES_DIR` is the fixed
  `"$HOME/.dotfiles"` (never from `MODE_ARG`), so this is safe in practice; only a pathological
  unset/empty `$HOME` could degrade it (and `guard_not_root`/`begin_mutating_mode` run first).
  For defense-in-depth, consider mirroring the offload lane's degenerate-path refusal
  (`case "$DOTFILES_DIR" in ""|"/"|"$HOME") die …`).

---

## Adversarial / fresh-eyes addendum (self-review of the design, not just impl-vs-spec)

### Minor

- **M3 — adopt's reuse of `dotfiles_install_rc_source` can leave a just-adopted, TRACKED rc file
  immediately dirty.** After checkout, adopt calls `dotfiles_install_rc_source`, which **appends** the
  sentinel `source` block to `RC_TARGET` (e.g. `~/.zshrc`). If the adopted repo **tracks that rc file**
  (extremely common — people keep `.zshrc`/`.bashrc` in their dotfiles), adopt checks it out clean and
  then appends our block → the tracked file is now modified, so `dotfiles status` shows ` M .zshrc`
  right after a fresh adopt (and a later `dotfiles commit` would fold our machine-specific block into
  their repo). *Mitigating nuance:* if the adopted rc already carries our sentinel (they ran init on
  another machine), `install_rc_source`'s `grep -qF` short-circuits → no append → no dirtying. So this
  bites the first-adopt-of-a-pre-existing-repo case.
  **Recommend:** after checkout, detect whether `RC_TARGET` is tracked by the adopted repo (e.g.
  `dotfiles_git ls-files --error-unmatch "<rc-rel-path>"`), and if so **skip the append + inform the
  user** ("your adopted rc is tracked; add the alias source line yourself if it isn't already"), or at
  least **warn** that the rc now shows modified and why. This keeps `dotfiles status` clean after adopt
  and avoids silently committing our block into the user's repo. *(This is an interaction between the
  adopt-checkout and the reused init rc-wiring — neither is wrong alone; the coherence gap is only in
  their combination, which is why it wasn't visible reviewing them separately.)*

### Future / security note

- **F3 — adopt checks out shell-executable config from a user-supplied URL (trust boundary).** By
  design, adopt materializes `.bashrc`/`.zshrc`/`.profile` etc. from an arbitrary remote; those run on
  the user's next login. This is inherent to "adopt your dotfiles" (the user chose the URL), and the
  main checkout-time code-exec vectors are limited (git does NOT copy remote hooks on clone, and
  clean/smudge filters require filter commands already defined in the user's git config — a repo alone
  can't define an executing filter). Still, a fresh-eyes review should NAME the boundary: **the user
  must trust the remote; the adopted rc files are attacker-controlled if the URL is.** Recommend a
  one-line note in `usage()`/docs ("adopt only repos you trust — their shell rc files will run on next
  login"). Not a code defect; documentation/expectation-setting.

## Coherence summary

Adopt slots cleanly into the four-lane design (classification / offload / dotfiles / adopt): the
rclone-remote offload lane and the git-bare dotfiles lanes stay mutually exclusive via `set_mode`;
adopt reuses the dotfiles helpers without modifying the risky rc-edit; and it adds only additive
surface. No inconsistency with the merged lanes, no missing data-loss failure mode. The one item worth
acting on before merge is **M1** (align the doc to the shipped trap-arming approach) so the committed
spec and code tell the same story; M2/F1/F2 are optional/low-priority.
