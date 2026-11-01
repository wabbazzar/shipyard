# Diagnose the 2026-10-07 proctor batsGate exit 1 and make gate failures self-identifying

- **Created:** 2026-10-31
- **Owner:** wabbazzar
- **Status:** Ready — polished 2026-10-31; no open user-decision items
- **Priority:** medium
- **Type:** bugfix
- **Estimated Points:** 8 (three phases: 3 · 3 · 2)
- **Refs:** approved Daily Dispatch item `mentat:shipyard:02ef5699`;
  incident `9d1e258996e05a652268a107295a3450e360e79b6b7ec1af456a030721c31390`
  (class regression, surface runners, source release);
  `agents/release/runner.sh:112-135` (gate config validation),
  `agents/release/runner.sh:478-483` (gate execution),
  `agents/release/runner.sh:556-565` (failure result), `.agents/config.toml:52-56`,
  `tests/release-blocking-gate.bats:85-97` (`configure_gate`),
  `docs/OPERATIONS.md:76`

## Goal

Decide whether the 2026-10-07T09:30Z `batsGate` exit 1 was a flake, a
dirty-tree-sensitive test, or a real regression; make the runner-owned gate
record WHICH tests failed so the next failure is self-identifying; then fix or
close per the verdict. Do not build anything beyond that.

## Context

### Incident evidence (from the incident record, not re-verified)

- `batsGate.exitCode = 1`; the 200-line `log_tail` held tests 745–942, all `ok`,
  no `not ok`. syntax, leakCheck, deckFresh, deckRender passed.
- `scriptChecks.worktreeClean=false`, consistent with an uncommitted staged
  rename `docs/tickets/pending/diff-associated-project-rules-memory.md ->
  docs/tickets/complete/` in the live checkout. That rename was committed in
  `a2ca658`, so the dirty condition no longer exists on `main` and must be
  recreated on purpose.

### Observability gap (read from code, 2026-10-31)

- Gate stdout/stderr is appended to the shared `$LOG_FILE`
  (`runner.sh:481`). Nothing extracts failing node names.
- Failure result is only `.[$key] = {status:"completed", pass:false,
  exitCode:$rc}` plus one generic error string (`runner.sh:556-565`).
- Config validation is **exact**: `keys == ["command","modes","result_key",
  "timeout_sec"]` (`runner.sh:~121`), so any new key currently exits 2. The
  validator must be extended, not merely tolerated.

### Measured baseline (C2, run 2026-10-31 on this box)

`bats tests/ -t` on a clean tree: **951 ok, 0 not ok, exit 0, 5m01s wall**
(`real 5m1.325s`). Bats 1.10.0. So: (a) the failure did not reproduce on a
clean tree today, supporting flake or dirty-tree; (b) CLAUDE.md's "~80s" is
stale and the full suite does not fit a 300s tool timeout, so run it with
`run_in_background` and wait; (c) `[release.blocking_gate] timeout_sec = 900`
leaves ~3x headroom.

### Hypothesis (unproven; Phase 1 confirms or kills it)

A test reads the LIVE checkout and trips on a staged rename. Candidates
referencing `docs/tickets` or live-tree state: `tests/doctor.bats`,
`tests/ticket-lifecycle-install.bats`, `tests/delegation-contract.bats`,
`tests/delegation-report.bats`, `tests/shipyard-learn.bats`,
`tests/memory-*.bats`, `tests/deck-render.bats`.

## Discovery results (polish step 0)

- `.agents/config.toml` has no `[memory]` table: planning-memory query is a
  no-op (authoritative opt-out). No `.agents/specialists/*.toml`: specialist
  routing is a no-op. No `autonomous = true`: standard auto-gate rules apply.
- Gate classes that apply (from `.agents/gates.md`): bats suite, shell scripts,
  config-gated additivity (runner change), public-repo hygiene, delegation
  contract. Not applicable: systemd, served app, deck coupling (no SKILL.md
  frontmatter or `GENERIC_SKILLS` change), model-invocation caps (no model call
  added).

## Decisions

