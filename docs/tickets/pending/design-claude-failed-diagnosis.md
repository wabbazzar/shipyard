# Make design `claude_failed` diagnosable, and make a repeating one visible

- **Created:** 2026-10-01
- **Owner:** wabbazzar
- **Status:** Pending — polished, ready for `execute-ticket`
- **Priority:** med
- **Type:** bugfix
- **Estimated Points:** 5 (three phases: 2 · 2 · 1)
- **Refs:** approved Daily Dispatch item `mentat:shipyard:5f92390d`;
  `agents/design/runner.sh:284-290` (`finish`), `:346-359` (spawn + fail path),
  `agents/lib/spawn.sh:22-98` (stall retry), `agents/lib/post-run.sh:52-99`
  (`agent_finish`), `[[medic.checks]]` in `.agents/config.toml`,
  `tests/design.bats`, `tests/harness-spawn-retry.bats`

## Goal

Answer, with evidence, *why* shipyard-mentat reported `claude_failed`, and close
the two gaps that let it happen four days running unseen: (1) the runner throws
away everything that would identify the cause, (2) nothing alerts on a repeating
design failure. Do **not** change design's proposal-output contract
(`agents/design/runner.sh` merge/dedup/`mentat-result.json` shape) or the
telemetry collectors (`agents/design/collectors.sh`).

## Findings (measured 2026-10-01; commands reproducible)

Events = `$QUARTET_EVENTS_DIR/*.jsonl` (hub stream; resolve from
`systemctl --user show shipyard-mentat.service -p Environment --value`).

```bash
cat "$QUARTET_EVENTS_DIR"/*.jsonl | jq -c 'select(.svc=="shipyard-mentat" and .event=="job.end")' \
  | jq -r '[.status,(.reason//"-")]|@tsv' | sort | uniq -c
```

Baseline: **5 `fail claude_failed` · 42 `ok` · 23 `skipped open_cap`.** The
failures are 2026-08-20 (2 s) and **four consecutive daily runs 2026-09-19 →
09-22** (each `duration_s` 6–7). 2026-09-23 was `ok`; the last 8 runs
(09-24 → 10-01) are `skipped open_cap`. So the proposal's "4 of last 5" was true
of a window that has since closed; **the failure is not currently recurring.**
Do not build a fix that assumes it still is.

Signature, by elimination (code + data, not guess):

| Candidate | Verdict | Evidence |
|---|---|---|
| Wrapper timeout | **Impossible** | `agents/design/runner.sh:346-352` passes no `--timeout`; `spawn.sh:173` only adds `timeout` when set. Timeout is rc 124, which `_run_harness` returns untouched (`spawn.sh:79`). |
| Token cap | **Impossible** | design passes no token cap to the CLI; its budget gate fires *before* spawn and emits `reason=budget`, never `claude_failed` (`runner.sh:293-299`). |
| Transient stall, retries exhausted | **Ruled out** | `SPAWN_STALL_RETRIES` default 2 sleeps 5 s + 15 s (`spawn.sh:29,84-93`). open_cap runs (no model call) take 3–4 s of collectors; failed runs took 6–7 s, so the claude segment was ≈2–3 s — no backoff slept. |
| **Fast non-stall failure** | **Consistent** | `runner.sh:355` fires on `rc != 0` **or empty stdout**. A CLI that exits non-zero (or prints nothing) within ~2 s and whose stderr does not match `_SPAWN_STALL_RE` is terminal on attempt 1 (`spawn.sh:84`). Typical members: auth/login expiry, usage/credit limit, invalid flag, immediate network refusal. |

**The exact member is unrecoverable from retained data** and this ticket must not
pretend otherwise. Reason: `runner.sh:277` truncates the log
(`echo … > "$LOG_FILE"`) at every start, so `tmp/shipyard-mentat-last-run.log`
holds only the latest (open_cap) run; the failure path (`:355-358`) records
neither `rc` nor stderr in `job.end`. That loss — not any model behavior — is the
defect. (Cross-check done: medic never ran for these days — see below.)

### Why nobody noticed

