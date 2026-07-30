# Restore native macOS runtime and gate parity

- **Created:** 2026-07-30
- **Owner:** wabbazzar
- **Status:** pending — draft ready for polish
- **Priority:** high
- **Type:** bugfix
- **Estimated Points:** 5 (3 phases, each capped at 2)
- **Refs:** `install.sh:167,929-936`, `agents/design/runner.sh:97-114,357-432`,
  `agents/design/collectors.sh:45-54`, `tests/design.bats:88-102,147-160,251-253`,
  `tests/deck-mirror.bats:101-107`

## Summary

Make the shipped design role and repository gate run under the native macOS
runtime selected by the launchd installer. Close the Bash 3.2, BSD date/touch,
and BSD in-place-edit gaps that the first real Mac gate exposed.

## Problem / Background — reproduced acceptance anchors

The new launchd path deliberately emits `/bin/bash` as the runner interpreter.
On macOS that is Bash 3.2.57, while developer shells and Linux CI use newer
Bash. The installed design role therefore cannot parse:

```text
$ /bin/bash -n agents/design/runner.sh
agents/design/runner.sh: line 369: unexpected EOF while looking for matching ``'
agents/design/runner.sh: line 457: syntax error: unexpected end of file
exit=2
```

The incompatible construct is a quoted Python heredoc nested in command
substitution at `agents/design/runner.sh:357-432`; the odd triple-backtick
comment at line 369 is parsed as shell backticks only by Bash 3.2. Bash 5.2
returns 0, which is why Linux CI and ordinary developer runs missed it.

With Bats itself running under native Bash, two BSD utility assumptions are
also observable:

```text
$ PATH="$PWD/.git/apple-bin:$PATH" /opt/homebrew/bin/bats \
    --filter 'collectors count events' tests/design.bats
not ok ... tests/design.bats, line 102
expected sources.events.job_fail=1; actual=0

$ PATH="$PWD/.git/apple-bin:$PATH" /opt/homebrew/bin/bats \
    --filter 'determinism guard: a missing transform target aborts' \
    tests/deck-mirror.bats
sed: ... invalid command code f
```

`agents/design/collectors.sh:49` uses GNU `date -d`, so its suppressed failure
silently enumerates no event files. `agents/design/runner.sh:102` uses GNU
human-relative `touch -d` in the shipped self-test. Test fixtures use bare GNU
`sed -i`, which BSD sed interprets as a backup suffix before the product code
is reached.

### Root cause record

- **Where:** shared assumptions at the launchd/runtime boundary and in fixture
  utilities, not the business reducers.
- **When:** `f1cab2f` introduced the nested heredoc/backticks;
  `257bdfa` made `/bin/bash` the real launchd interpreter and exposed it.
  The exact GNU utility assumptions predate the Mac gate.
- **Elsewhere:** Bash 3.2 syntax-checking flags only the design runner; bare
  `sed -i` and human-relative `touch -d` recur in test fixtures and must be
  handled through one explicit portable fixture contract.
- **Why missed:** CI is Linux-only; design tests resolve a modern PATH Bash;
  launchd tests inspect manifests but never parse/run the design role with the
  emitted interpreter; there is no Darwin/BSD fixture lane.

## Technical Requirements

1. Preserve `install.sh`'s explicit `/bin/bash` launchd contract; do not make
   installed jobs depend on Homebrew.
2. Make every shipped shell entrypoint pass `/bin/bash -n` on macOS without
   weakening the existing modern-Bash syntax gate.
3. Replace design event-day enumeration and stale-fixture timestamp creation
   with deterministic Linux/macOS-compatible helpers. Do not change the
   seven-day window or freshness semantics.
4. Give test fixtures one explicit portable in-place-edit and mtime contract;
   do not globally hide production utility usage behind an opaque PATH shim.
5. Add a regression that invokes the emitted design runner interpreter
   contract and a collector assertion that fails when the current UTC day is
   skipped.
