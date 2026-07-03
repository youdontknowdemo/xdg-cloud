# Peer Review Synthesis — PR #43: xdg-tui offload manager

> Reviewed 2026-07-03 by 5 parallel reviewers: architect, test-engineer,
> backend-coder (python), devops-engineer (bash), security-engineer.
> All five verdicts: **APPROVE-WITH-NITS**. Zero blockers.

## Agreements (unanimous)

- **Wrap-don't-bypass holds end to end.** No policy in the TUI: no state-file
  reads, no pre-checks duplicating script guards, argv built only from registry
  canonical keys and call-time `$HOME` joins; every `--apply` behind preview →
  confirm; refusals relayed verbatim.
- **The two load-bearing safety contracts are real and adversarially tested.**
  The test reviewer ran mutation experiments: a `SIG_IGN` mutant was killed by 3
  independent tests (the offload ran to *completion* under the mutant — exactly
  the failure the design predicts); a softened consent gate (`.strip()`
  comparison) and a dropped porcelain field were each killed as well.
- **Porcelain contract is byte-consistent** across the bash emitters, the golden
  smoke group, and the python parser, with version-header exact-match both sides.
- Sandbox hygiene is structural, not conventional: containment self-checks
  before every `--apply`, injected env, real-HOME inequality assertions.

## Findings → resolution (remediated pre-merge in fe39bcf)

| # | Severity | Finding (reviewer) | Resolution |
|---|----------|--------------------|------------|
| 1 | MAJOR | Embedded **newline** in a symlink target / duplicate `remote=` lines split a porcelain row — one exotic symlink makes the dashboard fatally unusable (devops; independently found by security, who confirmed it **fails closed** — no forged argv possible) | Both emitters sanitize newline→placeholder; `head -n1` on the `remote=` extraction; smoke **P6** goldens pin both, negative-verified against the pre-fix script |
| 2 | MINOR (consent) | No `curses.flushinp()` before the y/N apply confirm — buffered type-ahead/paste could auto-answer a destructive confirm (security) | `flushinp()` before every consent read in `_confirm` and `_prompt_line`; call-order pinned by `tests/tui/test_ui_prompts.py` via the lazy-import seam |
| 3 | MINOR | `Executor.capture` children inherit the TUI's tty stdin — a future script prompt would steal keystrokes or hang (backend) | `stdin=subprocess.DEVNULL`; behaviorally pinned (fixture child must see EOF) |
| 4 | MINOR | Makefile python guards were existence-only; a stock-mac CLT-stub python3 would pop a GUI installer and fail the gate (devops) | Both guards use the launcher's functional-probe idiom |
| 5 | MINOR (docs) | Spec §4.3 vs §6 conflict on xdg-row actionability — code follows §6 (architect, backend) | §4.3 reconciled: xdg rows carry the three iCloud lanes, deliberate |
| 6 | MINOR (docs) | ADR §5.2 sentence literally banned its own launcher (architect) | Wording scoped to *core* scripts; launcher named as the sole sanctioned exception |

## Deferred (accepted, not merge-relevant)

- Headless coverage of `run_action`'s confirmed-apply wiring for offload/hydrate
  (gates beneath are fully covered; RecordingExecutor technique noted) — follow-up.
- Coverage numbers met by branch-walk inspection, not machine-enforced (stdlib-only
  posture excludes coverage tooling) — accepted.
- Tiny-terminal `addnstr` guards in two prompts, `--dump | head` BrokenPipeError,
  `\r` in symlink targets, `--`-before-positional defense-in-depth, `XDG_TUI_SCRIPT`
  seam left ungated (env-set already implies code-exec) — hardening-slice candidates.
- Timing margin in one unit test's disposition observer (0.1s sample in a 0.3s
  child); the integration SIGINT tests are race-free by construction (self-signaling
  shim). — tighten if it ever flakes.
- Termux curses unverified on-device; `--aside` drop-window trap timing verified on
  macOS bash 3.2 only (repo has no CI). P2 manual matrix remains open.

## Conflicts

None requiring arbitration — reviewer findings were disjoint or mutually
confirming (notably: devops and security hit the newline gap independently and
agreed on both the impact and the fail-closed behavior).

## Gate at review close

`make lint` clean (shellcheck enable=all + py_compile ×9); `make test`:
smoke PASS (~500 assertions incl. Groups P1–P6, Q1) + **84** python tests OK.
