# Research: rclone offload-on-demand + dotfiles bare-repo + macOS gotchas

> PACT Prepare-phase consultation for the home-classification / dotfiles plan
> (feeds architect Task #8 → plan Task #6). **Analysis only — no implementation.**
> Target: `bin/cloud-xdg-provision.sh` conventions (stock macOS bash 3.2, dry-run
> default, `--apply` gate, single master cleanup trap, here-doc-not-pipe).

## Executive Summary

Three capabilities are being folded into xdg-cloud: (a) classify **all** top-level
`~/` dirs, (b) **offload-on-demand** for git-managed code dirs (push to cloud, drop
local to free space, re-hydrate later, git = source of truth), (c) a **dotfiles
bare git repo** + idempotent shell aliases.

The single most important design fact — confirmed by the existing two scripts — is
that **only an rclone REMOTE frees local space**. `home-tree.sh` already uses an
rclone remote (`rclone sync`/`bisync`); `cloud-xdg-provision.sh` symlinks into a
synced **mount** (`~/Library/CloudStorage/...`, iCloud) and frees **no** space until
the provider uploads and evicts. Offload-on-demand must therefore be built on the
**rclone-remote** model (like `home-tree.sh`), not the mount-symlink model — or, for
an iCloud-only machine, on an explicit `brctl evict` after upload. The verifiable
safe sequence is **copy → check (read-back) → only then drop local**, and because
git is the source of truth, the drop must additionally be gated on a **clean working
tree AND a confirmed push to the remote**, so the cloud copy is belt-and-suspenders,
never the sole copy.

A virtualenv is **not** a safe offload target (hardcoded absolute paths break on
re-hydration to a different path); a git repo **is**. The classifier must encode
that distinction.

---

## 1. SCOPE IN MY DOMAIN

What this research validates (effort: ~medium — patterns are well-established; the
synthesis to bash 3.2 + git-as-truth is the novel part):

- The verifiable rclone **push → verify → drop** sequence and which subcommand/flags
  make the verify trustworthy *before* the local delete.
- The **re-hydrate** sequence and partial/interrupted-hydration detection.
- The **git safety-gate set** that makes "drop local" safe when git is source of truth.
- **rclone-remote vs mounted-cloud-path** trade-off for *actually freeing space*.
- The canonical **dotfiles bare-repo** init + idempotent alias install + its pitfalls
  and its interaction with cloud-xdg home-dir symlinking.
- A **per-dir safety verdict** for the named code dirs (which break if moved).

Out of scope (architect/coder owns): the actual bash functions, the registry schema
changes, the CLI flag surface, test fixtures.

---

## 2. DEPENDENCIES & INTERFACES (what the architect needs from this)

- **Reuse `home-tree.sh`'s rclone plumbing**: `require_rclone()` (checks binary +
  `rclone listremotes | grep -qx "remote:"`), the `RCLONE_REMOTE`/`DRIVE_SUBDIR`
  env-override convention, and the `run()`/dry-run discipline. Offload-on-demand is
  closer to `home-tree.sh` (rclone remote) than to `cloud-xdg-provision.sh`.
- **New per-dir state**: offload needs to record, per offloaded dir, the remote path
  it went to (so re-hydrate knows the source). Suggest a small state file under
  `$XDG_STATE_HOME/xdg-cloud/offloaded/<dir>.json` (or a flat list) — state is
  machine-specific and stays local per the project's HARD RULES.
- **Classifier interface**: a function that, given a top-level `~/` entry, returns a
  class ∈ {offloadable-git, offloadable-data, never-local (config/state/cache),
  unsafe-to-move (venv/abs-path), system, unknown}. Architect decides whether this
  extends the `XDG_DIR_REGISTRY` or is a separate code-dir registry.
- **Git preconditions are a hard interface**: the offload command must shell out to
  `git -C "$dir"` and refuse on any non-clean/un-pushed state (see §3/§5).
