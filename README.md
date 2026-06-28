# xdg-cloud

A small, self-contained, cross-OS shell toolkit for getting your user data to
the cloud **without breaking XDG/app correctness**. It ships two production
bash scripts that solve the same problem with **two opposite strategies** — you
pick one per machine. Both run on macOS, Linux, and Termux/Android, are
dry-run by default, and keep your machine-specific `config`/`data`/`state`/`cache`
strictly local (never in the cloud).

---

## Choose ONE strategy per machine

> ⚠️ **The two scripts take OPPOSITE stances on where your live data lives.**
> They are an **either/or** choice, **not** complementary defaults. **Do not run
> both on the same machine/home** — one makes the cloud your live home (local
> folders become symlinks into it), the other keeps the home local and mirrors
> it to the cloud as a backup. Running both creates confusing double-management
> (data living in the cloud *and* being rclone-mirrored to a second cloud
> location). It will not corrupt your files — both keep config/state/cache
> local — but it is a UX footgun. Pick a lane.

| Strategy | Script | When to use |
|----------|--------|-------------|
| **Cloud-as-live-home** | `bin/cloud-xdg-provision.sh` | You want `~/Documents`, `~/Music`, … to **BE** your Drive — the real data lives in the cloud and your local folders are pointers (symlinks) into it. You trust the cloud drive as primary storage. |
| **Local-home + backup** | `bin/home-tree.sh` | You want `~/Documents` etc. to **stay local** on fast disk, with the cloud as a safe, scheduled backup **mirror** (`rclone`). You treat the cloud as a backup, not primary. |

**New here? Start with `home-tree.sh`.** Keeping your data local and backing it
up is the lower-risk on-ramp. Reach for `cloud-xdg-provision.sh` once you
deliberately want a *live cloud home* — it is the more advanced stance.

---

## Safe by default

Both scripts **print a plan and change nothing** unless you pass `--apply`
*plus* an action flag. Nothing destructive ever runs from a bare invocation, so
you can always preview first. `cloud-xdg-provision.sh --relocate` renames the
original aside as `*.pre-offload-DATE` and **never deletes**; `home-tree.sh`
archives overwritten/deleted files and guards bulk deletions with
`--max-delete`.

---

## Quick start

```sh
# 1. (one time) activate the shellcheck pre-commit hook + chmod the scripts
make install

# 2. ALWAYS dry-run first — this only prints a plan, touches nothing:
#    Option A — cloud-as-live-home:
/bin/bash bin/cloud-xdg-provision.sh --cloud-root "/path/to/your/Drive"
#    Option B — local home + backup mirror:
/bin/bash bin/home-tree.sh

# 3. When the plan looks right, re-run with --apply (+ an action flag):
/bin/bash bin/cloud-xdg-provision.sh --cloud-root "/path/to/Drive" --apply --relocate
#    …or…
/bin/bash bin/home-tree.sh --apply --sync
```

> macOS ships bash 3.2; run the scripts with **`/bin/bash`**. Both are 3.2-safe.

---

## Per-platform prerequisites

| Platform | `cloud-xdg-provision.sh` | `home-tree.sh` |
|----------|--------------------------|----------------|
| **macOS** | Auto-detects `~/Library/CloudStorage/GoogleDrive-*/My Drive` as the cloud root. `rsync` preferred for `--relocate` (falls back to `cp -a`). | Detects the Drive mount for info only; backups always go through `rclone` for lock-safe behavior. `rclone` required for `--sync`/`--bisync`. |
| **Linux** | **`--cloud-root` / `CLOUD_ROOT` is mandatory** (no auto-detect) — point it at your rclone / google-drive-ocamlfuse / insync mount. Writes `$XDG_CONFIG_HOME/user-dirs.dirs`. | `rclone` required for backups. |
| **Termux/Android** | Same as Linux — `CLOUD_ROOT` mandatory. `pkg install rclone make`. | `pkg install rclone make`. |

Runtime deps: **coreutils** (both), **rsync** (optional, `--relocate`),
**rclone** (required for any `home-tree.sh` sync; `--bisync` needs a current
rclone build). `shellcheck` is a dev-only dependency (lint + pre-commit hook).

---

## `cloud-xdg-provision.sh` — cloud-as-live-home

Provisions a canonical user-data ontology **inside your cloud drive** and points
your local user dirs at it via symlinks. The real data lives in the cloud root.

