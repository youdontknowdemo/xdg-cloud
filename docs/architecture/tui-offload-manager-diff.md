# `xdg-tui` Architecture Spec (TUI offload manager)

**Phase:** PACT Architect · **Status:** CODE gate — both coders build exactly what this document specifies.
**Upstream:** approved plan `docs/plans/tui-offload-manager-plan.md` (user-locked: registry dashboard,
Python stdlib curses, all file-management lanes incl. reclaim + iCloud with typed-consent evict;
dotfiles + default provision lane excluded) and PREPARE research
`docs/preparation/research-tui-offload-manager.md` (porcelain=1 schema, functional probe launcher,
no-op-SIGINT-handler contract, stdlib-only tooling — all adopted here).
**Companion amendment:** ADR §Decision 3 (see §10 — exact text; applied by the lead, not by coders).

---

## 0. What `xdg-tui` is (prime directive: wrap, don't bypass)

`xdg-tui` is an **optional, strict-wrapper TUI** over `bin/cloud-xdg-provision.sh`. Every action is a
normal per-invocation run of the provision script (dry-run preview → explicit confirm → `--apply`), so
the script's guards — lock, not-root, degenerate-path refusal, master trap, read-back verify, evict
gates — remain the **sole enforcement layer**. The TUI adds UX, never policy:

- It never reads state files (`$XDG_STATE_HOME/xdg-cloud/offloaded/*`) or the lock dir — internal contracts.
- It never validates or "helpfully fixes" anything the script refuses — refusals render **verbatim**.
- It builds argv only from canonical registry keys and `$HOME/<localName>` joins — no free-text paths in v1.
- Consent friction is **preserved**, never eroded: evict requires a typed acknowledgment (§6).

Two new data seams make this possible: a versioned `--porcelain` output mode on the two read-only
report commands (§2), and a two-mode executor (capture vs terminal-handover) in the Python side (§4).

---

## 1. Files touched + S2 partition (zero shared files)

| File | Change | Owner (CODE) |
|---|---|---|
| `bin/cloud-xdg-provision.sh` | `PORCELAIN` config var; `--porcelain` modifier flag + post-parse guard; `porcelain_classify_row` helper; porcelain branches in `cmd_classify` + `cmd_offload_status`; `usage()` line | **devops-coder** |
| `bin/xdg-tui` (new, no `.sh`, `chmod +x`) | bash-3.2 launcher: functional python3+curses probe, exit-127 guidance, `exec` | **devops-coder** |
| `Makefile` | launcher added to shellcheck target; skip-guarded `py_compile` + `unittest` steps | **devops-coder** |
| `tests/smoke.sh` | new porcelain golden group (P-group, §8.3) | **devops-coder** |
| `.gitignore` | `__pycache__/` (py_compile artifacts) | **devops-coder** |
| `bin/xdg_tui.py` (new, `chmod +x` optional — launched via `python3`) | the TUI: pure core + executor + curses loop, `--dump`, `--version` | **backend-coder** |
| `tests/tui/test_parse.py`, `test_model.py`, `test_plan.py`, `test_interpret.py`, `test_executor.py` (new) | stdlib `unittest` suites for the pure core + executor seams | **backend-coder** |
| `docs/architecture/xdg-cloud-adr.md` | Decision 3 amendment §10 — **lead applies verbatim** (keeps coder file sets disjoint) | lead |
| `README.md`, `CHANGELOG.md` | polish slice — deferred to TEST-phase/lead commits | lead |
| `bin/lib/xdg-common.sh`, `bin/home-tree.sh` | **untouched** | — |

> **Naming divergence from the plan (deliberate):** the plan says `bin/xdg-tui.py`; this spec uses
> **`bin/xdg_tui.py`**. A hyphenated filename is not an importable Python module name, which would force
> every test file through `importlib.util.spec_from_file_location` gymnastics. With the underscore,
> tests do one `sys.path.insert(0, <repo>/bin)` and `import xdg_tui`. The user-facing command name is
> unchanged — users run `bin/xdg-tui` (the launcher).

**S2 rule for CODE:** devops-coder owns all bash + build files; backend-coder owns all python files.
The porcelain golden tests (bash, smoke.sh) land **before or with** the python parser so the contract
is frozen first. The only cross-dependency is the §2.6 golden format itself — both coders build against
this document, not against each other's files.

---

## 2. Bash slice — `--porcelain` (exact bodies)

### 2.1 Config var (with the other modifier defaults, after `OFFLOAD_ASIDE=0`, ~L88)

```sh
PORCELAIN=0        # 1 = machine-readable output for --classify/--offload-status (--porcelain)
```

### 2.2 Flag parse (modifier arm, placed with `--aside`/`--fast-verify`, NOT a `set_mode` lane)

```sh
    --porcelain)          PORCELAIN=1 ;;
```

### 2.3 Post-parse guard (immediately after the `case "$STYLE" …` check, ~L489)

```sh
# --porcelain is a MODIFIER (like --aside), valid only on the two read-only report
# modes. Fail loud on misuse so callers never silently get human-format output.
if [ "$PORCELAIN" -eq 1 ]; then
  case "$MODE" in
    classify|offload-status) : ;;
    *) die "--porcelain applies only to --classify or --offload-status" ;;
  esac
fi
```

### 2.4 `usage()` addition (in the read-only report section)