6. Keep Linux behavior and all 523 existing test contracts green.

## Implementation Plan

### Phase 1 — Bash 3.2 launchd runtime contract (2 pts)

Remove the parser-sensitive backticks from the nested design-runner heredoc
without changing the Python normalization logic. Add a Mac-capable regression
that syntax-checks every shipped shell entrypoint with the launchd interpreter
and proves the design self-test reaches runtime rather than parse failure.

Files: `agents/design/runner.sh`, `tests/launchd-install.bats` or a focused
portable-shell test.

Delegation: subagent — implement the minimal parser fix and red/green
interpreter-contract regression.

### Phase 2 — Portable UTC window and stale fixture time (2 pts)

Introduce the smallest explicit platform-neutral date/mtime helpers needed by
the design collector and self-test. Preserve UTC day names, seven-day bounds,
and the 40-day stale exclusion.

Files: `agents/design/collectors.sh`, `agents/design/runner.sh`,
`tests/design.bats`, and a shared runtime helper only if both call sites need it.

Delegation: subagent — implement and characterize Linux/BSD time behavior with
focused collector and self-test evidence.

### Phase 3 — Portable test-fixture mutation and full gate (1 pt)

Add a transparent fixture helper for in-place text replacement and timestamp
setup, migrate the failing fixture call sites, and run the complete native Mac
and Linux-compatible repository gate. Avoid changing production behavior in
this phase.

Files: `tests/helpers.bash` and affected `tests/*.bats`.

Delegation: subagent — sweep fixture-only GNU utility assumptions, migrate to
the explicit helper, and return focused plus full-suite results.

## Testing Strategy

- Capture RED from `/bin/bash -n agents/design/runner.sh`, the focused design
  collector/self-test cases, and the deck-mirror determinism fixture.
- Add a regression that uses the same `/bin/bash` path emitted by launchd.
- Run focused design, launchd, and deck-mirror Bats files under the native Mac
  shell contract.
- Run `bats tests/`, shell syntax, Python compile, leak, deck freshness, deck
  completeness, and rendered-deck gates on the corrected tree.
- Preserve GitHub's Linux gate; the handoff agent pushes and watches CI.

## Acceptance Criteria / Definition of Done

- [ ] `/bin/bash -n` succeeds for every shipped shell entrypoint, including
      `agents/design/runner.sh`.
- [ ] The design role launched with the installer-selected interpreter reaches
      its deterministic self-test and returns 0.
- [ ] A planted current-day event is counted inside the seven-day collector
      window on both macOS and Linux.
- [ ] The 40-day self-test incident is excluded without GNU-only `touch -d`.
- [ ] Test fixture mutation reaches the product assertion under BSD and GNU sed.
- [ ] The regression coverage fails against `a065ae1` for the captured causes.
- [ ] The complete repository gate is green on the Mac, and Linux GitHub CI is
      green after server-side integration.
- [ ] No live LaunchAgent is reloaded and no event file is changed by this
      ticket.

## Dependencies

- Blocked by: none.
- Blocks: autonomous execution of
  `docs/tickets/pending/local-operations-dashboard.md` on a green Mac baseline.
- External services: none.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| A test shim hides a production portability defect | Use named fixture helpers, not a global `sed`/`date` PATH replacement. |
| UTC behavior drifts across platforms | Assert exact current-day inclusion and bounded day lists with fixed fixtures. |
| Bash parser fix changes embedded Python | Change only the comment/fence representation and compare normalized output. |
| Mechanical fixture edits sprawl | Limit replacements to reproduced GNU-only forms and keep one helper contract. |

## Out of scope

- Changing the launchd interpreter to Homebrew Bash.
- Installing GNU coreutils as a runtime dependency.
- Loading/restarting live LaunchAgents.
- Implementing the local operations dashboard.
- General shell modernization unrelated to the reproduced Mac failures.