| Flag | Effect |
|------|--------|
| `--apply` | Actually create folders / symlinks (default: dry-run). |
| `--relocate` | Move existing populated local dirs **into** the cloud, then replace them with symlinks. Original renamed aside (`*.pre-offload-DATE`), never deleted. Requires `--apply`. |
| `--style xdg\|mac` | Cloud folder naming: `xdg` = lowercase (`documents`), `mac` = capitalized (`Documents`). Default `xdg`. |
| `--cloud-root PATH` | The cloud-resident user-data home. Auto-detected on macOS; **mandatory** elsewhere. |
| `--redirect-downloads` | Also symlink `Downloads` (off by default — it's ephemeral triage). |

```sh
# preview, then apply + migrate populated dirs, with macOS-style names:
/bin/bash bin/cloud-xdg-provision.sh --cloud-root "$HOME/Library/CloudStorage/GoogleDrive-me/My Drive" --style mac
/bin/bash bin/cloud-xdg-provision.sh --cloud-root "$HOME/Library/CloudStorage/GoogleDrive-me/My Drive" --style mac --apply --relocate
```

## `home-tree.sh` — local home + safe backup mirror

Provisions a clean local XDG tree and mirrors the human-facing folders to the
cloud via `rclone`. The cloud is a **backup destination, never a live `$HOME`**.
A generated rclone filter (exclude → allow → catch-all deny) is the single
source of truth for what may travel.

| Flag | Effect |
|------|--------|
| `--apply` | Actually create dirs / run sync (default: dry-run). |
| `--sync` | ONE-WAY backup (local → cloud); deletions/overwrites archived, not lost. |
| `--bisync` | TWO-WAY sync via `rclone bisync` (adds `--resync` automatically on first run only). |
| `--root PATH` | Home-tree root (default: `$HOME`). |
| `--remote NAME` | rclone remote name (default: `gdrive`). |
| `--dest PATH` | Subpath inside the remote (default: `Backup/home`). |
| `--max-delete N` | Abort a sync that would delete more than N files (default: 25). |

```sh
# preview the local tree + filter (cloud untouched), then a safe one-way backup:
/bin/bash bin/home-tree.sh
/bin/bash bin/home-tree.sh --apply --sync --remote gdrive --dest Backup/home
```

---

## Hard rules (both scripts enforce these)

1. **Only the user-data layer offloads.** XDG *user* dirs (`desktop`,
   `documents`, `music`, `pictures`, `videos`, `public`, `templates`, plus a
   `projects` area) are the genuine cross-OS portable set.
2. **XDG *base* dirs stay LOCAL.** `config` / `data` / `state` / `cache` are
   machine-specific, high-churn, or SQLite-lock-sensitive. They are **never**
   sent to the cloud. Put live dotfiles in git (chezmoi / yadm / a bare repo).
3. **System roots are never offloadable.** `/`, `/usr`, `/etc`, `/var`, `/opt`,
   `/Applications`, `/System`, `/Library` are machine-managed — excluded by
   design. Offloading them is a category error.

### Canonical mapping (FHS / XDG / macOS → cloud folder)

```
config    XDG_CONFIG_HOME   ~/.config            -> LOCAL ONLY (git for dotfiles)
data      XDG_DATA_HOME     ~/.local/share       -> LOCAL ONLY (curate ports by hand)
state     XDG_STATE_HOME    ~/.local/state       -> LOCAL ONLY (logs/history)
cache     XDG_CACHE_HOME    ~/.cache             -> LOCAL ONLY (never cloud)
desktop   XDG_DESKTOP_DIR   ~/Desktop            -> <cloud-root>/desktop
documents XDG_DOCUMENTS_DIR ~/Documents          -> <cloud-root>/documents
downloads XDG_DOWNLOAD_DIR  ~/Downloads          -> create-only (triage)
music     XDG_MUSIC_DIR     ~/Music              -> <cloud-root>/music
pictures  XDG_PICTURES_DIR  ~/Pictures           -> <cloud-root>/pictures
videos    XDG_VIDEOS_DIR    ~/Movies (mac)       -> <cloud-root>/videos
public    XDG_PUBLICSHARE   ~/Public             -> <cloud-root>/public
templates XDG_TEMPLATES_DIR ~/Templates          -> <cloud-root>/templates
projects  (convention)      ~/Projects           -> <cloud-root>/projects

System root dirs (/ /usr /etc /var /opt /Applications /System /Library):
  machine-managed — NOT offloadable. Excluded by design.
```

(Folder names follow `--style`; `mac` capitalizes them. `home-tree.sh` uses the
capitalized `SAFE_DIRS` set: `Documents Pictures Music Videos Projects Notes`.)

> **Directory-set divergence between the two scripts:**
> `cloud-xdg-provision.sh` manages `Desktop`, `Downloads`, `Public`, and
> `Templates` in addition to the shared set — these map to XDG user-dirs that
> exist on most desktops. `home-tree.sh` manages `Notes` instead — a common
> personal folder with no XDG variable. Neither script is wrong; they cater to
> different usage patterns. If you switch strategies later, check for any
> directories in one set that you also want managed by the other.

---

## Known traps

- **Music / app SQLite databases stay local.** The Music *library database* and
  any `*.sqlite`/`*.db` files are excluded from sync — FUSE cloud mounts ignore
  POSIX locks and will corrupt them. Only your media *files* travel.
- **Relocating a large library is expensive.** `cloud-xdg-provision.sh --relocate`
  copies a populated dir into the cloud before symlinking. A 100k-track Music
  library can take a long time and a lot of cloud quota. Preview first.
- **macOS Finder + symlinks.** After `--relocate`, your local `~/Documents`
  becomes a symlink into "My Drive". Google's client syncs the real folder; the
  symlink is a local convenience. Some Finder/Spotlight behaviors differ on
  symlinked home dirs — verify before deleting the `*.pre-offload-DATE` original.
- **Linux/Termux need a real mount.** `cloud-xdg-provision.sh` has no auto-detect
  off macOS — `CLOUD_ROOT` must point at an actual mounted drive (rclone mount,
  ocamlfuse, insync). A bare path that isn't a live mount won't sync.
- **`rclone bisync --resync` runs only on the first run.** `home-tree.sh` adds
  `--resync` automatically the first time (to establish the baseline) and never
  again. Don't pass it manually on later runs — it can clobber the comparison
  state.
- **Don't run both scripts on one home.** See the warning at the top.

### macOS: special home folders & iCloud Drive (important)

macOS treats `Desktop`, `Documents`, `Downloads`, `Music`, `Movies`, `Pictures`,
and `Public` as **protected special folders**, and `cloud-xdg-provision.sh
--relocate` **cannot move them** on macOS. This is by design, not a bug:

- **It's an ACL, not TCC.** Each special folder carries a
  `group:everyone deny delete` ACL (`ls -lde ~/Public` shows it) that macOS
  applies to preserve the standard home layout. Renaming a directory needs the
  `delete` right, so `mv ~/Public …` returns `Permission denied`. **Full Disk
  Access does not help** — all five macOS access layers (POSIX, ACL, TCC, SIP,
  sandbox) must independently approve, and a `deny` ACE wins regardless of FDA.
  Stripping the ACL (`chmod -N`) is *not* recommended: its reversibility and
  side effects are undocumented. `--relocate` detects this and skips the folder
  (nothing copied), so your data is never touched.
- **Use Apple's native feature for Desktop + Documents.** The only supported way
  to put these in iCloud is *System Settings → [your name] → iCloud → iCloud
  Drive → "Desktop & Documents Folders"* (both move together; it's
  FileProvider-backed, not a symlink you can imitate).
- **Music / Movies / Pictures / Public have no folder-level iCloud option.**
  Leave them local. Use the **Photos app** (iCloud Photos) and **Apple Music**
  for the two that have app-native cloud; the rest stay on local disk.
- 🚩 **iCloud "Optimize Mac Storage" is a dataloss footgun for this tool.** With
  it on, iCloud evicts local files to invisible *dataless placeholders* — and
  copying a placeholder with `rsync`/`cp` (what `--relocate` uses) moves an
  **empty stub**, losing the real data. Evicted files are also invisible to Time
  Machine and Spotlight. **Turn off "Optimize Mac Storage"** (or right-click →
  "Keep Downloaded") before relocating anything out of an iCloud path.

**Net:** on macOS the symlink-relocate model is correct for the *non-special*
dirs (`Projects`, `Templates`, and any custom folders with no `deny delete`
ACL); for the protected home folders, use Apple's native iCloud feature instead.
The model is fully portable on Linux/XDG, where these ACLs don't exist.

---

## Development

```sh
make lint       # shellcheck bin/*.sh hooks/pre-commit tests/*.sh (honors .shellcheckrc)
make test       # sandboxed smoke checks — never touches the real $HOME
make install    # chmod +x + wire hooks/pre-commit into .git/hooks (idempotent)
make version    # print the version string from VERSION
```

The pre-commit hook (committed at `hooks/pre-commit`) runs `make lint` and blocks
any commit that fails shellcheck. It is **not** active until you run
`make install` once after cloning.

> **Testing `--apply` manually:** `cloud-xdg-provision.sh --apply` creates
> symlinks under the real `$HOME`. To test without touching your home directory,
> override `HOME` explicitly:
> ```sh
> mkdir -p /tmp/xdg-test-home && HOME=/tmp/xdg-test-home \
>   /bin/bash bin/cloud-xdg-provision.sh --cloud-root /tmp/xdg-test-cloud --apply
> ```
> `make test` does this automatically (sandboxed `HOME` per ADR §10).

## License

[MIT](LICENSE) © 2026 Pipulate.