```
  --porcelain               Machine-readable output for --classify/--offload-status:
                            a 'porcelain=1' version header, then pipe-delimited rows
                            class|canonical|localName|state|remote|git. Fields are only
                            ever APPENDED within version 1; breaking changes bump the header.
```

### 2.5 Porcelain emitters (exact bodies)

New helper, placed directly after `classify_one` (~L1042). It mirrors `classify_one`'s branch logic
exactly and emits **no** advisory second line (the TUI derives the migrate-projects hint from
`class==code && state==symlink`):

```sh
# Emit ONE porcelain row for --classify: class|canonical|localName|state|remote|git.
#   $1 = class label (xdg|code|local), $2 = a 'canonical|mac|lin|…' registry-style row.
# States: symlink|localdir|absent. remote = readlink target for symlink, else empty.
# git is ALWAYS empty from classify (offload-status owns that field). Mirrors
# classify_one's branches exactly; no human header, no advisory lines.
# canonical/localName come from the fixed pipe-delimited registries, so they can
# never contain '|'; a symlink TARGET is arbitrary, so a pipe-containing target is
# sanitized to a fixed placeholder rather than corrupting the row (or dropping it).
porcelain_classify_row() {
  local class row canonical name target state remote
  class="$1"; row="$2"
  [ -n "$row" ] || return 0                 # unknown key — emit nothing (mirror classify_one)
  canonical="$(field "$row" 1)"
  name="$(local_name "$(field "$row" 2)" "$(field "$row" 3)")"
  target="$HOME/$name"
  state="absent"; remote=""
  if [ -L "$target" ]; then
    state="symlink"
    remote="$(readlink "$target")"          # readlink (no -f) on a known symlink
    case "$remote" in *"|"*) remote="<non-porcelain-target>" ;; esac
  elif [ -d "$target" ]; then
    state="localdir"
  fi
  printf '%s|%s|%s|%s|%s|\n' "$class" "$canonical" "$name" "$state" "$remote"
}
```

`cmd_classify` gains a porcelain branch at the top; the human path below it is **byte-unchanged**:

```sh
# --classify: classify every known top-level ~/ entry. Read-only.
cmd_classify() {
  local k
  if [ "$PORCELAIN" -eq 1 ]; then
    printf 'porcelain=1\n'
    # shellcheck disable=SC2086   # intentional word-split of the space-separated key lists
    for k in $CLOUDXDG_KEYS; do porcelain_classify_row xdg   "$(registry_row "$k")"; done
    # shellcheck disable=SC2086
    for k in $CODE_KEYS;     do porcelain_classify_row code  "$(code_row "$k")"; done
    # shellcheck disable=SC2086
    for k in $LOCAL_KEYS;    do porcelain_classify_row local "$(code_row "$k")"; done
    return 0
  fi
  … existing body unchanged (log header, classify_one loops, Notes heredoc) …
}
```

`cmd_offload_status` gains the analogous branch; the state/git logic is a **faithful mirror** of the
existing human branches (same conditions, same order), differing only in output format:

```sh
# --offload-status: for each code dir, report offloaded-vs-local. Read-only.
cmd_offload_status() {
  local k state_dir name target sf remote gitout row state gitfield
  state_dir="$XDG_STATE_HOME/xdg-cloud/offloaded"
  if [ "$PORCELAIN" -eq 1 ]; then
    printf 'porcelain=1\n'
    # shellcheck disable=SC2086   # intentional word-split of the space-separated key list
    for k in $CODE_KEYS; do
      row="$(code_row "$k")"
      name="$(local_name "$(field "$row" 2)" "$(field "$row" 3)")"
      target="$HOME/$name"
      sf="$state_dir/$k"
      if [ -f "$sf" ]; then
        # state file present -> offloaded (same 3.2 parse idiom as the human branch;
        # tolerate a malformed/empty file). offloaded is state-file-presence ONLY —
        # deliberately NO '-e target' check here: the porcelain is a faithful mirror,
        # and the TUI derives 'inconsistent' by joining the two streams (§4.2 / §11).
        remote="$(grep '^remote=' "$sf" 2>/dev/null | cut -d= -f2- || true)"
        [ -n "$remote" ] || remote="<unknown remote>"
        case "$remote" in *"|"*) remote="<non-porcelain-remote>" ;; esac
        printf 'code|%s|%s|offloaded|%s|\n' "$k" "$name" "$remote"
      else
        state="local"; gitfield="none"
        if [ -d "$target" ] && git -C "$target" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
          gitout="$(git -C "$target" status --porcelain 2>/dev/null || true)"
          if [ -n "$gitout" ]; then gitfield="dirty"; else gitfield="clean"; fi
        elif [ ! -e "$target" ]; then
          state="absent"
        fi
        printf 'code|%s|%s|%s||%s\n' "$k" "$name" "$state" "$gitfield"
      fi
    done
    return 0
  fi
  … existing body unchanged (log header + human loop) …
}
```

### 2.6 Frozen format + golden outputs (every enum state)

```
line 1:  porcelain=1                      (literal; TUI refuses any other first line)
rows:    class|canonical|localName|state|remote|git      (exactly 6 fields, LF-terminated)
```

- `--classify --porcelain` emits **exactly 15 rows** (8 xdg + 3 code + 4 local, registry order);
  `state ∈ symlink|localdir|absent`; `git` always empty.
