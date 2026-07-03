# Research: `xdg-tui` offload manager (PREPARE phase)

> PACT Prepare-phase research for the Python/curses TUI that wraps
> `bin/cloud-xdg-provision.sh`. Resolves the 6 unchecked research items in
> `docs/plans/tui-offload-manager-plan.md`. **Analysis + machine probes only — no
> implementation code.** Structure: each section is finding → evidence → decision → open risk.
>
> Machine probed: macOS 15.7.8 (Darwin 24.6.0, x86_64), 2026-07-03. This machine has
> Xcode CLT installed and `python3` resolving to a venv (`/Users/administrator/pyenv/bin/python3`,
> Python 3.9.6). Truly-stock-macOS and Termux claims are knowledge-based and flagged as such.

## Executive Summary

All six PREPARE items resolve in favor of the plan's recommendations, with three
refinements worth ARCHITECT attention:

1. **curses is GO** on both the venv python and the stock `/usr/bin/python3` on this
   machine (import + `setupterm` + `cup`/`smcup`/`civis` all succeed). Recommend **stdlib
   curses, no ANSI fallback for v1** (curses-required is acceptable; a fallback doubles the
   render surface for a ~15-row dashboard). Termux remains the only unverified platform.
2. **The launcher's python3 detection must be a functional probe, not just
   `command -v`** — stock macOS `/usr/bin/python3` is a CLT shim that exists on `PATH` but
   pops a GUI installer (and fails) when CLT is absent. Probe with `python3 -c 'import
   curses'` so both "python missing" and "curses missing" fail into the same guidance message.
3. **The Ctrl-C-mid-apply spec has one non-obvious crux**: the TUI must install a no-op
   SIGINT *handler*, **never `SIG_IGN`**. `SIG_IGN` is inherited across `exec` and would
   neutralize the child bash's `trap on_signal INT`, defeating the script's recovery + lock
   release. A *handled* signal resets to `SIG_DFL` on exec (POSIX), so the child's trap works.

Porcelain: freeze `porcelain=1` + pipe-delimited `class|canonical|localName|state|remote|git`
with per-command enum sets enumerated below. `--icloud-status` and `--reclaim` get **no
porcelain in v1** (verbatim panes). The "inconsistent" state is **derived in the TUI** by
merging the two porcelain streams, keeping the bash change a faithful mirror.

---

## 1. Python availability matrix + launcher detection

### Finding
`python3` presence is reliable on Debian, unreliable on stock macOS (CLT shim), and absent
by default on Termux. Presence on `PATH` (`command -v`) does not prove python3 actually runs.

### Evidence
- **This machine (macOS 15.7.8, CLT installed):** `command -v python3` →
  `/Users/administrator/pyenv/bin/python3`; `/usr/bin/python3 --version` → `Python 3.9.6`;
  `xcode-select -p` → `/Library/Developer/CommandLineTools`. So here both the venv and the
  stock interpreter work.
- **Stock macOS (no CLT), knowledge-based:** `/usr/bin/python3` is an Apple stub that, on
  first invocation without CLT, opens the GUI "Install Command Line Tools" dialog and exits
  non-zero. `command -v python3` **succeeds** (the stub is on `PATH`) but running it does not
  yield a usable interpreter. Prior agent-memory (`tui-stack-stock-availability`) records this
  as "NOT dependable."
- **Debian/Ubuntu:** `python3` preinstalled (part of base). Reliable.
- **Termux:** no python in base; `pkg install python` (~60 MB pulls Python + its own curses/
  ncurses). Knowledge-based, not device-verified.

| Platform | `python3` on PATH | Actually runnable | Install path |
|----------|-------------------|-------------------|--------------|
| macOS + CLT | yes | yes | `xcode-select --install` (already done here) |
| macOS stock (no CLT) | yes (shim) | **no** — GUI prompt, non-zero | `xcode-select --install` |
| Debian/Ubuntu | yes | yes | `sudo apt install python3` (usually present) |
| Termux | no | no | `pkg install python` |

