# xdg-cloud Makefile
# Thin targets only — each is a one-or-two-line shell-out (ADR Decision 3).
# Requires: bash, shellcheck (for lint), coreutils. No just/npm/python.

VERSION := $(shell cat VERSION)

.PHONY: lint test install version
.DEFAULT_GOAL := lint

## lint: shellcheck all shell sources; honors .shellcheckrc; non-zero on any finding.
lint:
	shellcheck bin/*.sh hooks/pre-commit tests/*.sh

## test: run smoke + idempotency checks in a sandbox (never touches real $$HOME).
test:
	bash tests/smoke.sh

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