- `--offload-status --porcelain` emits **exactly 3 rows** (CODE_KEYS order);
  `state ∈ offloaded|local|absent`; `git ∈ clean|dirty|none` (empty for `offloaded`).
- Version rule: fields are only ever appended within `porcelain=1`; reorder/insert/semantic change
  bumps to `porcelain=2`.

Golden lines (one per reachable enum state — these exact shapes are the smoke-test assertions, §8.3):

```
# --classify --porcelain
xdg|documents|Documents|symlink|/sandbox/cloud/documents|          (symlink; remote = readlink target)
xdg|music|Music|localdir||                                         (plain local dir)
xdg|templates|Templates|absent||                                   (nothing at $HOME/Templates)
code|projects|Projects|symlink|/sandbox/cloud/Projects|            (code-class symlink → TUI shows migrate hint)
code|repos|repos|localdir||
local|pyenv|pyenv|localdir||

# --offload-status --porcelain
code|repos|repos|offloaded|gdrive:xdg-offload/code/repos|          (state file with remote= line)
code|repos|repos|offloaded|<unknown remote>|                       (state file present but malformed)
code|repos|repos|local||clean                                      (git work tree, clean)
code|repos|repos|local||dirty                                      (git work tree, dirty)
code|repos|repos|local||none                                       (dir exists, not a git tree)
code|androidstudio|AndroidStudioProjects|absent||none              (no state file, no dir)
```

---

## 3. Launcher — `bin/xdg-tui` (exact body)

No `.sh` suffix (user-facing command). `chmod +x`. Added **explicitly** to the Makefile shellcheck
target (the `bin/*.sh` glob will not match it).

```bash
#!/usr/bin/env bash
#
# xdg-tui — launcher for the OPTIONAL Python TUI (bin/xdg_tui.py).
#
# bash 3.2. Finds a WORKING python3 with stdlib curses via a FUNCTIONAL probe —
# never a bare `command -v`: stock macOS ships a CLT shim python3 that exists on
# PATH but pops a GUI installer and exits non-zero when CLT is absent. Probing
# `import curses` folds "python missing" and "curses missing" into ONE failure
# path with one guidance message. On failure: guidance to stderr, exit 127.
#
set -euo pipefail

# --- locate self (symlink- and CWD-safe; same idiom as cloud-xdg-provision.sh) ---
__self_src="${BASH_SOURCE[0]}"
while [ -h "$__self_src" ]; do
  __self_dir="$(cd -P "$(dirname "$__self_src")" >/dev/null 2>&1 && pwd)"
  __self_src="$(readlink "$__self_src")"
  case "$__self_src" in
    /*) : ;;                                   # absolute target — use as-is
    *)  __self_src="$__self_dir/$__self_src" ;; # relative — resolve vs link dir
  esac
done
__self_dir="$(cd -P "$(dirname "$__self_src")" >/dev/null 2>&1 && pwd)"

# Functional probe: proves python3 RUNS *and* stdlib curses imports, in one shot.
# </dev/null so the probe can never block on stdin. On stock macOS without CLT this
# may surface Apple's own installer dialog (the supported install route) and then
# fall through to the guidance below.
if python3 -c 'import curses' </dev/null >/dev/null 2>&1; then
  exec python3 "$__self_dir/xdg_tui.py" "$@"
fi

cat >&2 <<'EOF'
xdg-tui needs python3 with the stdlib `curses` module (no pip packages required),
which was not found or failed to run. Install python3, then re-run xdg-tui:

  macOS          xcode-select --install      # installs /usr/bin/python3
  Debian/Ubuntu  sudo apt install python3    # usually already present
  Termux         pkg install python

EOF
exit 127
```

Exit-code posture: 127 = launcher-level "no runnable interpreter" (command-not-found convention);
everything ≥ the python process uses the TUI's own codes; the provision script's 0/1/130 taxonomy is
untouched. `exec` replaces the launcher so signals and exit codes pass straight through.

---

## 4. Python module — `bin/xdg_tui.py` (single file, three-layer seam)

**Single file**, three sections separated by banner comments: `CORE` (pure), `EXECUTOR` (thin,
injectable), `UI` (curses loop). Rationale: one deploy artifact beside the launcher, no package/
`sys.path` machinery at runtime; the seam is enforced by *import discipline*, not file boundaries —
`import curses` appears **only inside the UI entrypoints** (lazy), so the CORE and EXECUTOR are
importable and unit-testable on a python without curses. If the file outgrows ~900 lines in a later
slice, promoting to a package is a v2 refactor, not a v1 concern.

Python floor: **3.9** (stock macOS `/usr/bin/python3` is 3.9.6). No `match`, no `X | Y` annotation
unions, no 3.10+ stdlib APIs.

### 4.1 Skeleton — every public name + signature

