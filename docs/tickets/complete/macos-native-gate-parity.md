# Restore native macOS runtime and gate parity

- **Created:** 2026-07-30
- **Owner:** wabbazzar
- **Status:** complete — native Mac gate verified; server integration underway
- **Priority:** high
- **Type:** bugfix
- **Estimated Points:** 5 (3 phases, each capped at 2)
- **Refs:** `install.sh:167,929-936`, `agents/design/runner.sh:97-114,357-432`,
  `agents/design/collectors.sh:45-54`, `tests/design.bats:88-102,147-160,251-253`,
  `tests/deck-mirror.bats:101-107`, `.agents/gates.md`

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

## Decisions

### Locked decisions

| Decision | Contract |
|---|---|
| Installed interpreter | Keep `/bin/bash`; launchd jobs must not depend on Homebrew. |
| Runtime dependencies | Python 3.11+ is already required by Shipyard and may provide portable UTC/mtime operations; GNU coreutils must not become a runtime dependency. |
| Fixture utilities | Add named helpers in `tests/helpers.bash`; do not globally replace `sed`, `date`, or `touch` on `PATH`. |
| Test surface | Add `tests/macos-portability.bats` for interpreter/utility contracts and keep existing behavior assertions in their owning files. |
| Live state | This prerequisite changes source/tests only. It does not reinstall, reload, kickstart, or mutate any live LaunchAgent/event file. |

### Open decisions with defaults

| Decision | Default the builder applies and records |
|---|---|
| Bare `sed -i` sweep | Migrate every fixture-only bare `sed -i` occurrence to the named helper so the same class cannot fail later in the 523-case run. |
| Relative fixture mtimes | Migrate human-relative `touch -d` fixture usage to one Python-backed helper; leave ISO-8601 `touch -d` uses only where both BSD and GNU semantics are proven. |
| UTC enumeration shape | Emit the bounded UTC day list once from Python and consume it in shell; do not fork Python once per event line. |

### User-decision-class items

None. The changes are private, reversible source/test corrections with no live
service mutation. The `polish-ticket` auto-gate proceeds to `execute-ticket`.

## Verified pre-build baseline (2026-07-30)

- Host: macOS 26.5, Apple `/bin/bash` 3.2.57, Python 3.11.7.
- Toolchain installed during polish: native Homebrew Bats 1.14.0 and Bash
  5.3.15. Because this Codex parent runs translated, the native launchd gate
  must force `/bin/bash` through a temporary first-on-PATH shim:

  ```bash
  MAC_BASH_SHIM="$(mktemp -d)"
  ln -s /bin/bash "$MAC_BASH_SHIM/bash"
  PATH="$MAC_BASH_SHIM:$PATH" /opt/homebrew/bin/bats --version
  ```

- Exact RED anchors on `a065ae1`:
  - `/bin/bash -n agents/design/runner.sh` exits 2 with unmatched backtick /
    unexpected EOF.
  - Native-shell `tests/design.bats` reports current-day `job_fail=0` instead
    of 1 and self-test rejects GNU-relative `touch -d`.
  - Native-shell `tests/deck-mirror.bats` fails at fixture `sed -i` before the
    product assertion.
- Linux/server baseline at the same commit: 523/523 Bats, syntax, Python
  compile, leak, deck freshness/completeness, render, install/doctor, GitHub CI,
  and Pages deployment all green.

## Traps this build must pin

- New test files must be explicitly staged before `leak-check.sh`; it scans
  tracked files only.
- Do not “fix” the parser failure by selecting Homebrew Bash in launchd.
- Keep the Bash 5 syntax gate as a guard while adding `/bin/bash` 3.2 proof.
- BSD `sed -i` requires a suffix; GNU accepts an attached nonempty suffix, but
  named Python fixture helpers avoid backup cleanup and quoting drift.
- Preserve UTC semantics and source checksums; the collector remains read-only.
- The standalone clone is not fleet-live. Do not run `install.sh --project`,
  `launchctl bootstrap/bootout/kickstart`, or the live runner in this ticket.
- Do not use a Git worktree: the post-commit hook can repoint installed skill
  symlinks into the temporary tree.

## Implementation Plan

### Phase 1 — Bash 3.2 launchd runtime contract (2 pts)

Remove the parser-sensitive backticks from the nested design-runner heredoc
without changing the Python normalization logic. Add a Mac-capable regression
that syntax-checks every shipped shell entrypoint with the launchd interpreter
and proves the design self-test reaches runtime rather than parse failure.

Files owned: `agents/design/runner.sh`, new
`tests/macos-portability.bats`.

**Delegation: subagent — bounded build brief (≤40-line return).**