| # | Decision | Status |
|---|---|---|
| 1 | Do not build now: this ticket is polished only; the owner said do not build it. `execute-ticket` runs it later. | Locked |
| 2 | New key is `failure_excerpt` (bool) under `[release.blocking_gate]`; unset/false == today's bytes. | Locked (house rule) |
| 3 | `failedTests` = lines matching `^not ok ` from the gate output, max 20 entries, each cut to 200 chars. | Default; builder may adjust caps, must record in Ledger |
| 4 | Do NOT turn the key on in `.agents/config.toml` during this ticket. Enabling it changes live automation behavior; the owner flips it after review. | Locked; owner-side follow-up |
| 5 | Verdict `real regression` in Phase 1: stop and notify via `$QUARTET_NOTIFY_CMD`, no auto-fix (shipyard policy: regressions wait for a human). | Locked |

No user-decision-class item is open (nothing spends money, goes public, is
destructive, or alters owner-configured automation: Decision 4 keeps the key
off).

## Traps pinned for this ticket

- **Fleet-live edit:** `agents/release/runner.sh` runs for every installed
  project on the next timer fire. The key defaults off; reason about every
  project's config shape. Work on `main`, small steps, no branch, no worktree
  (CLAUDE.md). A stray detached worktree exists at `.kilo/worktrees/
  cuboid-screwdriver` — do not touch it, do not commit from it.
- **Phase 1 stages a rename in the live install.** Restore it fully; compare
  `git status --porcelain` before and after; never commit it. Check `git status`
  and `git log --oneline -3` first: another session may have uncommitted work —
  scope `git add` to your own files, never `git add -A`.
- **Untracked files vacuously pass leak-check.** Run `git add -N <file>` before
  `bash scripts/leak-check.sh` for any new file.
- **Guard tests must pass pre-change.** The additivity case (Phase 2 step 2)
  must be run against the unmodified runner and pass there.
- **Hard-wrapped prose:** any doc-grep assertion must fit one source line.
- **bats runtime:** ~5 min; use background execution, never two copies at once.

## Phase 1 — Reproduce and classify (3 pts)

**Goal:** verdict `flake` | `dirty-tree-sensitive` | `real regression`, with
failing node IDs.

Steps: (1) `git status --porcelain` must be empty except this ticket. (2) Run
`bats tests/ -t` to a scratchpad file, 2 more times for flake detection (baseline
above is run 1: green). (3) Stage a rename of any
`docs/tickets/pending/*.md` into `docs/tickets/complete/` with `git mv`, run the
suspect files individually (`bats tests/<file>.bats -t`), then the full suite;
record every `not ok`. (4) Restore with `git mv` back / `git reset`, confirm
status identical to step 1. (5) For any dirty-only failure, name the line that
reads the live tree.