```python
#!/usr/bin/env python3
"""xdg-tui — optional curses dashboard wrapping bin/cloud-xdg-provision.sh.

Strict wrapper: every action is a normal dry-run/--apply invocation of the
provision script; the script's guards are the sole enforcement layer.
"""
# stdlib only. NO `import curses` at module top (lazy, inside UI) — the pure
# core + executor must import cleanly on a python without curses.
import os, signal, subprocess, sys

PORCELAIN_VERSION = "porcelain=1"

# ============================== CORE (pure) ==============================
# No tty, no subprocess, no os.environ reads inside these functions — every
# input arrives as a parameter. 100% branch coverage required on gating logic.

class PorcelainError(Exception): ...   # bad header / field count / unknown state

class Row:        # parsed porcelain row (namedtuple or small class)
    """Fields: klass, canonical, local_name, state, remote, git  (all str)."""

class Entry:
    """Joined dashboard entry.
    Fields: klass ('xdg'|'code'|'local'), canonical, local_name,
            classify_state ('symlink'|'localdir'|'absent'),
            offload_state  ('offloaded'|'local'|'absent'|None),   # None for non-code
            git ('clean'|'dirty'|'none'|''), remote (str),
            state (str, derived — see build_model), note (str, advisory)."""

def parse_porcelain(text, source):
    # type: (str, str) -> list  # of Row; source ∈ {"classify", "offload-status"}
    """First line must equal PORCELAIN_VERSION else PorcelainError (fail-fast on
    drift). Each row: exactly 6 pipe-split fields; state must be in the source's
    enum set; unknown state/short row -> PorcelainError carrying the raw line
    (surfaced, never guessed)."""

def build_model(classify_rows, status_rows):
    # type: (list, list) -> list  # of Entry, classify (registry) order
    """Join by canonical. Derivations (render-only, no policy):
    - state = offload_state if the entry is code-class and has a status row,
      else classify_state — EXCEPT:
    - 'inconsistent' when classify_state == 'localdir' AND offload_state ==
      'offloaded' (state file + populated local dir). Render BOTH facts.
    - note = 'cloud-symlinked; restore with --migrate-projects' when
      klass == 'code' and classify_state == 'symlink'."""

def plan_action(target, op, confirmed=False, typed_ack=None):
    # type: (str, str, bool, str) -> list  # argv (script path NOT included)
    """Build argv for one op from the ACTIONS table (§5). target is a canonical
    KEY for offload/hydrate, an ABSOLUTE PATH for reclaim/icloud-*.
    GATES (the P0-tested invariants):
      * '--apply' appears IFF confirmed is True.
      * '--i-understand-data-loss-risk' appears IFF op == 'icloud-evict' AND
        typed_ack == target (exact string equality). Never otherwise, and
        'icloud-evict' with typed_ack != target raises ConsentError — the TUI
        must not even build a preview argv without the typed acknowledgment.
    Unknown op -> ValueError."""

class ConsentError(Exception): ...

def interpret_result(op, rc, out, err):
    # type: (str, int, str, str) -> Outcome
    """Outcome(status, message): rc 0 -> 'ok'; rc 130 -> 'interrupted' (NEVER
    success); rc 1 -> 'refused' (die/guard; message = stderr verbatim);
    other -> 'error'. No stderr parsing beyond pass-through."""

def preview_blocks(out):
    # type: (str) -> bool
    """True if a dry-run preview contains 'WOULD BLOCK' — UX nicety only
    (suppress the confirm prompt); not policy."""

def render_frame(entries, selected, width):
    # type: (list, int, int) -> list  # of str — pure; shared by curses UI and --dump

# ============================ EXECUTOR (thin) ============================

class Executor:
    def __init__(self, script_path, env=None):
        # env=None -> os.environ AT CALL TIME (never cached at import; tests
        # inject a sandboxed env: HOME, XDG_*, PATH-with-shims).
        ...
    def capture(self, argv):
        # type: (list) -> tuple  # (rc, out, err)
        """READ-ONLY calls only (porcelain reads, dry-run previews). Runs
        [script_path]+argv via subprocess.run(capture_output=True, text=True,
        errors='replace') — full drain guaranteed, pipe never closed early
        (SIGPIPE-141 hazard). Never used for anything containing --apply."""
    def handover(self, argv):
        # type: (list) -> int  # rc
        """--apply calls only. Caller has already left curses (endwin). Runs
        the child with INHERITED stdin/stdout/stderr (the real tty — rclone
        --progress, guard refusals, and trap recovery text render natively).
        Installs prev = signal.signal(SIGINT, _sigint_noop) around the run and
        restores prev in a finally. Returns the child's real rc (130 on
        interrupt via PEP-475 auto-retry)."""

def _sigint_noop(signum, frame):   # a HANDLER, never signal.SIG_IGN (§7)
    pass

def default_script_path():
    # type: () -> str
    """$XDG_TUI_SCRIPT if set (test seam), else <dir-of-this-file>/
    cloud-xdg-provision.sh resolved via os.path.realpath(__file__)."""

def read_version():
    # type: () -> str
    """<dir-of-this-file>/../VERSION, first whitespace-delimited token;
    '(version unknown)' on missing/empty — mirrors print_version()."""

# ============================== UI (curses) ==============================

def refresh_model(executor):
    # type: (Executor) -> list  # of Entry
    """capture --classify --porcelain + --offload-status --porcelain,
    parse both, build_model. PorcelainError -> fatal message + exit 1."""

def run_action(stdscr, executor, entry, op):
    """The ONLY mutation path. Sequence per §5 flow column: (typed consent if
    required) -> dry-run preview via capture -> confirm -> curses.endwin() ->
    executor.handover -> 'exit N — press Enter' -> stty-sane reset ->
    curses re-init -> refresh_model."""

def main_tui(stdscr, executor):
    """Thin loop: render(render_frame(...)), getch dispatch:
    j/k/UP/DOWN move · ENTER action menu · r refresh · q quit · ? help ·
    KEY_RESIZE re-render. Installs _sigint_noop for the whole session
    (restores on exit); 'q' is the quit path."""

def dump(executor):
    # type: (Executor) -> int
    """--dump: one render_frame to stdout, no tty, no curses import. rc 0;
    rc 1 with message on PorcelainError."""

def main(argv):
    """--version -> print 'xdg-tui <ver>', rc 0. --dump -> dump(). No args ->
    import curses; curses.wrapper(main_tui, executor). Unknown arg -> usage
    to stderr, rc 1."""

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

### 4.2 RATIFIED: `inconsistent` is TUI-derived (research §3 decision)

**Ratified.** The bash porcelain stays a faithful mirror of what the script already reports; the TUI
derives `inconsistent` from the *join* of two existing facts (`classify` says `localdir`,
`offload-status` says `offloaded`). Rationale: (a) adding an `-e` check to the offload-status
porcelain branch would create a state the human output cannot express — the two output modes of one
command would diverge, which is exactly the drift `--porcelain` exists to prevent; (b) it keeps new
code out of the data-loss-adjacent script and the golden-test surface minimal; (c) it honors
wrap-don't-bypass: rendering the conjunction of two reported facts is display, not validation — the
TUI asserts nothing the script didn't already say. The dashboard renders `inconsistent` showing
**both** underlying facts (`state-file says offloaded · local dir populated`).

### 4.3 Model/UI notes

- Dashboard = 15 classify rows in registry order; the 3 code rows carry the full action set, xdg rows
  carry the three iCloud lanes only (per §6 — reconciled post-review: the implementation follows §6,
  deliberately; the script's resolvers gate applicability), local rows are informational (plus the
  `--migrate-projects` note on code+symlink).
- `local` code entries show the git field (`clean`/`dirty`/`none`); `dirty` renders as a caution
  marker but the TUI does **not** block offload on it — the script's own git guards decide (verbatim
  refusal if they refuse). No color-only encoding (plan accessibility note).
- `--dump` exists so TEST and humans can snapshot a frame without a tty; it shares `render_frame`
  with the curses path, so frame content is unit-testable.

---

## 5. Action/lane registry (data-driven — the `ACTIONS` table in CORE)

| op | argv template (before script path) | target arg | dry-run first | confirm | io mode (apply) |
|---|---|---|---|---|---|
| `offload` | `--offload KEY` (+`--apply`) | canonical key | yes (capture → pane) | `y/N` (default N) | handover |
| `hydrate` | `--hydrate KEY` (+`--apply`) | canonical key | yes (capture → pane) | `y/N` (default N) | handover |
| `reclaim` | `--reclaim PATH` (+`--apply`) | `$HOME/<localName>` of the selected code entry | yes (capture → **verbatim** pane) | `y/N` (default N) | handover |
| `icloud-status` | `--icloud-status PATH` | `$HOME/<localName>` | n/a (read-only) | none | capture → **verbatim** pane |
| `icloud-download` | `--icloud-download PATH` (+`--apply`) | `$HOME/<localName>` | yes (capture → verbatim pane) | `y/N` (default N) | handover |
| `icloud-evict` | `--icloud-evict PATH --i-understand-data-loss-risk` (+`--apply`) | `$HOME/<localName>` | yes — but **after** typed consent (§6) | typed path, then `y/N` | handover |
| *(internal)* `refresh` | `--classify --porcelain` / `--offload-status --porcelain` | — | — | — | capture |

Rules baked into the table (not per-call-site logic):

- **Path args are always** `os.path.join(home, entry.local_name)` computed at call time from the
  executor's env — never free text, never cached at import (§9). The script's own resolvers
  (`resolve_code_target`, `icloud_resolve_under_root`, reclaim's root canonicalization) remain the
  applicability gates; a path they refuse renders as a verbatim refusal in the pane.
- **Key args are always** the canonical registry key (unambiguous for `resolve_code_target`).
- **Reclaim + iCloud panes render captured output verbatim** — no porcelain for these lanes in v1
  (research §3: per-file/prose output, structurally unlike the registry dashboard).
- Every `--apply` goes through **handover** (never capture — rclone `--progress` needs the tty);
  every read-only/dry-run call goes through **capture** with full drain.
- Dry-run preview containing `WOULD BLOCK` → suppress the confirm prompt (`preview_blocks`, nicety).
- Preview rc != 0 → show refusal verbatim, **no** confirm prompt, no apply.
- One op at a time, foreground, serial — the mkdir lock makes this the only honest mode.

---

## 6. Evict typed-consent gate (single-keypress evict is BANNED)

The script's `--i-understand-data-loss-risk` is deliberate consent friction; the TUI must preserve
**equivalent** friction. Note the script checks `ICLOUD_CONFIRM` **before dry-run too** (gate 5 runs
unconditionally), so even the evict *preview* needs the flag — therefore typed consent comes first:

1. User selects a code/xdg entry, chooses `icloud-evict` from the action menu.
2. TUI shows the warning text (mirrors the script's own gate-5 message) and prompts:
   *"Type the full local path (`$HOME/<localName>`) to acknowledge the data-loss risk:"*
3. Input must equal the target path **exactly** (string equality; no trimming beyond the trailing
   newline, no case folding). Mismatch or empty → abort; **no invocation of any kind is made**.
4. On match → `plan_action(path, "icloud-evict", confirmed=False, typed_ack=path)` → dry-run preview
   (capture): `--icloud-evict PATH --i-understand-data-loss-risk`. The script's remaining gates
   (macOS-only, under-CloudDocs, brctl, compiled helper, whole-set upload verification) all run and
   any refusal renders verbatim — the TUI never weakens them.
5. Preview rc==0 → prompt `Evict? (y/N)` default **N** → on `y`, handover apply: same argv + `--apply`.

**P0 invariants (unit-tested at 100% branch coverage):** argv never contains
`--i-understand-data-loss-risk` unless `typed_ack == target`; never contains `--apply` unless
`confirmed`; `icloud-evict` with a missing/mismatched `typed_ack` raises `ConsentError` before any
argv exists. Adversarial cases: empty input, double keypress, `y` at the typed-ack prompt, path with
trailing slash — all must fail the gate.

---

## 7. Interrupt contract (the crux: no-op handler, NEVER `SIG_IGN`)

Adopted verbatim from research §5 — this is binding on CODE and TEST:

1. **Foreground child owns the real tty.** On `--apply`, the TUI leaves curses (`endwin`), then
   `Executor.handover` installs `prev = signal.signal(signal.SIGINT, _sigint_noop)` — a real
   **handler function**, never `signal.SIG_IGN` — and runs the child with inherited fds.
   *Why it matters:* `SIG_IGN` survives `exec` and would neutralize the child bash's
   `trap on_signal INT`, silently disabling the script's recovery message + 130 semantics. A
   *handled* signal resets to `SIG_DFL` on exec (POSIX), so the child's trap arms normally.
2. Ctrl-C is delivered by the tty to the foreground process group; the child runs
   `on_signal → cleanup_handler` (recovery text + lock `rmdir`) and exits 130. The parent's no-op
   handler swallows its copy; `subprocess.run` returns the real rc via PEP-475 auto-retry.
3. `interpret_result` maps **rc 130 → "interrupted"** (never success, never generic error). The
   handover path restores `prev` in a `finally`, does an `stty sane`-equivalent reset, re-inits
   curses, and **refreshes both porcelain reads** so the dashboard reflects reality.
4. `main_tui` installs the same no-op handler for the whole curses session (menu-time Ctrl-C must not
   kill the TUI; `q` quits). `--dump` and `--version` leave the default disposition untouched.

**What TEST asserts** (P1 integration, slow-rclone shim, SIGINT to the child pid/pgrp, sandboxed
`HOME`/`XDG_*` inherited via executor env injection; handover fds pointed at a capture file):

- child **rc == 130**, surfaced by `interpret_result` as `interrupted` — not `ok`;
- **lock absent**: `$XDG_CACHE_HOME/cloud-xdg-provision.lock` does not exist afterward;
- **container intact**: the CODE container still exists locally (interrupt lands during the copy,
  before the read-back-gated drop window);
- **the child's recovery/trap output appeared** in the captured tty stream — this is the assertion
  that catches a `SIG_IGN` regression, which the lock assertion alone would miss (research §5 HIGH risk);
- post-interrupt refresh shows the dir still `local` (never falsely `offloaded`).

---

## 8. Build + test wiring

### 8.1 Makefile (exact diffs; recipe lines tab-indented)

```make
## lint: shellcheck all shell sources (incl. the extensionless launcher); then
##       byte-compile the TUI as its zero-dep python "lint". Skips cleanly where
##       python3 is absent — the shell toolkit's gate is unchanged on such machines.
lint:
	shellcheck bin/*.sh bin/lib/*.sh bin/xdg-tui hooks/pre-commit tests/*.sh
	@if command -v python3 >/dev/null 2>&1; then \
	  python3 -m py_compile bin/xdg_tui.py tests/tui/*.py && \
	  echo "py_compile OK: bin/xdg_tui.py tests/tui/*.py"; \
	else \
	  echo "python3 not found — skipping TUI byte-compile (install python3 to lint the TUI)"; \
	fi

## test: smoke suite (bash contract, incl. the porcelain golden group) + stdlib
##       unittest for the TUI core. Same graceful skip as lint.
test:
	bash tests/smoke.sh
	@if command -v python3 >/dev/null 2>&1; then \
	  python3 -m unittest discover -s tests/tui -p 'test_*.py'; \
	else \
	  echo "python3 not found — skipping TUI unit tests (install python3 to run them)"; \
	fi
```

Sequencing constraint: the `tests/tui/` discover step must not land before at least one test file
exists (`unittest discover` on an empty dir exits non-zero) — backend-coder ships `xdg_tui.py` and its
first tests in the same commit. `.gitignore` gains `__pycache__/`.

### 8.2 `tests/tui/` layout (stdlib `unittest`; python-side, backend-coder)

```
tests/tui/test_parse.py        header refusal (first line != porcelain=1), 6-field rule,
                               unknown-state/short-row -> PorcelainError (surfaced never guessed),
                               every enum state from §2.6 fixture text
tests/tui/test_model.py        join by canonical; 'inconsistent' derivation; migrate-projects note;
                               non-code entries have offload_state None
tests/tui/test_plan.py         argv matrix for every op in §5; --apply iff confirmed;
                               evict consent gating incl. adversarial inputs (§6) — 100% branch
tests/tui/test_interpret.py    rc 0/1/130/other mapping; stderr passed through verbatim
tests/tui/test_executor.py     capture mode against a fake script (fixture emitting §2.6 goldens,
                               large-output full-drain case); asserts handover installs a HANDLER
                               (signal.getsignal(SIGINT) is callable, is not SIG_IGN) and restores prev
```

Each test file does `sys.path.insert(0, <repo>/bin)` (computed from `__file__`) then `import xdg_tui`.
No test touches the real `$HOME`: executor env is always injected. Integration tests (round-trip,
SIGINT §7) are **TEST-phase** deliverables (`tests/tui/test_integration.py`, skip-guarded on rclone +
sandbox containment self-check) — not CODE-phase.

### 8.3 smoke.sh porcelain golden group (bash-side, devops-coder)

New group appended after the reclaim group, same harness conventions (sandboxed `HOME`, fabricated
`$XDG_STATE_HOME` files, capture-then-inspect — write output to a file and `grep -qxF`/`awk` on the
file, never pipe the script into `grep -q`):

| Assert | How |
|---|---|
| header exact | line 1 of both outputs is literally `porcelain=1` (`sed -n 1p` on the capture file) |
| row counts | classify = 16 lines total (header+15); offload-status = 4 (header+3) |
| field discipline | every row: `awk -F'\|' 'NR>1 && NF!=6 {exit 1}'` |
| every enum state | fixture per state → whole-line `grep -qxF` of the §2.6 golden shapes: symlink (sandbox symlink), localdir (mkdir), absent (nothing), offloaded+remote (fabricated state file with `remote=` line), offloaded+`<unknown remote>` (empty state file), local+clean / local+dirty (git fixture ± untracked file), local+none (plain dir), absent+none |
| read-only | find-snapshot of sandbox HOME + state dir before/after both porcelain runs — byte-identical |
| human path unchanged | `--classify` without `--porcelain` still emits the human header + Notes block |
| misuse refused | `--porcelain --offload` (and bare `--porcelain`) exits non-zero with the §2.3 message |

This group is the **contract freeze**: it lands with (or before) the python parser, and any future
change to the porcelain shape must update these goldens deliberately.

---

## 9. Footguns (binding)

**bash 3.2 / shellcheck (`enable=all` minus the repo-wide disables):**

- `--porcelain` must **not** call `set_mode` — it is a modifier; making it a lane would break
  `--classify --porcelain` with "choose ONE mode".
- The porcelain branches must emit **only** `printf` rows — no `log` header, no Notes heredoc, no
  advisory second line may leak into machine output.
- `printf` format strings are always literal; row values are arguments (SC2059).
- `case` patterns matching a literal pipe must quote it: `*"|"*` (unquoted `|` is the case
  alternation operator).
- Keep the `# shellcheck disable=SC2086` comments on the intentional word-split `for k in $KEYS` loops.
- `grep '^remote=' … || true` idiom preserved (set -e/pipefail; missing line is not an error).
- No backticks inside quoted strings/heredocs; no `[[ ]]`, no `mapfile`, no `<()`, no `readlink -f`.
- Launcher: probe runs with `</dev/null` (never block on stdin); launcher has no `.sh` suffix, so it
  **must** be named explicitly in the shellcheck target; `exec` (not plain call) so rc/signals pass through.
- Makefile recipes: tabs, `$$` escaping inside the shell-outs, `@if command -v …` skip idiom
  (mirrors the `helper` target).

**python (3.9 floor):**

- **`SIG_IGN` ban** (§7). The no-op suppression is `signal.signal(SIGINT, _sigint_noop)` where
  `_sigint_noop` is a def — never `SIG_IGN`, never leaving `KeyboardInterrupt` to unwind curses.
  Restore the previous handler in `finally`.
- **`endwin` on every exit path** including exceptions: the curses session runs under
  `curses.wrapper`; the handover leave/re-enter sequence wraps the child run in `try/finally`
  (finally: restore handler, tty reset, re-init). A crash must never leave the terminal raw.
- **Capture = full drain**: `subprocess.run(capture_output=True)` only; never hand-rolled `Popen`
  pipes that can close early (child gets SIGPIPE → spurious 141). Never capture a `--progress` call.
- **Never cache resolved `$HOME`/env at import time** — module-level constants may not read
  `os.environ`; the executor resolves env at call time and tests inject sandboxed env
  (containment requirement T2). `XDG_TUI_SCRIPT` is the script-path test seam.
- `import curses` only inside the UI entrypoints (`main`'s TUI branch) — `--dump`/`--version` and all
  CORE/EXECUTOR imports must work without curses.
- `text=True, errors="replace"` on captured output — undecodable bytes from a child must not raise.
- argv is always a list to `subprocess`; **never `shell=True`** (no injection surface).
- 3.9 syntax only: no `match`, no `int | None` annotations, no 3.10+ APIs.
- `KEY_RESIZE` handled in the getch loop (re-render); no busy-poll.

---

## 10. ADR Decision 3 amendment (exact text — the lead appends to `docs/architecture/xdg-cloud-adr.md` §5)

```markdown
### 5.2 Amendment (2026-07-03) — Python permitted for the OPTIONAL TUI only

Decision 3's dependency rule ("No dependency beyond bash, shellcheck, coreutils. Do **not** call
`just`, `npm`, `python`, etc.") is amended **narrowly**:

- `bin/xdg_tui.py`, launched via `bin/xdg-tui`, is an **optional companion** TUI. It may be
  written in Python 3 (**stdlib only** — curses UI, zero pip packages).
- The **core toolkit remains bash-3.2-pure**: `bin/*.sh`, `bin/lib/*.sh`, `hooks/`, and
  `tests/smoke.sh` must never require python, and no *core* script in those sets may invoke
  python. (`bin/xdg-tui`, the launcher, is the sole sanctioned python-invoking shell script —
  it exists precisely to gate the optional TUI behind a functional probe.)
- The Makefile's python steps (`py_compile` in `lint`, `unittest discover` in `test`) are
  **skip-guarded** behind `command -v python3` — a machine without python3 still passes
  `make lint`/`make test` and retains every non-TUI feature (same graceful-skip idiom as the
  no-`swiftc` `helper` target).
- The TUI is a **strict wrapper** (see `docs/architecture/tui-offload-manager-diff.md`): it adds
  UX, never policy; the provision script's guards remain the sole enforcement layer.

Everything else in Decision 3 (Makefile over just; thin targets; no npm) is unchanged. A future
proposal to require python for any *core* lane re-opens this decision; this amendment does not.
```

---

## 11. Reasoning chain

- **Porcelain is a mirror, not a new report** — *because* the TUI must never parse drift-prone human
  text or internal state files, yet the bash change must stay small on a data-loss-adjacent script;
  so each porcelain branch reproduces the existing branch logic exactly, and the golden group freezes
  it. *Which required* keeping `inconsistent` out of the bash (§4.2): it is the join of two existing
  facts, and deriving it in the TUI keeps both output modes of each command semantically identical.
- **Modifier flag, not a lane** — *because* `set_mode` enforces one lane per invocation and
  `--classify --porcelain` must be one invocation; a lane would also wrongly imply lock/trap posture
  (porcelain modes stay read-only, no `begin_mutating_mode`).
- **Separate executable + two-mode executor** — *because* every TUI action must be a fully-guarded
  normal script run (lock, trap, dry-run gate all per-invocation), and the wrapped rclone calls use
  `--progress`, *which required* terminal handover for every `--apply` (capture would garble progress
  and risk SIGPIPE) and full-drain capture for the bounded read-only outputs.
- **No-op handler, never `SIG_IGN`** — *because* POSIX exec semantics reset handled signals to
  `SIG_DFL` but preserve `SIG_IGN`, so only a handler keeps the child's `trap on_signal INT` alive;
  *which required* TEST to assert the recovery **message** (not just lock absence) so a `SIG_IGN`
  regression cannot pass.
- **Typed consent precedes even the evict preview** — *because* the script checks `ICLOUD_CONFIRM`
  before dry-run (gate 5 is unconditional), so the TUI cannot show a preview without passing the risk
  flag; gating that flag on the typed path keeps the script's consent friction byte-equivalent in the
  TUI (single-keypress evict banned by construction, testable as a pure function).
- **Underscore module name** — *because* the tests are the enforcement mechanism for the confirm/
  consent gates, and they must import the core trivially; the launcher preserves the user-facing
  hyphenated name.
- **stdlib-only tooling with `command -v` skips** — *because* ADR Decision 3's dependency posture
  survives only if a python-less machine still passes every gate; this keeps the ADR amendment narrow.

---

## 12. Decisions — RESOLVED

- [x] **RATIFIED: `inconsistent` is TUI-derived** (§4.2) — bash porcelain stays a faithful mirror;
  the TUI renders the join of two reported facts. (Overturning would fork porcelain semantics from
  human output inside `cmd_offload_status`.)
- [x] **`--porcelain` is a modifier flag** parsed like `--aside`, guarded post-parse to the two
  read-only modes; misuse dies loudly.
- [x] **Schema frozen**: `porcelain=1` header + `class|canonical|localName|state|remote|git`;
  append-only within v1; pipe-containing remotes sanitized to a placeholder (rows never dropped,
  never corrupted); no reclaim/icloud porcelain in v1 (verbatim panes).
- [x] **Single-file `bin/xdg_tui.py`** (underscore — importable for tests; hyphen stays on the
  launcher), three-layer seam enforced by lazy `curses` import; python 3.9 floor.
- [x] **Every `--apply` = terminal handover; every read-only call = full-drain capture.**
- [x] **Evict**: typed-path acknowledgment → preview (with risk flag) → y/N → apply. `ConsentError`
  before any argv without the ack. Single-keypress evict banned.
- [x] **Interrupt**: no-op SIGINT handler session-wide in the TUI; rc 130 = interrupted; TEST asserts
  rc + lock + container + **recovery message** + truthful refresh.
- [x] **Tooling**: `py_compile` + `unittest discover`, both skip-guarded; launcher named explicitly
  in the shellcheck target; `__pycache__/` gitignored.
- [x] **S2 partition**: devops-coder = bash/build/smoke; backend-coder = python/tests-tui; ADR
  amendment + README/CHANGELOG = lead. Zero shared files.

### Known limitations / v2 candidates (recorded, not built)

- Termux curses remains assumed-GO pending the P2 on-device pass; a clean launch-time failure is the
  designed degradation (no ANSI fallback in v1).
- Reclaim/iCloud parsed tables (porcelain branches for those lanes) deferred.
- Free-text path targets for reclaim/iCloud (beyond registry entries) deferred — v1 targets
  `$HOME/<localName>` only.
- `python3` found only under a versioned name (`python3.11`) is not probed — `python3` is the
  universal name; documented.
