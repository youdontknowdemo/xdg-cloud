# Architecture Review — `xdg-cloud` PR #1

**Reviewer:** pact-architect · **Date:** 2026-06-28 · **Branch:** `feature/cloud-xdg-provision`
**Scope:** Design coherence, component boundaries, interface contracts, separation of concerns,
extensibility, spec-basis alignment. Two scripts (`bin/cloud-xdg-provision.sh`, `bin/home-tree.sh`)
plus Makefile, hooks, tests, docs.

**Verdict:** Solid, above-average shell engineering with genuinely well-considered safe-by-default
discipline and structurally-enforced invariants. **One BLOCKING interface-contract defect** (relative
`--cloud-root` silently produces dangling symlinks). Several MINOR coherence and DRY issues. The
monolith and two-script decisions are both correctly made.

---

## Summary table

| ID | Severity | One-line |
|----|----------|----------|
| B1 | BLOCKING | Relative `--cloud-root` silently creates dangling symlinks (no path absolutization) |
| M1 | MINOR | `--style mac` produces cloud folder `Videos`, not the documented `Movies` — `cloud_name` abstraction is incomplete |
| M2 | MINOR | Trailing slash on `--cloud-root` yields `//` targets and breaks cross-invocation idempotency |
| M3 | MINOR | The canonical "portable user-data set" is defined twice, divergently, with no shared source of truth |
| M4 | MINOR | ~40 lines of plumbing + platform logic duplicated verbatim across the two scripts; no shared lib |
| M5 | MINOR | `local_name()` first parameter is dead — confusing interface |
| M6 | MINOR | No check that `CLOUD_ROOT` is a live mount before symlinking into it (silent local-disk fallback) |
| F1 | FUTURE | `OFFLOAD_SET` rows have no arity validation — malformed edits mis-parse silently |
| F2 | FUTURE | `OFFLOAD_SET` parsed 3× via subshell pipes, one `cut` per field; fine now, note if it grows |
| F3 | FUTURE | Naming/style logic is a candidate for the shared module implied by M4 |

---

## BLOCKING

### B1 — Relative `--cloud-root` silently creates dangling symlinks
**`bin/cloud-xdg-provision.sh`** — `resolve_cloud_root` (137–147), `ensure_cloud_tree:190`,
`redirect_one:208,228,243`, `write_user_dirs:274`.

`CLOUD_ROOT` is never canonicalized to an absolute path. The cloud tree is created with
`mkdir -p "$CLOUD_ROOT/$cn"` (resolved against **CWD**), while the symlink is created with
`ln -s "$target" "$localpath"` where `target="$CLOUD_ROOT/$cn"` is stored verbatim into a link that
lives under `$HOME` — so it resolves against **`$HOME`**, not CWD. The two locations diverge.

Verified (`--apply`, sandboxed HOME, `--cloud-root ./relcloud`):
```
[run] mkdir -p ./relcloud/documents                     # created under CWD
[run] ln -s ./relcloud/documents <home>/Documents       # link resolves under $HOME
readlink <home>/Documents  ->  ./relcloud/documents
[ -e <home>/Documents ]    ->  BROKEN/DANGLING
```

This is a silent-corruption defect on the **primary documented entry point** (`--cloud-root PATH`).
There is no validation, no warning, and on a second `--apply` the new dangling-symlink-detection branch
(216–224) will now *leave the broken links in place* and warn — stranding the user with a pile of
dead links and data scattered in a CWD-relative tree they didn't expect.

**Fix:** absolutize `CLOUD_ROOT` once, early in `resolve_cloud_root`, before any `mkdir`/`ln` uses it
(e.g. resolve via a `cd "$dir" && pwd` of the parent, or reject a non-absolute path with a clear error).
Whichever the coder picks, the contract should be: *an absolute path in, or a hard error out.* Silent
acceptance of a relative path is not acceptable for an interface that creates symlinks.

---

## MINOR

### M1 — `--style mac` does not produce the documented Apple folder names
**`bin/cloud-xdg-provision.sh`** — `cloud_name` (150–160), header comment `:42`, `OFFLOAD_SET:71`.

The header promises `mac = capitalized (Documents, Music, Movies)`. But `cloud_name` only
**capitalizes the canonical token** (`videos` → `Videos`); it never consults the Apple-name column
(`OFFLOAD_SET` field 2 = `Movies`). Verified: `--style mac` creates `<cloud>/Videos`, while the local
mac dir is `~/Movies`. So the cloud folder is `Videos`, contradicting the documented `Movies`.

The `cloud_name` abstraction is therefore incomplete: "style" is implemented as a casing transform, but
the mac convention is a *naming* convention (`videos`→`Movies`), not a casing one. Either route
`--style mac` through the mac-name column for folders that diverge, or fix the header/README to state
that `--style mac` capitalizes canonical names and does **not** apply Apple-specific renames to cloud
folders. As written, code and docs disagree.