> Work only in the isolated clone on its current `main`. Own
> `agents/design/runner.sh`, new `tests/macos-portability.bats`, and this
> ticket's Phase 1 Ledger row. First add a case named `launchd interpreter
> parses every shipped shell entrypoint`; show it RED against `a065ae1`
> because `/bin/bash -n agents/design/runner.sh` exits 2. Preserve a modern
> `bash -n` guard. Make the smallest parser-safe edit to the embedded Python
> comment/fence without changing normalization output. Return ≤40 lines:
> files; RED/GREEN commands + exits; test count; exact syntax/output evidence;
> blockers.
>
> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

**RED:**

```bash
/bin/bash -n agents/design/runner.sh
```

It must exit 2 with the captured unmatched-backtick signature. The modern
guard must pass before the edit:

```bash
bash -n agents/design/runner.sh
```

**Focused GREEN and observable DoD:**

```bash
MAC_BASH_SHIM="$(mktemp -d)"
ln -s /bin/bash "$MAC_BASH_SHIM/bash"
PATH="$MAC_BASH_SHIM:$PATH" /opt/homebrew/bin/bats \
  --filter 'launchd interpreter parses every shipped shell entrypoint' \
  tests/macos-portability.bats
/bin/bash -n agents/design/runner.sh
bash -n agents/design/runner.sh
```

The Bats output shows one passing interpreter-contract case; both syntax
commands exit 0. Remove `$MAC_BASH_SHIM` after the gate. Before commit, also run
the full static gate listed under Final Gate. Commit only the two owned files.

### Phase 2 — Portable UTC window and stale fixture time (2 pts)

Introduce the smallest explicit platform-neutral date/mtime helpers needed by
the design collector and self-test. Preserve UTC day names, seven-day bounds,
and the 40-day stale exclusion.

Files owned: `agents/design/collectors.sh`, `agents/design/runner.sh`,
`tests/design.bats`, `tests/macos-portability.bats`.

**Delegation: subagent — bounded build brief (≤40-line return).**

> Own only the Phase 2 files above. Add RED cases that plant a current UTC-day
> event and a 40-day stale incident under BSD utilities. Preserve the existing
> 7-day collector, freshness cutoff, append-only inputs, and self-test
> semantics. Replace GNU-relative date/touch calls with bounded Python 3.11
> operations; do not fork per event line. Record input file checksums before
> and after. Return ≤40 lines: files; RED/GREEN commands + exits; exact counts,
> UTC names, checksums; blockers.
>
> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

**RED against `a065ae1`:**

```bash
MAC_BASH_SHIM="$(mktemp -d)"
ln -s /bin/bash "$MAC_BASH_SHIM/bash"
PATH="$MAC_BASH_SHIM:$PATH" /opt/homebrew/bin/bats \
  --filter 'collectors count events|--self-test exits 0' tests/design.bats
```

It must fail with `job_fail=0` for the planted current-day event and the BSD
`touch` rejection/self-test count mismatch.

**Focused GREEN and observable DoD:**

```bash
PATH="$MAC_BASH_SHIM:$PATH" /opt/homebrew/bin/bats \
  tests/design.bats tests/macos-portability.bats
