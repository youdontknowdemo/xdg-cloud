# xdg-cloud Makefile
# Thin targets only — each is a one-or-two-line shell-out (ADR Decision 3).
# Requires: bash, shellcheck (for lint), coreutils. No just/npm. python3 is
# OPTIONAL (ADR Decision 3 amendment): only the companion TUI needs it, and
# every python step below skip-guards behind a FUNCTIONAL probe
# (`python3 -c ''`, same idiom as bin/xdg-tui) — never a bare `command -v`:
# stock macOS ships a CLT stub python3 that exists on PATH but pops a GUI
# installer and exits non-zero when CLT is absent.

VERSION := $(shell cat VERSION)

.PHONY: lint test install version helper
.DEFAULT_GOAL := lint

## lint: shellcheck all shell sources (incl. the extensionless launcher); then
##       byte-compile the TUI as its zero-dep python "lint". Skips cleanly where
##       python3 is absent — the shell toolkit's gate is unchanged on such machines.
##       Also skips while bin/xdg_tui.py has not landed yet (concurrent-dev window).
lint:
	shellcheck bin/*.sh bin/lib/*.sh bin/xdg-tui hooks/pre-commit tests/*.sh
	@if ! python3 -c '' </dev/null >/dev/null 2>&1; then \
	  echo "python3 not found — skipping TUI byte-compile (install python3 to lint the TUI)"; \
	elif [ ! -f bin/xdg_tui.py ]; then \
	  echo "bin/xdg_tui.py not present — skipping TUI byte-compile"; \
	else \
	  files="bin/xdg_tui.py"; \
	  for f in tests/tui/*.py; do [ -f "$$f" ] && files="$$files $$f"; done; \
	  python3 -m py_compile $$files && \
	  echo "py_compile OK: $$files"; \
	fi

## test: smoke suite (bash contract, incl. the porcelain golden group) + stdlib
##       unittest for the TUI core. Same graceful skip as lint.
test:
	bash tests/smoke.sh
	@if ! python3 -c '' </dev/null >/dev/null 2>&1; then \
	  echo "python3 not found — skipping TUI unit tests (install python3 to run them)"; \
	elif ! ls tests/tui/test_*.py >/dev/null 2>&1; then \
	  echo "tests/tui has no test files yet — skipping TUI unit tests"; \
	else \
	  python3 -m unittest discover -s tests/tui -p 'test_*.py'; \
	fi

## install: make scripts/hook executable and wire the pre-commit hook (idempotent).
install:
	@git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: make install must run inside a git repo. Clone xdg-cloud with git, then run make install." >&2; exit 1; }
	chmod +x bin/*.sh hooks/pre-commit
	@set -e; \
	 hooks_dir="$$(git rev-parse --git-path hooks)"; \
	 mkdir -p "$$hooks_dir"; \
	 src_hook="$$(pwd)/hooks/pre-commit"; \
	 dest_hook="$$hooks_dir/pre-commit"; \
	 if { [ -e "$$dest_hook" ] || [ -L "$$dest_hook" ]; } && \
	    ! { [ -L "$$dest_hook" ] && [ "$$(readlink "$$dest_hook")" = "$$src_hook" ]; }; then \
	   bak="$$dest_hook.backup-$$(date +%Y%m%d-%H%M%S)"; \
	   mv "$$dest_hook" "$$bak"; \
	   echo "make install: backed up existing pre-commit hook -> $$bak"; \
	 fi; \
	 ln -sf "$$src_hook" "$$dest_hook"; \
	 echo "pre-commit hook wired: $$dest_hook -> $$src_hook"

## version: print the canonical version string from the VERSION file.
version:
	@echo $(VERSION)

## helper: compile the iCloud upload-state helper (macOS + Xcode Command Line Tools). OPTIONAL —
##         only `--icloud-evict` needs it. If swiftc is absent (e.g. Linux/CI), the binary is NOT
##         produced and evict refuses at runtime — this target still EXITS 0 so make never breaks.
##         The compiled binary (bin/icloud-uploaded) is .gitignore'd — never commit it.
helper:
	@if command -v swiftc >/dev/null 2>&1; then \
	   swiftc -O -o bin/icloud-uploaded bin/icloud-uploaded.swift && chmod +x bin/icloud-uploaded && \
	   echo "built bin/icloud-uploaded"; \
	 else \
	   echo "swiftc not found (install Xcode Command Line Tools) — skipping helper; --icloud-evict will refuse until built." >&2; \
	 fi
