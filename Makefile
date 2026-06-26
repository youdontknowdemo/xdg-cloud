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
	chmod +x bin/*.sh hooks/pre-commit
	ln -sf ../../hooks/pre-commit .git/hooks/pre-commit
	@echo "pre-commit hook wired: .git/hooks/pre-commit -> ../../hooks/pre-commit"

## version: print the canonical version string from the VERSION file.
version:
	@echo $(VERSION)