/bin/bash -n agents/design/collectors.sh agents/design/runner.sh
python3 -m py_compile scripts/delegation-report.py scripts/gen-deck-data.py
```

The focused suite passes; the current UTC-day event count is 1; the 40-day
incident is excluded; fixture/event checksums are unchanged. Remove the shim
after the gate and commit only Phase 2 paths.

### Phase 3 — Portable test-fixture mutation and full gate (1 pt)

Add a transparent fixture helper for in-place text replacement and timestamp
setup, migrate the failing fixture call sites, and run the complete native Mac
and Linux-compatible repository gate. Avoid changing production behavior in
this phase.

Files owned: `tests/helpers.bash`, affected `tests/*.bats`,
`tests/macos-portability.bats`, and this ticket for its final Ledger/graduation.

**Delegation: subagent — bounded build brief (≤40-line return).**

> Add named Python-backed `fixture_replace_in_place` and
> `fixture_set_mtime_ago` helpers in `tests/helpers.bash`. Demonstrate the
> deck-mirror case RED before edits, migrate every fixture-only bare `sed -i`
> and human-relative `touch -d` occurrence, and add a static contract that can
> fail if either form returns. Do not place fake `sed/date/touch` binaries on
> PATH and do not change product expectations. Return ≤40 lines: files; count
> migrated; RED/GREEN/full-gate commands + exits; test counts; blockers.
>
> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

**RED:**

```bash
MAC_BASH_SHIM="$(mktemp -d)"
ln -s /bin/bash "$MAC_BASH_SHIM/bash"
PATH="$MAC_BASH_SHIM:$PATH" /opt/homebrew/bin/bats \
  --filter 'determinism guard: a missing transform target aborts' \
  tests/deck-mirror.bats
```

It fails at BSD `sed -i` before `sync-deck-mirror.sh` runs.

**Focused GREEN and observable DoD:**

```bash
PATH="$MAC_BASH_SHIM:$PATH" /opt/homebrew/bin/bats \
  tests/deck-mirror.bats tests/macos-portability.bats
! rg -n '(^|[;&|[:space:]])sed -i([[:space:]]|$)|touch -d "[0-9]+ (minute|day)s? ago"' \
  tests
```

The focused cases reach product assertions and the static scan finds no
fixture-only GNU form. Continue directly to the Final Gate before the phase
commit.

## Testing Strategy

- Capture RED from `/bin/bash -n agents/design/runner.sh`, the focused design
  collector/self-test cases, and the deck-mirror determinism fixture.
- Add a regression that uses the same `/bin/bash` path emitted by launchd.
- Run focused design, launchd, and deck-mirror Bats files under the native Mac
  shell contract.
- Run `bats tests/`, shell syntax, Python compile, leak, deck freshness, deck
  completeness, and rendered-deck gates on the corrected tree.
- Preserve GitHub's Linux gate; the handoff agent pushes and watches CI.

## Final Gate — run before every phase commit as applicable, then end-to-end

```bash
MAC_BASH_SHIM="$(mktemp -d)"
ln -s /bin/bash "$MAC_BASH_SHIM/bash"
PATH="$MAC_BASH_SHIM:$PATH" /opt/homebrew/bin/bats tests/
/bin/bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py scripts/delegation-report.py
/bin/bash scripts/leak-check.sh
/bin/bash scripts/check-deck-fresh.sh
/bin/bash scripts/check-deck-complete.sh
node scripts/check-deck-render.mjs
git diff --check
git status --short
unlink "$MAC_BASH_SHIM/bash"
rmdir "$MAC_BASH_SHIM"
```

Expected: 523+ tests pass (increased by the new regressions); both syntax
surfaces exit 0; compile/leak/deck/render gates pass (`render` exit 3 is a
recorded toolchain skip only if Playwright is absent); no unexplained paths or
background test processes remain. Cleanup removes only the known shim symlink
and now-empty directory created in the same shell.

After the verified final commit, graduate deterministically:

```bash
scripts/ticket-lifecycle.sh --project . \
  --graduate docs/tickets/pending/macos-native-gate-parity.md
scripts/ticket-lifecycle.sh --project . --check
```

The graduation rename belongs in the final phase commit. The server receiving
agent imports the commit bundle, re-runs Linux gates, fast-forward pushes, and
watches GitHub CI; this Mac performs no GitHub push.

## Acceptance Criteria / Definition of Done

- [x] `/bin/bash -n` succeeds for every shipped shell entrypoint, including
      `agents/design/runner.sh`.
- [x] The design role launched with the installer-selected interpreter reaches
      its deterministic self-test and returns 0.
- [ ] A planted current-day event is counted inside the seven-day collector
      window on both macOS and Linux.
- [x] The 40-day self-test incident is excluded without GNU-only `touch -d`.
- [x] Test fixture mutation reaches the product assertion under BSD and GNU sed.
- [x] The regression coverage fails against `a065ae1` for the captured causes.
- [ ] The complete repository gate is green on the Mac, and Linux GitHub CI is
      green after server-side integration. Mac: 528/528; server/CI pending.
- [x] No live LaunchAgent is reloaded and no event file is changed by this
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

## Ledger

The builder appends the pre-slice plan, exact builder line, commit hash, RED /
GREEN evidence, and honest deferrals before moving to the next phase.

| Phase | Plan | Builder | Commit | Evidence / notes |
|---|---|---|---|---|
| 1 — Bash 3.2 contract | Add a RED launchd-interpreter regression, make the embedded Python comment parser-safe, then run native + modern syntax gates. | builder: subagent (1 agent) | `4bbc319` | RED: `/bin/bash -n agents/design/runner.sh` rc=2 with unmatched backtick. GREEN: portability Bats 1/1, native + modern full syntax PASS, compile/leak/deck PASS; render rc=3 (Playwright unavailable). |
| 2 — portable UTC/mtime | Add RED native cases for current-day collection and stale self-test data, replace GNU-relative time operations with bounded Python, and prove source checksums stay unchanged. | builder: subagent (1 agent) | `e9a85e8` | RED: native design Bats 0/2, current-day `job_fail=0`, BSD touch rejected relative time. GREEN: design + portability Bats 13/13; seven UTC days counted; stale incident excluded; SHA-256 sources unchanged; native/modern syntax, compile/leak/deck PASS. |
| 3 — fixture utilities/final | Add named fixture mutation/mtime helpers, migrate every reproduced GNU-only fixture form, prove the static contract, run the full Mac gate, and graduate the ticket. | builder: subagent (1 agent) + lead integration | this phase commit | RED: BSD `sed -i` aborted before the deck assertion; the first native full pass exposed Bash 3.2 runtime failures from nested `case` in command substitution and `${var^}`, GNU relative-date cooldown writes, lock-fixture mismatch, and `/var` ↔ `/private/var` manifest identity. GREEN: all 25 reproduced failures pass; native ARM64 `/bin/bash` Bats 528/528 (exit 0); native + modern syntax, Python compile, leak, deck freshness/completeness, and `git diff --check` pass. Render gate exits 3 only because Playwright is absent. Live LaunchAgents and event files were not mutated. Linux/server gate and GitHub CI are the receiving agent's integration check. |

Run this ticket with the `execute-ticket` skill.