### Decision
Launcher (`bin/xdg-tui`, bash 3.2) does a **functional probe**, not a bare `command -v`.
Draft (bash-3.2-safe: no `[[ ]]`, `cd … && pwd -P` instead of `readlink -f`, `<<'EOF'` heredoc):

```bash
#!/bin/bash
# xdg-tui — launcher. Finds a working python3 (stdlib only), else prints guidance.
set -eu
dir="$(cd "$(dirname "$0")" && pwd -P)"

# Functional probe: proves python3 RUNS *and* curses imports in one shot. On stock
# macOS without CLT this triggers Apple's own installer (the correct install path) and
# fails through to the message below. </dev/null so the probe never blocks on stdin.
if python3 -c 'import curses, sys; sys.exit(0)' </dev/null >/dev/null 2>&1; then
  exec python3 "$dir/xdg-tui.py" "$@"
fi

cat >&2 <<'EOF'
xdg-tui needs python3 with the stdlib `curses` module (no pip packages required),
which was not found or failed to run. Install python3, then re-run xdg-tui:

  macOS         xcode-select --install     # installs /usr/bin/python3
  Debian/Ubuntu sudo apt install python3    # usually already present
  Termux        pkg install python

EOF
exit 127
```

Notes for ARCHITECT/CODE:
- Probe imports `curses` (not just `import sys`) so a python build lacking curses fails into
  the same message — one failure path, not two.
- On stock macOS the probe *may* surface Apple's GUI CLT installer. That is acceptable and
  intentional: it is Apple's supported install route, and the text still points at the
  non-GUI `xcode-select --install`.
- Exit `127` (command-not-found convention). The script's own exit taxonomy (0/1/130) is
  unaffected — the launcher is upstream of it.
- `exec` replaces the launcher process so signals/exit codes pass straight through to python.

### Open risk
- **[LOW]** Termux `pkg install python` bundles its own curses; unverified on-device (see §2).
- **[LOW]** A machine with a broken/renamed `python3` but working `python3.11` won't be
  found. Acceptable for v1 — `python3` is the universal name; document it.

---

## 2. curses go/no-go + ANSI fallback decision