`finish()` (`runner.sh:284-290`) calls `emit_event job.end` directly and
`exit 0`; it never goes through `agent_finish` (`post-run.sh:52`), the only path
that escalates `status=fail` to `medic --mode post-run`. build/release/scribe use
`agent_finish`; design does not. Exit 0 also means systemd shows the unit
`Finished`, so unit-failure scans see nothing. Four silent failures followed.

### Should `crew-install-drift` flag repeated design failure? — **No (locked)**

`install.sh --doctor` is a read-only, <1 s *static* conformance audit (units,
symlinks, config keys, hooks — filesystem state). A repeated `job.end` failure is
*runtime telemetry*; folding it into `--doctor` would mix two jobs, and `--doctor`
is also run by `ice` and other projects, so a runtime signal there is fleet-wide
noise. The right home is a **separate** `[[medic.checks]]` entry (the existing
notify-only check mechanism, `runner.sh` of medic ≈ line 627-660) backed by a
tiny read-only streak script. Phase 1 re-proves the "doctor reads no events"
premise with a grep before building on it.

## Decisions

### Locked decisions

| Decision | Locked result |
|---|---|
| `reason` token | `reason=claude_failed` is unchanged and stays the only `reason` value on this path. Collectors/Mentat consume it (`surface-design-job-end-failure-reasons`). New detail rides in **new** keys only. |
| Collectors + proposal contract | `agents/design/collectors.sh` and the proposal merge/dedup/result-file code (`runner.sh` from `# --- merge proposals` onward) are **not edited**. Phase gate asserts it. |
| Detail fields | When enabled, the `claude_failed` `job.end` gains `exit_code=<rc>` and `cause=<class>`; `cause ∈ {empty_output, stall_exhausted, timeout, exit_nonzero}` decided deterministically: rc 0 + empty → `empty_output`; rc 124 → `timeout`; stderr+stdout match `_SPAWN_STALL_RE` → `stall_exhausted`; else `exit_nonzero`. No free text in the event. |
| Durable failure record | When enabled, the failure path also appends one block (ts, rc, cause, first 20 lines of stderr/stdout, `[spawn]` retry lines) to `tmp/<svc>-last-failure.log`, which no later run truncates. It lives under `[paths] result_dir` (gitignored), never in the event stream. |
| Config gate | New key `[design] failure_detail` (bool). **Unset/false ⇒ byte-identical `job.end` and no new file** — proven by a bats case run against pre-change code. |
| Streak check | New read-only `agents/lib/job-fail-streak.sh` (`--svc`, `--threshold N`, `--events-dir`); exit 0 when the svc's most recent consecutive `job.end status=fail` run is `< N`, exit 1 with a one-line reason when `>= N`; skipped/ok break the streak only for `ok`, **`skipped` is neutral**. Wired as an opt-in `[[medic.checks]]` entry, notify-only. |
| Not changed | design's lack of `--timeout`/token cap (see Open decisions), `agent_finish` routing for design, `install.sh --doctor`. |
| Branching | Work on local `main` in the canonical checkout (CLAUDE.md: no branches/worktrees here). Scope every `git add` to this ticket's files; the tree currently has an unrelated staged rename. |

### Open decisions with defaults (builder applies, records in Ledger, proceeds)

1. **Enable the new behavior on shipyard's own install?** Default: **no.**
   Ship the key off; do not edit the gitignored `.agents/config.toml`. Print the
   two lines the owner would add (`failure_detail = true` under `[design]`, and
   the `job-fail-streak` check block) in the final report.
2. **Streak threshold.** Default `2` consecutive design failures (the incident
   was 4; 1 is a stall-class blip the retry already covers).
3. **Check name.** Default `design-fail-streak`.

### User-decision class — carved out, NOT decided here

- **design has no wall-clock timeout or token cap** (`runner.sh:343-345` says so
  deliberately), which conflicts with the gate "Model-invocation caps". Adding
  either changes live automation the owner deliberately configured. This ticket
  records it as a follow-up in the Ledger and changes nothing. Builder assumption
  on every phase: the spawn call stays exactly as is.