### M2 — Trailing slash on `--cloud-root` is not normalized
**`bin/cloud-xdg-provision.sh`** — `redirect_one:208`, `write_user_dirs:274`.

`target="$CLOUD_ROOT/$cn"` with `CLOUD_ROOT=/x/` yields `/x//documents`. Cosmetic in `ln -s`, but the
idempotency check (`readlink == target`, 212) is string equality, so running once with a trailing slash
and once without will fail the match and fall into the "other symlink, leave untouched" branch (221) —
producing a spurious warning and a no-op where the user expects "ok". Normalize trailing slashes when
absolutizing (ties to B1's fix — do both in one place).

### M3 — The "portable user-data set" is defined twice and the two definitions disagree
**`bin/cloud-xdg-provision.sh:65–75` (`OFFLOAD_SET`)** vs **`bin/home-tree.sh:32` (`SAFE_DIRS`)**.

This is the deepest design issue. The core domain concept — *which user folders are portable to the
cloud* — is the shared identity of the whole toolkit, yet it is encoded twice, in two different data
structures, with two different enforcement mechanisms, and **different contents**:

- `OFFLOAD_SET`: desktop, documents, downloads, music, pictures, videos, public, templates, projects
- `SAFE_DIRS`:   Documents, Pictures, Music, Videos, Projects, **Notes**

`cloud-xdg-provision` enforces the invariant *by data omission* (base/system dirs simply never appear in
`OFFLOAD_SET`); `home-tree` enforces it *via an rclone allow/deny filter* (`write_filter:153–187`). Two
mechanisms, two lists, no single source of truth — they can and already do drift (Desktop/Downloads/
Public/Templates vs Notes). The README documents the divergence (161–167), which is honest, but
documentation is not architecture. If these are meant to be the same conceptual set, they should derive
from one definition; if they are deliberately different, that intent should be expressed in code (e.g. a
shared base set + per-script extensions), not left as two hand-maintained lists that a future edit will
silently desync.

### M4 — Duplicated plumbing and platform logic; no shared library
**`cloud-xdg-provision.sh:80–87` vs `home-tree.sh:50–62`** (identical `log/info/warn/die/run`);
**`cloud-xdg-provision.sh:129–135` vs `home-tree.sh:106–117`** (identical platform detection);
**`cloud-xdg-provision.sh:141–143` vs `home-tree.sh:121–127`** (macOS GoogleDrive glob, duplicated).

~40 lines are duplicated verbatim across the two scripts, including the load-bearing platform-detection
and Drive-mount-discovery logic. The ADR never evaluated extracting a `lib/common.sh`. There is a
legitimate counter-argument — keeping each script standalone makes it individually portable (drop on
`PATH`, `curl | bash`, copy into a dotfiles repo) with no sourcing dependency — and for a two-script
toolkit that may be the right call. But it is a real architectural decision that was made by default, not
deliberately. Recommend the coder/ADR explicitly state the stance: *"self-contained by design, duplication
accepted"* — and if so, add a one-line comment in both plumbing blocks noting they are intentional twins
that must be edited together. Otherwise the duplication is a silent drift risk (see how M3 already drifted).

### M5 — `local_name()` first parameter is dead
**`bin/cloud-xdg-provision.sh:163–165`**, called at `:207` as `local_name "$canon" "$mac" "$lin"`.

The body only uses `$2`/`$3`; `$1` (`canon`) is never referenced. A 3-arg call where one arg is ignored
is a confusing interface and invites a future caller to pass args in the wrong order. Drop the unused
parameter (call `local_name "$mac" "$lin"`) or document why it's there.

### M6 — No "is this actually a mount?" check before provisioning into CLOUD_ROOT
**`bin/cloud-xdg-provision.sh`** — `resolve_cloud_root:137–147`, `ensure_cloud_tree:190`.

On Linux/Termux the contract (README "Known traps", 183–185) is that `CLOUD_ROOT` must be a *live mount*.
But `ensure_cloud_tree` just `mkdir -p`s into it. If the rclone/ocamlfuse mount is down, the script
silently creates a plain **local** directory tree and symlinks `~/Documents` into it — the user believes
their data now lives in the cloud when it lives on local disk, and the real mount (when it comes up) will
shadow it. The footgun is documented but not guarded. Consider a non-fatal warning when `CLOUD_ROOT` is
not a mountpoint on Linux (e.g. `mountpoint -q` / compare `stat -f`), or at minimum require the path to
already exist (don't `mkdir -p` the cloud *root* itself, only its subdirs).

---

## FUTURE

### F1 — `OFFLOAD_SET` rows have no arity validation
**`field():170`, `redirect_one:197–201`.** A malformed row (wrong field count after a future edit) parses
silently: a missing `redirect` field makes `wantredir=""`, the `[ "$wantredir" = "1" ]` test is false, and
the row is silently skipped with no error. For a fixed XDG spec set this is low-risk, but the pipe-DSL is
the documented extension point ("add an entry by editing the string"), so a malformed edit failing
silently is a poor extension experience. Consider a one-pass validator (assert 5 fields per non-empty row)
or a loud comment above `OFFLOAD_SET` stating the exact field contract.

### F2 — `OFFLOAD_SET` is parsed three times via subshell pipes
**`ensure_cloud_tree:187`, `main:319`, `write_user_dirs:270`** each do `printf | while read`, and `field()`
spawns a `cut` per field per row. Irrelevant at 9 rows; noting only because the pattern (and its
`printf | while` subshell, which also means no loop variable can escape) would not scale and is easy to
copy into a future third script. Acceptable as-is.

### F3 — Naming/style logic is a candidate for the shared module implied by M4
`cloud_name`/`local_name`/`--style` handling is exactly the kind of pure, testable naming logic that
would belong in the `lib/common.sh` discussed in M4 if a third strategy script is ever added. No action
now; flag for when the toolkit grows past two scripts.

---

## Answers to the seven review questions

1. **Does the structure match the spec basis, and are the hard rules enforced or just documented?**
   Enforced, and notably well: base dirs (`config/data/state/cache`) are *structurally* incapable of
   offloading in `cloud-xdg-provision` because they never appear in `OFFLOAD_SET` and are only ever
   `mkdir`'d locally (`ensure_local_base:175–182`); system roots are referenced nowhere. That is
   enforcement-by-construction, not just prose. **Strength.** The caveat is M3 — the *same* invariant is
   enforced by a *different* mechanism in `home-tree` (rclone filter), so the rule is real but expressed
   twice.

2. **Should `relocate_dir` / `ensure_cloud_tree` / `redirect_one` be separate scripts?**
   No. They are sequential steps of one cohesive workflow ("make the cloud my live home") and are already
   cleanly decomposed into single-purpose functions. Splitting them into separate executables would harm
   usability (the user wants one command) for no modularity gain. The internal decomposition is good; the
   monolith is justified.

3. **Is `--cloud-root PATH` a well-designed entry point? Relative paths / trailing slashes / spaces?**
   Spaces: handled correctly (quoted throughout — important for macOS "My Drive"). **Relative paths:
   broken — see B1 (BLOCKING).** Trailing slashes: M2 (MINOR). The entry point is the right *shape* but
   lacks input normalization; it trusts the caller to pass a clean absolute path and fails silently when
   they don't.

4. **Is editing `OFFLOAD_SET` the right way to add an entry?**
   For a set that mirrors a fixed public spec (XDG user-dirs), a static table is reasonable and honest —
   you are not building a plugin system for nine folders. The weakness is the silent-failure mode on
   malformed edits (F1), not the table-as-config choice itself.

5. **Is the pipe-delimited string a reasonable bash-3.2 data structure?**
   Yes — given the 3.2 constraint (no associative arrays), a delimited table parsed by `cut` is a
   standard, defensible idiom. The subtle risks are real but contained: no field may contain `|` or
   leading whitespace, and no arity check exists (F1). Reasonable, with the caveat noted.

6. **Is provision + redirect + write-user-dirs too much for one script?**
   No. These are three steps of one use case, not three concerns glued together. They are properly
   separated into distinct functions and run in a clear pipeline in `main`. Cohesion is high. Keep it.

7. **`home-tree.sh` vs `cloud-xdg-provision.sh` — one script or two?**
   Two, correctly. They embody opposite strategies (cloud-as-live-home vs local-home+backup) and the
   ADR/README frame them as an either/or per machine. Merging into one `--mode` tool would create a
   confusing mega-command and blur the safety-critical "pick one lane" framing. Two scripts is the right
   call; the duplication cost it incurs is M4, which is a separate, addressable concern.

---

## Design strengths (preserve these)

- **Invariants enforced by construction**, not just documented (Q1).
- **Safe-by-default applied consistently**: dry-run default, `--apply` + action-flag gating, `--relocate`
  renames aside and never deletes, `home-tree` archives + `--max-delete` guard.
- **`redirect_one`'s symlink-state decision tree** (212–244) is well-ordered, and the comment explaining
  why dangling-link detection must precede the `[ ! -e ]` check (216–220) shows real care about a subtle
  `set -e` failure mode.
- **Two-script split and the either/or README framing** correctly convert a philosophical tension into a
  user-facing choice rather than a hidden footgun.