### Finding
stdlib `curses` imports and initializes term capabilities cleanly on this machine, on both
the venv and stock interpreters, using a read-only `setupterm` probe (no `initscr`, so this
session's terminal was never taken over).

### Evidence (read-only probes, no screen takeover)
- venv `python3`: `import curses` → OK, `curses.version` → `b'2.2'`; `curses.setupterm()` →
  OK; `tigetstr('cup')`, `('smcup')`, `('civis')` all truthy (cursor-move, alt-screen,
  cursor-hide caps present). `TERM=tmux-256color`.
- stock `/usr/bin/python3`: `import curses` → OK (`b'2.2'`); `curses.setupterm()` → OK.
- No `initscr()` was called in-session, per the instruction to avoid taking over this tty.

### Decision
- **Use stdlib `curses`.** Confirmed working; zero pip deps preserves the toolkit's
  low-dependency identity. Matches the plan and the ARCHITECT recommendation.
- **No plain-ANSI fallback renderer for v1. curses-required is acceptable.** Rationale: the
  dashboard is ~15 static rows with simple j/k/enter/q navigation; a second ANSI renderer
  doubles the UI surface (and its test burden) to guard a case (curses missing but python
  present) that is rare — the launcher's probe already imports curses, so "python present but
  curses absent" fails at launch with guidance rather than silently. If Termux later proves
  curses-hostile, an ANSI fallback becomes a v2 item, not a v1 blocker.
- **Termux assumption:** `pkg install python` provides curses linked against Termux's own
  ncurses + terminfo; curses apps (e.g. `python -m venv`-adjacent tools, ipython) are known to
  work under Termux. Treat as **assumed-GO, flagged for the P2 manual on-device pass** per the
  plan. If it fails, the failure is visible (curses raises at `initscr`), not silent.

### Open risk
- **[MEDIUM]** Termux curses/terminfo unverified on-device. Mitigation: P2 manual matrix pass;
  the no-fallback decision means a Termux curses failure is a clean launch-time error, not a
  garbled screen. Revisit ANSI fallback only if Termux fails.
- **[LOW]** `setupterm` succeeding ≠ `initscr` succeeding under every `TERM`. Very low risk on
  xterm/tmux/linux terms; `curses.wrapper()` guarantees `endwin` on any init failure.

---

## 3. Porcelain spec finalization

### Finding
The two read-only commands produce **disjoint, fully enumerable** state sets. A single
6-field schema serves both if each command populates only the fields it computes. The
plan's "inconsistent" state is not produced by either command today and should be **derived
in the TUI** rather than added to the bash, keeping the porcelain a faithful mirror.

### Evidence — every reachable state, walked from code

**`cmd_classify` → `classify_one`** (`bin/cloud-xdg-provision.sh:1021-1042`), runs over
`CLOUDXDG_KEYS` (class `xdg`), `CODE_KEYS` (class `code`), `LOCAL_KEYS` (class `local`).
For `target="$HOME/$name"`:

| Code branch | Human string | Porcelain `state` |
|-------------|--------------|-------------------|
| `[ -L target ]` | `symlink -> <readlink>` | `symlink` (target → `remote` field) |
| `[ -d target ]` | `local dir` | `localdir` |
| else | `absent` | `absent` |
| extra advisory (code-class symlink only) | `(cloud-symlinked; restore … --migrate-projects)` | not a row — set a `git`-column flag or omit; see decision |

`classify_one` returns early on an empty row (`[ -n "$row" ] || return 0`) — unknown keys
emit nothing.

**`cmd_offload_status`** (`:1063-1093`), runs over `CODE_KEYS` only. For each,
`sf="$XDG_STATE_HOME/xdg-cloud/offloaded/$k"`:

| Code branch | Human string | Porcelain `state` | `remote` | `git` |
|-------------|--------------|-------------------|----------|-------|
| `[ -f sf ]` | `offloaded -> <remote>` | `offloaded` | remote (or `<unknown remote>` if unparsed) | (empty) |
| local, git tree, dirty | `local (git: dirty)` | `local` | (empty) | `dirty` |
| local, git tree, clean | `local (git: clean)` | `local` | (empty) | `clean` |
| local, `! -e target` | `local (absent)` | `absent` | (empty) | `none` |
| local, exists, not git | `local` | `local` | (empty) | `none` |

Note the asymmetry: offload-status reports `offloaded` **purely on state-file presence**; it
never checks whether the local dir still exists. So a state file **plus** a populated local
dir (the "inconsistent" case) renders as plain `offloaded` here, while `classify` renders the
same dir as `localdir`. That divergence is exactly what lets the TUI detect inconsistency.

Registry facts (from `bin/lib/xdg-common.sh`): `field() { … cut -d'|' -f"$2"; }` (pipe is the
existing delimiter), `CODE_KEYS="repos androidstudio projects"`,
`CLOUDXDG_KEYS="desktop documents downloads music pictures videos public templates"`,
`LOCAL_KEYS="pyenv applications syslog qemu"`.

### Decision — frozen schema

```
porcelain=1
class|canonical|localName|state|remote|git
```

- **Line 1 is the version header** (literal `porcelain=1`), emitted by both commands before
  any rows. The TUI refuses any first line != `porcelain=1` (fail-fast on drift).
- **Rows are pipe-delimited, exactly 6 fields**, one per registry entry.
- **Field semantics + enums:**
  - `class` ∈ `xdg | code | local`
  - `canonical` — the registry key (e.g. `repos`). The TUI **always** addresses actions by
    this, never the local name (matches `resolve_code_target` accepting key or name).
  - `localName` — platform local dir name (`local_name` output).
  - `state`:
    - from **`--classify --porcelain`**: `symlink | localdir | absent`
    - from **`--offload-status --porcelain`**: `offloaded | local | absent`
  - `remote`: symlink target (classify, `symlink` state) OR offload remote (offload-status,
    `offloaded` state); else empty.
  - `git` (offload-status only): `clean | dirty | none`; empty from classify.
- **Extend by appending fields only** (never reorder/insert) so `porcelain=1` stays stable;
  a genuinely breaking change bumps to `porcelain=2`.
- **Documented assumption:** no `|` in canonical keys, local names, or remote strings (true
  for the fixed registry + rclone `remote:path` forms). The porcelain branch must **not**
  emit rows for entries containing `|` — or the ARCHITECT picks a NUL/`\t` alt if any remote
  can contain `|`; pipe is safe for the current fixed set.

**Inconsistent state — derive in the TUI, do not add bash logic.** The TUI parses both
streams, keys by `canonical`, and derives `inconsistent` when `classify.state == localdir`
**and** `offload-status.state == offloaded`. This keeps the bash change a pure, golden-testable
mirror of existing output and honors "the TUI adds no validation of its own" — it only renders
the join of two facts the script already reports. (Alternative: add an `-e target` check to
the offload-status porcelain branch to emit `inconsistent` directly. Rejected for v1: it adds
new bash behavior beyond mirroring, widening the golden-test surface and the data-loss-adjacent
code. Flag for ARCHITECT to ratify.)

**cloud-symlinked advisory:** the code-class `--migrate-projects` hint is advisory, not a
state. Recommend surfacing it as a derived TUI note when `class==code && state==symlink`
(the TUI already has enough from the row) rather than adding a 7th porcelain field.

### `--icloud-status` porcelain: NOT for v1

`cmd_icloud_status` (`:1796-1814`) output is **per-file**, not per-registry-entry:
`printf '  %-12s %-14s %-24s %s\n'` over every file under the path — columns
`ubi(in-icloud|local?) | dataless|materialized | uploaded|not-uploaded|unknown(...) | <path>`,
variable row count. This is a file listing, structurally unlike the registry dashboard. The
TUI needs it only as informational text. **Decision: verbatim scroll pane, no porcelain branch
for `--icloud-status` in v1.** Same reasoning applies to `--reclaim` (long prose dry-run plan
→ verbatim pane). Both defer a porcelain branch to a future slice if a parsed table is ever
wanted.

### Open risk
- **[MEDIUM]** If ARCHITECT prefers script-side `inconsistent`, the offload-status porcelain
  branch grows an `-e` check — re-scope the golden tests accordingly. Decision above defers it.
- **[LOW]** `<unknown remote>` (malformed state file) contains a space but no `|` — safe in
  the `remote` field; the TUI should render it verbatim, not treat it as an error.

---

## 4. rclone `--progress` non-tty behavior + terminal handover

### Finding
The offload/hydrate lanes call rclone **with `--progress`** (verified). `--progress` renders
a live, in-place-updating display using terminal control codes and is meant for an interactive
tty. Piped/redirected (non-tty) it degrades to non-interactive output and the live bar is
useless — which is precisely why the child must own the real tty.

### Evidence
- `bin/cloud-xdg-provision.sh:1283` — `run rclone copy --immutable "$container" "$dest"
  --progress` (offload); `:1331` — `run rclone copy --checksum "$remote" "$container"
  --progress` (hydrate). Both go through `run` (prints `%q`-quoted, executes under `--apply`).
- `:1285`, `:1303`, `:1332` — `rclone check --download --one-way …` is the independent
  read-back gate (not `--progress`); its stderr on failure is the guard message.
- rclone behavior (knowledge + rclone docs): `--progress`/`-P` uses terminal escape sequences
  for the updating stats block; when stdout is **not** a terminal it does not render the live
  block usefully (falls back to periodic/again-non-interactive logging governed by `--stats`).
  Capturing it through a pipe yields garbled or absent progress and risks the executor's own
  "drain completely or SIGPIPE-141" hazard called out in the plan's ARCHITECT seam.
- `rclone version` on this machine: `v1.74.3` (darwin). rclone is present and the offloaded
  lane's precondition (`rclone_remote_exists`) is real.

### Decision
**Terminal handover is the correct call, and it is mandatory (not optional) for the
`--apply` path** because the wrapped commands use `--progress`:
1. Before an `--apply` action, the TUI leaves curses (`curses.endwin()` / exit the
   `wrapper`-managed screen) and restores a sane tty (`stty sane` equivalent) so the child
   inherits a normal cooked terminal.
2. The child (`cloud-xdg-provision.sh … --apply`) runs with stdin/stdout/stderr = the real
   controlling tty (inherit fds — do **not** pipe). rclone `--progress`, the script's guard
   refusals, and the `cleanup_handler` recovery text all render natively.
3. TUI records rc, prints "exit N — press Enter", re-initializes curses, refreshes status.

For the **read-only** porcelain calls (`--classify/--offload-status --porcelain`) the executor
*does* capture stdout+stderr via pipes — those are small, bounded, non-`--progress` outputs;
drain both fully (never close early) per the plan's SIGPIPE note.

### Open risk
- **[LOW]** If a future lane pipes a `--progress` rclone call by mistake, progress breaks +
  SIGPIPE risk. Mitigation: the executor has exactly two modes (capture for read-only porcelain;
  handover for `--apply`); the `--apply` mode must be the only one used for offload/hydrate/
  reclaim/icloud-download/evict.

---

## 5. Ctrl-C-mid-apply semantics spec

### Finding
The script already handles SIGINT correctly on its own: `trap on_signal INT TERM` →
`cleanup_handler` (prints state-aware recovery, releases the lock) → `exit 130`. The TUI's
only job is to (a) not die on the shared Ctrl-C and (b) not poison the child's trap. The
crux: **use a no-op SIGINT *handler*, never `signal.SIG_IGN`.**

### Evidence — the script's signal path
- `install_cleanup_trap` (`:288-291`): `trap cleanup_handler EXIT`; `trap on_signal INT TERM`.
  Armed by `begin_mutating_mode` before `acquire_lock`.
- `on_signal` (`:279-282`): runs `cleanup_handler`, then `exit 130`. The comment (`:273-278`)
  is explicit that a bare trap would *resume* the interrupted code and falsely report success,
  so it exits 130 deliberately.
- `cleanup_handler` (`:232-271`): flag-gated. `OFFLOAD_ACTIVE` window (`:244-250`) prints
  "INTERRUPTED mid-offload-drop — your data is SAFE … cloud copy (read-back-verified) … local
  may be partially removed. Re-run --offload/--hydrate." `LOCK_OWNED` branch (`:267-270`)
  `rmdir "$LOCK_DIR"` on every exit path. The offload drop window sets `OFFLOAD_ACTIVE=1`
  only *after* the read-back verify passes (`:1287-1297`), so an interrupt during the rclone
  copy (before the drop) leaves the local container fully intact and no OFFLOAD_ACTIVE message
  — the container is simply still `local`.
- `LOCK_DIR="$XDG_CACHE_HOME/cloud-xdg-provision.lock"` (`:311`), an mkdir lock.

### The crux — SIG_IGN vs a no-op handler (POSIX exec semantics)
- `exec(2)`: signals set to be **caught** in the parent are reset to **`SIG_DFL`** in the
  new image; signals set to **`SIG_IGN`** remain **ignored**.
- bash: "signals ignored on entry to a non-interactive shell cannot be trapped or reset." So
  if the TUI sets `SIGINT → SIG_IGN` before spawning, the child bash inherits SIG_IGN, and its
  `trap on_signal INT` is a **no-op** — no recovery message, and depending on timing the lock
  release still runs via the EXIT trap but the 130/interrupt semantics are lost.
- Therefore the TUI must install a no-op **handler** (`signal.signal(SIGINT, lambda *_: None)`),
  which resets to `SIG_DFL` in the child → bash installs its trap normally → the recovery path
  works. The parent's no-op handler means Python does not raise `KeyboardInterrupt`.
- Python 3.5+ (PEP 475) auto-retries syscalls interrupted by a signal whose handler does not
  raise, so `subprocess.run(...)` with a no-op SIGINT handler will simply wait through the
  Ctrl-C and return the child's real rc (130) — no manual EINTR loop needed.

### Decision — the spec
1. **Foreground, same process group, child owns the real tty.** On `--apply`, TUI leaves
   curses (`endwin`), installs `prev = signal.signal(signal.SIGINT, lambda *_: None)`
   (**not** `SIG_IGN`), then `subprocess.run([...], stdin/stdout/stderr inherited)`.
2. **Ctrl-C is delivered by the tty to the foreground process group.** The child bash runs
   `on_signal → cleanup_handler` (recovery text + `rmdir LOCK_DIR`) and `exit 130`. The parent
   Python's no-op handler swallows its copy of SIGINT; `subprocess.run` returns rc via PEP-475
   auto-retry.
3. **TUI treats rc == 130 as "interrupted by user"** (distinct from rc 1 = die/refusal, rc 0
   = success). It restores `prev` SIGINT handler, re-inits curses, and **refreshes status**
   (re-runs both porcelain reads) so the dashboard reflects reality.
4. **No SIGTERM/SIGQUIT special-casing for v1**; the same no-op-handler discipline applies if
   added.

### What the interrupt test asserts (P1, slow-rclone shim + SIGINT to the child)
Driving the executor with `SHIM` = a slow `rclone` that sleeps mid-copy, send SIGINT to the
child pid (or its pgrp), then assert **the script's own guarantees through the TUI seam**:
- **Child exit code == 130** (surfaced by the TUI as "interrupted", never as success).
- **Lock not wedged:** `$XDG_CACHE_HOME/cloud-xdg-provision.lock` does not exist afterward
  (LOCK_OWNED cleanup ran).
- **Container intact:** the CODE container still exists locally. (Interrupt during the rclone
  copy — before the read-back-gated drop window — leaves it whole; if the interrupt lands in
  the `OFFLOAD_ACTIVE` drop window, the recovery message is present and the cloud copy is
  read-back-verified, so it is recoverable via `--hydrate`.)
- **Status refresh** after the interrupt shows the dir still `local` (copy never completed the
  drop) — i.e. the TUI re-reads porcelain and does not falsely show `offloaded`.
- All under sandboxed `HOME`/`XDG_*` (never the real `$HOME`); the child must inherit the
  overridden env (env-injection is a design requirement, per the plan's T2 containment rule).

The test targets the executor seam directly (integration), asserting the script's invariants —
it does not re-test the data-loss guards themselves (covered by existing script-level groups).

### Open risk
- **[HIGH]** If CODE implements the parent-side SIGINT suppression as `SIG_IGN` instead of a
  no-op handler, the child's recovery trap is silently disabled and the interrupt test may
  still pass on the *lock* assertion (EXIT trap releases it) while the *130/recovery* semantics
  are wrong. Call this out explicitly in the ARCHITECT diff-spec and cover it with a test that
  asserts the child's recovery **message** appears, not just lock absence.
- **[LOW]** tmux/screen may intercept some key combos; irrelevant to the SIGINT path (tty
  driver, not the multiplexer, delivers `^C`).

---

## 6. Python lint/test tooling gate

### Finding
The repo is deliberately dependency-light (Makefile ADR Decision 3: "No just/npm/python"),
gated by `make lint` (shellcheck) + `make test` (`tests/smoke.sh`) + a pre-commit hook, no CI.
stdlib `py_compile` and `unittest` are always present with any python3; `ruff`/`pytest` are
not (this machine has a venv `pytest` but no `ruff`, and neither is guaranteed on target
machines).

### Evidence
- `python3 -m py_compile --help` and `python3 -m unittest --help` both work on this machine
  (stdlib, no install).
- `command -v ruff` → not found; `command -v pytest` → venv-only (`/Users/administrator/
  pyenv/bin/pytest`). Neither is a safe assumption on stock macOS / Debian / Termux.
- Repo precedents for graceful skip: `make helper` skips cleanly with no `swiftc`; the offload
  lane's `require_code_rclone` and smoke tests skip when `rclone` is absent. Same idiom applies.

### Decision
**stdlib-only, with graceful runtime-absent skip.** Mirror the `command -v … || skip`
precedent. Exact Makefile step shapes (bash-3.2-safe; `command -v` guard; recipe lines are tab-
indented in the real file):

```make
# lint: byte-compile the TUI as the python "lint" (syntax + import-time errors).
# Skips cleanly where python3 is absent (Termux without pkg install python, stock mac no CLT).
lint:
	shellcheck bin/*.sh hooks/pre-commit tests/*.sh
	@if command -v python3 >/dev/null 2>&1; then \
	  echo "py_compile bin/xdg-tui.py tests/tui/*.py"; \
	  python3 -m py_compile bin/xdg-tui.py tests/tui/*.py; \
	else \
	  echo "python3 not found — skipping TUI byte-compile (install python3 to lint the TUI)"; \
	fi

# test: existing smoke suite + stdlib unittest discovery for the TUI core.
test:
	tests/smoke.sh
	@if command -v python3 >/dev/null 2>&1; then \
	  python3 -m unittest discover -s tests/tui -p 'test_*.py'; \
	else \
	  echo "python3 not found — skipping TUI unit tests (install python3 to run them)"; \
	fi
```

Rationale:
- `py_compile` is a real, zero-dependency lint: it catches syntax errors and (with a light
  import in the test module) import-time breakage. No `ruff` dependency to justify against ADR
  Decision 3.
- `unittest discover` is the stdlib runner — the plan's Python tests are already specified as
  `unittest`. No `pytest` dependency.
- Both steps `|| skip` (via the `command -v` guard) so a machine without python3 still passes
  `make lint`/`make test` — the toolkit's shell parts remain gated exactly as today.
- **ADR note (deliverable, not optional):** adding *any* python step touches Decision 3 ("No
  … python"). The ARCHITECT's ADR amendment must record: the TUI is an *optional companion*
  invoked only via `bin/xdg-tui`, its python steps are skip-guarded, and the shell toolkit
  remains python-free. This keeps the amendment narrow.

### Open risk
- **[LOW]** `unittest discover` returns non-zero if `tests/tui/` has zero test files at an
  intermediate slice — order the CODE slices so the directory has at least one test when the
  Makefile step lands (Slice 1 adds core + tests together, per the plan).
- **[LOW]** If a later slice genuinely needs `pytest` fixtures, add it as an *optional* second
  branch (`command -v pytest && pytest … || python3 -m unittest …`), never a hard dep.

---

## Dependencies mapped (confirmations for ARCHITECT)

- **Exit-code contract:** 0 success / 1 `die` / 130 interrupt — no finer taxonomy. Refusals
  are stderr text the TUI relays verbatim. (`on_signal` → 130; `die` → 1; confirmed.)
- **State files** `$XDG_STATE_HOME/xdg-cloud/offloaded/<canonical>` (`remote=` line) are an
  **internal** contract; the TUI must **not** read them — it reads porcelain only. (offloaded
  state surfaces via `--offload-status --porcelain`.)
- **Lock:** `$XDG_CACHE_HOME/cloud-xdg-provision.lock` (mkdir lock, released by
  `cleanup_handler` LOCK_OWNED branch). The TUI never touches it; serial one-op-at-a-time is
  the only honest mode.
- **Action addressing:** always canonical key (`resolve_code_target` accepts key or local
  name; key is unambiguous). `CODE_KEYS="repos androidstudio projects"` are the only
  offload/hydrate-eligible entries; `resolve_code_target` `die`s on anything else.
- **Consent friction:** `--icloud-evict` requires `--i-understand-data-loss-risk`
  (`ICLOUD_CONFIRM`, `:1841-1843`) AND the compiled upload-state helper (`:1838`). The TUI's
  typed-consent gate must gate *its own* passing of `--i-understand-data-loss-risk`; it must
  not weaken the script's separate helper/upload gates.

## Reasoning chain

1. The TUI is a strict wrapper, so every risky guarantee already lives in the script; PREPARE's
   job is to confirm the seams (data contract, tty handover, interrupt) don't erode those
   guarantees — not to design new safety.
2. **Data contract:** human output drifts and state files are internal → porcelain. Walking
   `classify_one` + `cmd_offload_status` gives a *closed* enum set, so the schema can be
   frozen and golden-tested; the two commands' disjoint views of the same code dir are what
   make "inconsistent" derivable without new bash — so the bash change stays a faithful mirror
   (smallest, safest diff).
3. **tty handover** is forced (not merely nice) because the wrapped rclone calls use
   `--progress`, which needs a real terminal; capturing would both garble progress and risk
   SIGPIPE — so the executor must have two clean modes (capture small porcelain; hand over for
   `--apply`).
4. **Interrupt:** the script already exits 130 with recovery + lock release, so the TUI must
   only avoid two failure modes — dying on the shared Ctrl-C, and poisoning the child's trap.
   POSIX exec semantics make the fix specific: a no-op *handler* (resets to SIG_DFL on exec,
   trap survives) not `SIG_IGN` (inherited, trap dies). This single distinction is the whole
   interrupt spec's crux and the highest-value finding for CODE/TEST.
5. **Availability + tooling** both resolve to "probe functionally, skip gracefully" — the same
   `command -v … || skip` idiom the repo already uses for rclone/swiftc — so the python
   dependency never breaks the shell toolkit's existing gates, keeping the ADR amendment narrow.

## References
- `bin/cloud-xdg-provision.sh`: `classify_one`/`cmd_classify` (1021-1061),
  `cmd_offload_status` (1063-1093), `cmd_offload` drop window (1283-1311),
  `cmd_hydrate` (1313+), `cmd_icloud_status` (1796-1814), `cmd_icloud_evict` gates
  (1833-1865), `cleanup_handler`/`on_signal`/`install_cleanup_trap` (200-291),
  `acquire_lock`/`LOCK_DIR` (309-311), arg parsing (438-487), `print_version` (414).
- `bin/lib/xdg-common.sh`: `field` (29), `CLOUDXDG_KEYS` (101), `CODE_KEYS`/`LOCAL_KEYS`
  (159-161), `home_class`/`is_machine_local` (176-187).
- `docs/plans/tui-offload-manager-plan.md` (approved plan, ARCHITECT/TEST sections).
- Machine probes (macOS 15.7.8, 2026-07-03): python3 (venv 3.9.6 + stock /usr/bin), curses
  `setupterm` caps, rclone v1.74.3, `command -v ruff/pytest`.
- Agent memory: `tui-stack-stock-availability` (stock availability matrix, CLT-shim behavior).
- POSIX `exec(2)` signal-disposition semantics; bash "ignored-on-entry cannot be trapped";
  Python PEP 475 (EINTR auto-retry).