- Routing design failures through `agent_finish` (medic auto-escalation) would
  change medic's fleet-wide incident volume. Not done here; the notify-only
  streak check is the conservative substitute.

No decision here blocks the build.

## Specialists and memory

`.agents/specialists/` is absent → no specialist routing. `.agents/config.toml`
has no `[memory]` table → no planning-memory query (legacy flow, zero added
calls).

## Phase protocol (all phases)

The builder is an **orchestrator**: delegate by default, keep context lean,
re-verify personally. Every subagent brief ends with:

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

Return shape for every subagent: **≤40 lines — files changed; commands run + exit
codes; evidence lines; blockers.** Longer evidence goes in the Ledger.

Gate classes that apply to **every** phase (`.agents/gates.md`): shell
(`bash -n` on touched scripts, then run them), bats (new case **shown failing on
pre-change code first**), config-gated additivity, public-repo hygiene
(`git add -N` any new file **before** `bash scripts/leak-check.sh` — a clean run on
an untracked file is vacuous). Not applicable: served app, systemd unit
generation (no `install.sh` change), deck coupling (no SKILL.md / `GENERIC_SKILLS`
edit). Fleet-live reminder: `agents/lib/**` and `agents/design/runner.sh` run on
every installed project's next timer fire — reason about each project's config
shape, and the unset path must be byte-identical.