Delegation: subagent. **Brief:** You are verifying a suspected dirty-tree-sensitive
bats test in `~/code/shipyard` (read `CLAUDE.md` "Work on main" first; the
checkout is the fleet's live install). Do steps 1–5 above exactly. You own no
tracked files: change nothing that stays after you finish. Write TAP output to
`/tmp/claude-1000/-home-wabbazzar-code-shipyard/63b730fe-2cd3-453f-bb7d-eeae00c8359c/scratchpad/`.
Run bats in the background (it takes ~5 min). **Return ≤40 lines:** files
changed (must be none); commands run + exit codes; every `not ok` with
`file:line`; verdict; evidence lines; blockers. Converge honestly or report the
precise blocker with the actual evidence — NEVER fake green, weaken a check, or
hand-wave "should work". Run the real command, read the real file, curl the real
port, and report exact output (exit codes, JSONL lines, HTTP codes), not
adjectives.

Orchestrator re-verifies personally: rerun the single failing test file (if any)
and `git status --porcelain`.

**Gates:** bats suite; shell scripts. **DoD:** the verdict and evidence are in
the Ledger; `git status --porcelain` before == after.

## Phase 2 — Make gate failures self-identifying (3 pts)

**Goal:** with `failure_excerpt = true` and a non-zero gate exit, the gate
object gains `failedTests`. Unset == byte-identical to today.

Tests (add to `tests/release-blocking-gate.bats`, using `configure_gate` and
`make_stub`; extend `configure_gate` with an optional key line rather than
duplicating it; no network/model):
1. **Failing-first:** stub gate command prints
   `ok 1 a` / `not ok 2 broken thing` / `not ok 3 other` and exits 1, key set;
   assert `jq -c .batsGate` equals
   `{"status":"completed","pass":false,"exitCode":1,"failedTests":["not ok 2 broken thing","not ok 3 other"]}`.
   Run it against the unmodified runner and show it FAIL (config exits 2 on the
   unknown key). Record the output.
2. **Additivity guard:** same stub, key unset: `.batsGate` equals exactly
   `{"status":"completed","pass":false,"exitCode":1}`. Must PASS before and
   after the change.
3. **Unknown key still rejected:** `foo = true` under `[release.blocking_gate]`
   exits 2 with the existing message.
4. **Passing gate with key set:** `.batsGate` has no `failedTests`.
5. **Caps:** 30 `not ok` lines yield 20 entries; a 500-char line is cut to 200.

Implementation: extend the validator at `runner.sh:~121` to allow an optional
`failure_excerpt` boolean (keys must be the four required, plus optionally that
one; reject anything else); tee gate output to a per-run temp file under
`$RESULT_DIR` in addition to `$LOG_FILE` (`runner.sh:481`), delete it
afterward; on non-zero exit with the key true, extract per Decision 3 and add
`failedTests` in the failure `jq` (`runner.sh:556-565`). Document the key at
`docs/OPERATIONS.md:76` (the canonical place that already discusses the blocking
gate; the main README has no `[release.blocking_gate]` row on this checkout,
verified 2026-10-31, so do not invent a parallel explainer). Extend `--check-config`
output only if it already prints the other gate keys.

Delegation: inline (single-file runner edit plus one bats file, each already
read in this ticket; the failing-first ordering is the point and the
orchestrator must read each gate result itself).

**Gates:** `bash -n agents/release/runner.sh`; `bats tests/release-blocking-gate.bats`
then full `bats tests/` (background, ~5 min); `bash agents/release/runner.sh
--check-config` against a fixture config with and without the key (exit 0 / the
bad-key exit 2); `git add -N` then `bash scripts/leak-check.sh`;
`bash scripts/check-deck-fresh.sh`. **DoD:** cases 1–5 pass; case 1 was shown
failing pre-change; full suite 951+new, 0 not ok; one commit on `main`.

## Phase 3 — Fix or close per the Phase 1 verdict (2 pts)

- `flake`: no code change. Record evidence in the Ledger. The ticket then
  graduates through `scripts/ticket-lifecycle.sh --graduate` in the final commit
  (execute-ticket's job).
- `dirty-tree-sensitive`: change the offending test to a fixture
  (`make_fixture_project` / `make_git_topology`). Prove it: with the staged
  rename in place the test passes; run it first against the unfixed test to show
  it fails. Restore the tree.
- `real regression`: stop, notify via `$QUARTET_NOTIFY_CMD`, do not auto-fix.

Delegation: inline (branch taken is verdict-dependent and under ~30 lines).

**Gates:** bats suite; leak-check; delegation contract
(`python3 scripts/delegation-report.py` shows no inline-without-reason).
**DoD:** outcome matches the verdict; final full `bats tests/` exit 0; roll-up
below true.

## Ledger

(builder appends per phase: plan, commit hash, `builder: subagent (<N> agents)` /
`builder: inline (<reason>)`, honest deferrals)

- Phase 1:
- Phase 2:
- Phase 3:

## Roll-up Definition of Done

- [ ] Phase 1 verdict + evidence recorded; tree status before == after.
- [ ] `failedTests` case shown failing pre-change, passing after; additivity
      guard passes both before and after.
- [ ] Unknown `[release.blocking_gate]` keys still exit 2.
- [ ] `docs/OPERATIONS.md` documents `failure_excerpt`; `.agents/config.toml`
      unchanged (Decision 4).
- [ ] Phase 3 outcome matches verdict.
- [ ] `bats tests/`, `bash scripts/leak-check.sh`, `bash scripts/check-deck-fresh.sh`,
      and the `bash -n` sweep are green on `main`; `git status` clean; no stray
      background bats or worktree links (`ls -l ~/code/*/.claude/skills/ | grep -c
      worktrees` → 0).

## Out of scope

Rewriting or splitting the bats suite; changing medic classification; any other
`[release.blocking_gate]` behavior; enabling the new key in the live config.

## Run it

`execute-ticket docs/tickets/pending/diagnose-proctor-bats-gate-exit-1.md`
(not run: owner said do not build).