- **Coupling caution**: keep offload-on-demand a *third* mode, not a merge of the two
  existing scripts — the README's "don't run both strategies on one home" warning
  means the new mode must declare which lane it lives in (it's a backup-style remote
  offload, compatible with `home-tree.sh`'s stance).

---

## 3. KEY DECISIONS & TRADE-OFFS (with recommendations)

### 3a. rclone REMOTE vs mounted cloud path — *which frees space?*

| Model | Frees local space? | Mechanism | Trade-off |
|-------|--------------------|-----------|-----------|
| **rclone remote** (`rclone copy local remote:path`) | **Yes, immediately** after local delete | True upload to provider; local copy then removed by us | Requires `rclone config`; upload time = quota/bandwidth bound; re-hydrate is an explicit `rclone copy remote→local` |
| **Mounted cloud path** (`mv`/`rsync` into `~/Library/CloudStorage/...` or iCloud) | **No** — not until provider uploads *and* evicts | File still occupies local disk in the sync cache | Subject to the exact sync-eviction lag the repo already documents; `--relocate` already does this for *symlink* semantics, not space-freeing |

**Recommendation: build offload-on-demand on the rclone REMOTE model.** It is the
only one that frees space deterministically and synchronously-from-the-user's-view,
and it reuses `home-tree.sh`'s existing, tested rclone discipline. The mounted-path
model is already covered by `cloud-xdg-provision.sh` for a different purpose
(symlink-live-home) and does **not** free space.

### 3b. The offload safety-gate set (git = source of truth)

Recommended **guards, all must pass before any local drop** (fail-closed):

1. **Is a git repo** — `git -C "$dir" rev-parse --is-inside-work-tree` succeeds.
   (Non-git dirs take the *data* path or are refused, not the git path.)
2. **Clean working tree** — `git -C "$dir" status --porcelain` is empty (no
   uncommitted, no staged, no untracked-that-matter). Refuse otherwise.
3. **No unpushed commits** — every local branch's `@{upstream}` is reachable on the
   remote: `git -C "$dir" rev-list --count @{u}..HEAD` == 0 for the current branch,
   and ideally check all branches (`git for-each-ref --format … refs/heads`). Refuse
   if anything is ahead of its upstream, or if a branch has **no** upstream.
4. **No stashes / no untracked-ignored-but-precious** — warn if `git stash list` is
   non-empty (stashes are NOT pushed and would be lost on a re-clone). This is the
   subtle data-loss trap: a clean tree can still hide stashes and untracked build
   artifacts the user cares about.
5. **rclone verify passed** (§3c) — the cloud copy is proven present before delete.

Rationale: with all five, the cloud copy is **belt-and-suspenders** — even if the
cloud blob were lost, `git clone` from the remote fully reconstructs the dir. Drop is
then safe. This is the inverse of `cloud-xdg-provision.sh`'s relocate, which retains
a `*.pre-offload-DATE` aside *because* the data has no other source of truth; here
git **is** the other source, so we can actually delete.

> ⚠️ Recommend still NOT `rm`-ing instantly: move to a local `*.pre-offload` aside
> first, verify cloud, then `rm -rf` the aside — OR rely on git remote as the net and
> delete directly. Architect should choose: aside-then-delete (safer, needs 2× peak
> space briefly) vs delete-direct (frees space immediately, leans fully on git+cloud).
> Given the whole point is to *free space*, **delete-direct after the 5 guards** is
> defensible — but make it an explicit, documented choice, not silent.

### 3c. The verifiable rclone sequence (copy → check → drop)

The robust, citable pattern (anjackson.net; rclone docs) adapted to "verify before
delete local":

```sh
# 1. PUSH (one-way, local -> remote). --immutable makes a changed/partial file an
#    ERROR rather than a silent overwrite; --no-traverse skips a slow dest pre-scan.
rclone copy --immutable "$dir" "$remote:$dest" --progress

# 2. VERIFY by reading the bytes BACK from the remote and comparing hashes.
#    --download forces a real read-back (not a trust-the-listing compare) — critical
#    for providers whose listing hash can't be trusted / FUSE async-upload lag.
#    --one-way: don't flag extra files already on the remote.
rclone check --download --one-way "$dir" "$remote:$dest"

# 3. Only if step 2 exits 0 AND the §3b git guards pass: drop the local copy.
```

Key flag rationale:
- **`rclone check --download`** is the verification that actually protects you: it
  re-reads every file from the remote and checksums it locally, so it catches a
  truncated/failed upload that a metadata-only `check` would miss. This is the direct
  analogue of, and stronger than, `cloud-xdg-provision.sh`'s `verify_copy()` caveat
  ("proves integrity in the mount's *view*, not durable upload") — a remote read-back
  *does* prove durable presence on the provider.
- **`--checksum`** on copy/sync compares by hash+size instead of mtime+size — use for
  re-hydrate idempotency.
- **Do NOT use `rclone move`** as the one-shot primitive for the drop. `move` deletes
  the source after a *copy-phase* success, but for git-source-of-truth we want the
  delete gated on the **independent read-back verify (step 2) AND the git guards** —
  not on copy's internal success alone. Use `copy` + `check --download` + explicit
  guarded local delete.

### 3d. macOS true-offload when the target is iCloud (not an rclone remote)

If a machine is iCloud-only (no rclone remote), the mounted-path model does not free
space. The macOS-native true-offload is **`brctl evict <path>`**, which replaces the
local copy with a dataless placeholder while keeping it in iCloud.

Trade-offs / requirements (cite as traps):
- Requires **"Optimize Mac Storage" ON** (the same setting the README flags as a
  dataloss footgun for `--relocate` of *placeholders*). For offload it's the enabler,
  but it means evicted files become **dataless** — and copying a dataless placeholder
  elsewhere copies an empty stub.
- `brctl evict` **strips most metadata** → Finder previews blank, **Spotlight won't
  index** the content.
- Re-hydrate is `brctl download <path>` (force-materialize).

**Recommendation:** offload-on-demand should default to the **rclone-remote** path
(reliable, provider-agnostic, frees space, reuses `home-tree.sh` plumbing). Treat
`brctl evict`/`download` as a **separate, clearly-labelled iCloud-only sub-mode**,
guarded by a macOS + iCloud-root + Optimize-Storage check — not the default, because
of the metadata/Spotlight loss and the Optimize-Storage coupling.

### 3e. Dotfiles bare-repo conventions + alias-install location

Canonical setup (Atlassian; bowmanjd; widely-used):

```sh
# init
git init --bare "$HOME/.dotfiles"
alias dotfiles='git --git-dir=$HOME/.dotfiles --work-tree=$HOME'
dotfiles config --local status.showUntrackedFiles no   # silence the $HOME noise

# fresh-machine adopt
git clone --bare <url> "$HOME/.dotfiles"
dotfiles checkout            # FAILS if a tracked file already exists locally
# -> on conflict: back the colliding files aside, then re-run `dotfiles checkout`
dotfiles config --local status.showUntrackedFiles no
```

Decisions:
- **`.dotfiles` (bare), not `.cfg`** — pick one name; bare dir holds only git
  internals, so it lives *outside* the work-tree problem (it's a dir, git ignores it
  via `status.showUntrackedFiles no`). Avoid a non-bare `~/.git` — that would make all
  of `$HOME` a single repo (recursion + catastrophic `git clean`).
- **Idempotent alias install** — append the alias to the rc file **only if absent**.
  Use a sentinel grep, not a blind append:
  ```sh
  rc="$HOME/.bashrc"   # or .zshrc per $SHELL; or a sourced ~/.config/xdg-cloud/aliases.sh
  line="alias dotfiles='git --git-dir=$HOME/.dotfiles --work-tree=$HOME'"
  grep -qF "git --git-dir=$HOME/.dotfiles" "$rc" 2>/dev/null || printf '%s\n' "$line" >> "$rc"
  ```
  **Recommendation:** write the alias to a **dedicated sourced file**
  (`~/.config/xdg-cloud/aliases.sh`) and ensure the rc file sources *that* (one
  idempotent guarded append), rather than appending the alias body directly. Cleaner
  to update/remove, matches the project's XDG-config-local stance, and avoids
  shell-specific duplication across `.bashrc`/`.zshrc`/`.profile`.

---

## 4. RISKS & CONCERNS

| Risk | Prob | Impact | Mitigation |
|------|------|--------|------------|
| **Drop local before durable upload** → data loss | Med | **Critical** | `rclone check --download` read-back (proves durable presence) + git remote as net; never delete on copy-phase success alone |
| **Clean tree hides stashes / untracked precious files** | Med | High | Guard 4: refuse/warn on non-empty `git stash list`; warn on untracked files even with clean *tracked* tree |
| **venv / abs-path dir offloaded then re-hydrated to a new path → breaks** | High (if not classified) | High | Classifier marks venvs (Pyenv/virtualenv) **unsafe-to-offload**; only git repos + plain data are eligible |
| **Branch with no upstream → `git clone` can't restore it** | Med | High | Guard 3: refuse if any local branch lacks an upstream or is ahead of it |
| **iCloud Optimize-Storage + dataless placeholder** copied as empty stub | Med | High | `brctl` sub-mode only; detect placeholders; never `rsync`/`cp` a dataless file |
| **Dotfiles `checkout` clobbers existing rc files on fresh machine** | High | Med | Detect collision, back aside (`*.pre-dotfiles`), then checkout — never force |
| **Dotfiles recursion** (`.dotfiles` tracked inside work-tree=$HOME) | Low | Med | `status.showUntrackedFiles no` + add `.dotfiles` to its own ignore; never a non-bare $HOME repo |
| **Bare-repo coexist with cloud-xdg symlinks**: a dotfile that is also a symlinked home dir | Low | Med | Dotfiles track files under `~/.config` etc. (LOCAL per HARD RULES); cloud-xdg only symlinks *user-data* dirs (Documents/Music/...). No overlap **if** dotfiles scope stays in config/state-class paths. Flag any tracked path that is also a redirect target. |
| **Existing `~/.gitconfig`** interaction | Low | Low | Bare-repo uses `--local` config; user's global `~/.gitconfig` is just another tracked file — track it deliberately, don't let it shadow `--git-dir` settings |
| **rclone remote not configured / wrong remote** | Med | Med | Reuse `home-tree.sh`'s `require_rclone()` precondition (binary + `listremotes` match) before any offload |

---

## 5. RECOMMENDED APPROACH (concrete sequences)

### Offload one git dir (the safe path)

```
PRECHECK   require_rclone (binary + remote exists)        # reuse home-tree.sh
GUARD 1    git -C "$dir" rev-parse --is-inside-work-tree  # is a repo
GUARD 2    [ -z "$(git -C "$dir" status --porcelain)" ]   # clean tree
GUARD 3    git -C "$dir" rev-list --count @{u}..HEAD == 0  AND every branch has
           an upstream with nothing ahead                  # fully pushed
GUARD 4    [ -z "$(git -C "$dir" stash list)" ]           # no hidden stashes (warn/refuse)
PUSH       rclone copy --immutable "$dir" "$remote:$dest" --progress
VERIFY     rclone check --download --one-way "$dir" "$remote:$dest"   # read-back
RECORD     write $XDG_STATE_HOME/xdg-cloud/offloaded/<dir> = "$remote:$dest"
DROP       (apply-mode only) remove local $dir            # space freed
           — architect's choice: aside-then-rm, or rm-direct leaning on git+cloud
```
Dry-run prints the whole plan and touches nothing (match existing `run()` discipline).

### Re-hydrate

```
LOOKUP     read recorded "$remote:$dest" for "$dir"
PULL       rclone copy --checksum "$remote:$dest" "$dir" --progress
DETECT-PARTIAL
           rclone check --download --one-way "$remote:$dest" "$dir"  # remote vs local
           — non-zero => incomplete/interrupted hydration; re-run copy, do NOT
             mark hydrated until check passes
ALT        prefer `git clone "$remote_url" "$dir"` when git is the source of truth and
           the cloud blob is only a cache — clone is self-verifying and needs no
           offload record. (Offer both: clone-from-git = canonical; rclone copy =
           restores untracked/ignored working files the git remote doesn't have.)
```
Interrupted-hydration signal: a post-copy `rclone check --download` mismatch, or a
sentinel "hydrating" marker file left until check passes (clear on success) so a
crashed hydrate is detectable on next run.

### Per-dir safety verdict for the named code dirs

| Dir | Offload-safe? | Why |
|-----|---------------|-----|
| `~/repos`, `~/Projects`, `~/AndroidStudioProjects` (git repos) | **Yes** (per-repo, via the guards) | git remote is source of truth; re-clone restores. Offload **per repo**, not the whole tree, so each gets its own clean/pushed check |
| A **Pyenv / virtualenv** dir | **No** | Hardcoded absolute paths in `bin/activate`, shebangs, `pyvenv.cfg`; relocating to a different path breaks it. Recreate from `requirements.txt`, don't offload |
| **QEMU images** (large `.qcow2`) | **Data path, not git** | Not git-managed; huge; offload as *data* (rclone copy + verify) with the aside-retained net (no git source of truth), or leave local |
| `~/AndroidStudioProjects` build output (`.gradle`, `build/`) | **Exclude from offload** | Regenerable, huge, churny — exclude like `home-tree.sh`'s filter excludes `node_modules`/`__pycache__` |
| `config`/`data`/`state`/`cache` | **Never** | HARD RULE — local, machine-specific, SQLite-lock-sensitive |

**Classifier rule of thumb:** *offload-eligible = (git repo with a clean, fully-pushed
state) OR (plain portable data with an aside-retained backup). Anything with embedded
absolute paths (venvs) or machine-managed (system, XDG base) is ineligible.*

---

## References

- rclone `copy` / `sync` / `move` / `check` — https://rclone.org/commands/rclone_copy/ , https://rclone.org/commands/rclone_check/ , https://rclone.org/commands/rclone_move/
- "Robust file transfers with Rclone" (copy `--immutable --no-traverse` → `check --download --one-way` → verified move) — https://anjackson.net/2023/07/04/robust-file-transfers-with-rclone/
- Atlassian — "How to Store Dotfiles: A Bare Git Repository" — https://www.atlassian.com/git/tutorials/dotfiles
- bowmanjd — bare-repo dotfiles (bash/zsh, fresh-machine adopt + conflict handling) — https://www.bowmanjd.com/dotfiles/dotfiles-2-bare-repo/
- macOS `brctl evict` / `brctl download` for iCloud true-offload (requires Optimize Storage; strips metadata/Spotlight) — https://techgarden.alphasmanifesto.com/mac/Manually-downloading-or-evicting-iCloud-files , https://clews.id.au/til/reclaiming-disk-space-from-icloud-drive-on-macos/
- In-repo precedent: `bin/home-tree.sh` (rclone remote `sync`/`bisync`, `require_rclone`, filter), `bin/cloud-xdg-provision.sh` (`verify_copy` durability caveat, relocate aside-retain, B2/B4/B5/B6 gates).