Toolchain verified while polishing (2026-10-01): `bats --version` → 1.10.0;
`bats tests/design.bats tests/harness-spawn-retry.bats` → all pass (20 in the
latter file's tail); `jq`, `python3` present. Stub a model with `make_stub claude`
from `tests/helpers.bash`; no test may touch the network or a model.

## Phase 1 — Pin the signature with failing tests (2 pts)

**Delegation: subagent** (one agent; owns `tests/design-claude-failed.bats` — new
file is justified: `tests/design.bats` is collector-focused and this file pins
runner failure semantics; extend `tests/design.bats` instead if it has a
`run_runner` design fixture that fits in <30 lines).

Brief: *Inputs:* this ticket's Findings table; `tests/helpers.bash`
(`make_stub`, `make_fixture_project`, `run_runner`); `tests/harness-spawn-retry.bats`
as the stub-pattern model. *Task:* (a) `grep -n 'events\|job.end' install.sh` and
record whether `--doctor` reads the event stream (expected: no — if it does,
STOP and report; the "No" decision above is invalidated). (b) Add bats cases that
run the design runner against a `claude` stub for four modes and assert the
**current** `job.end`: rc=1 stderr `Credit balance is too low`; rc=0 empty stdout;
rc=1 stderr `Response stalled mid-stream` with `SPAWN_STALL_RETRIES=0`; rc=124.
Assertions for the *new* behavior (`exit_code=`, `cause=` with `failure_detail=true`;
`tmp/<svc>-last-failure.log` containing the stub's stderr line) **must fail on
today's runner** — capture that red output. Add the **guard** case: with the key
unset, the `claude_failed` `job.end` line is byte-for-byte what pre-change emits
(`{"…","status":"fail","duration_s":N,"reason":"claude_failed"}` modulo ts/dur);
this guard **must pass on pre-change code** (a guard that fails pre-change
asserts nothing). *Return:* red-run excerpt per new case, green guard excerpt.

DoD: `bats tests/design-claude-failed.bats` → new-behavior cases red, guard green
on the unmodified runner; `git diff --stat` touches only the test file.

## Phase 2 — Gated diagnostics in the design failure path (2 pts)

**Delegation: inline** — one function and one config read in an already-read file,
~30 lines in `agents/design/runner.sh`.

Edit only the `claude_failed` branch (`runner.sh:355-358`) and a config read
(`jq_from_json "$CFG_JSON" -r '.design.failure_detail // false'`). Classify per
the locked rule using `_SPAWN_STALL_RE` (already sourced via `spawn.sh`); append
the failure block *before* `finish`; pass `exit_code=… cause=…` to `finish fail
reason=claude_failed` only when enabled. Do not move or edit any line below
`# --- merge proposals`. Add `failure_detail` to `--check-config` output if the
runner prints design keys there, and document the key in the README config table
(update the existing table; no parallel doc).

Verification surface:
- `bash -n agents/design/runner.sh`
- `bats tests/design-claude-failed.bats` → all green (the Phase 1 red cases now pass)
- `bats tests/design.bats tests/harness-spawn-retry.bats tests/token-caps.bats` → green, **unmodified**
- `git diff --stat -- agents/design/collectors.sh` → empty
- Unset-key byte identity: guard case from Phase 1 still green.
- Real run: `bash agents/design/runner.sh --project . --collect-only >/dev/null; echo $?` → 0
  (no model; confirms the runner still parses).

DoD: failing → passing for each of the four modes with `failure_detail=true`;
a live-shaped `job.end` line from the stub run contains `"cause":"exit_nonzero"`
and `"exit_code":1`; with the key unset no `tmp/*-last-failure.log` is created.

## Phase 3 — Repeated-failure visibility + roll-up (1 pt)

**Delegation: subagent** — owns `agents/lib/job-fail-streak.sh` and its bats case.

Brief: *Inputs:* locked "Streak check" decision; how `[[medic.checks]]` entries
are executed (`agents/medic/runner.sh` ≈ lines 26 and 627-660: env exported,
timeout, notify-only, cooldown); `tests/medic-transient-cooldown.bats` as the
two-scan pattern. *Task:* implement the read-only script (`set -uo pipefail`,
unknown arg → exit 2, no network, no writes); tests: fail,fail → exit 1; fail,
skipped, fail → counts 2; fail,ok → 0; threshold override; empty/missing events
dir → exit 0; malformed JSONL line tolerated. Replay the real stream read-only:
with `--svc shipyard-mentat --threshold 2 --events-dir "$QUARTET_EVENTS_DIR"` the
script must exit **0 today** (latest run is `skipped`, previous consecutive fail
run ended 09-22 and was broken by the 09-23 `ok`) and exit 1 against a fixture
copy of 09-19→09-22. Wire it as an *example* check block in the README /
`docs/ADAPTING.md` canonical check section (not into any live config). **Two-scan
test**: with the check failing, two consecutive medic scans notify at most once
(Traps: every notify path must record a cooldown) — if the existing checks path
lacks a cooldown, report it as a blocker rather than adding one silently.

DoD: `bash -n agents/lib/job-fail-streak.sh`; new bats green; real-stream replay
exit 0; fixture exit 1.

### Final gate (Phase 3 closes with this)

```bash
bats tests/                                     # full suite, ~80s
bash scripts/leak-check.sh                      # after git add -N of new files
bash scripts/check-deck-fresh.sh
bash -n install.sh agents/lib/*.sh agents/*/runner.sh agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py
git diff --stat main~N -- agents/design/collectors.sh   # empty (N = commits in this ticket)
```

Then update the existing README (config table: `[design] failure_detail`; check
example) and run `check-deck-fresh.sh` again; if README claims changed, update the
deck prose in `docs/deck-editorial.json` (never the generated JSON) and
regenerate. Read the CI result before calling the baseline green. Roll-up DoD:
all phases committed, tree clean of this ticket's files, all gates green, no
background processes started, no live config edited.

## Ledger

- Phase 1+2 (2026-10-01): `builder: subagent (1 agent)` for tests; `builder: inline (single runner branch ~20 lines)` for runner. Doctor premise re-proved: `install.sh` has no event-stream read (only an echo at :1014). Red→green on 4 `failure_detail` cases; unset-key guards green pre- and post-change. Baseline `bats tests/` 925 green. Doc row added to `docs/INSTALL.md` config table.

(builder appends: plan + commit hash per phase, `builder: subagent (N agents)` /
`builder: inline (<reason>)`, auto-decided open decisions, and the follow-up
"design has no timeout/token cap — owner decision" note.)

Run with `execute-ticket`: `docs/tickets/pending/design-claude-failed-diagnosis.md`.
