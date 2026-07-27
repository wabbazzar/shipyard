# Delegation Plan: make per-phase subagent use a designed, enforced, measured artifact

- **Created:** 2026-07-27
- **Owner:** wabbazzar
- **Status:** polished — ready for `execute-ticket`
- **Priority:** high
- **Type:** feature
- **Estimated Points:** 14 (7 phases, cap 5/phase)
- **Refs:** `skills/{execute,write,polish}-ticket/SKILL.md`, `skills/{feature,bugfix}/SKILL.md`,
  `install.sh:120` (`GENERIC_SKILLS`), `install.sh:755` (skill symlink step),
  `.agents/gates.md`

## Goal

Delegation to subagents is the highest-leverage cost lever in the ticket
pipeline and the only step in it with **no trigger condition, no default, no
artifact, and nothing checkable**. Make it a first-class per-phase artifact — a
**Delegation Plan** — that `write-ticket` drafts, `polish-ticket` hardens into
concrete briefs, `execute-ticket` obeys and records in the Ledger, and the front
doors (`/feature`, `/bugfix`) apply to their own investigation sweeps. Ship a
measurement script so "context bloat went down" is provable against a recorded
baseline rather than asserted.

## Problem / Background — the measured baseline (acceptance anchor)

**Measured 2026-07-27** across all 20 `execute-ticket` sessions in the Claude
Code transcript store. Attribution rule (reimplement exactly in Phase 1): every
assistant message from the first *real* `execute-ticket` invocation — a `Skill`
tool_use with `input.skill == "execute-ticket"`, or a user message containing
`<command-name>execute-ticket` — through end of session. **Do not** match the
bare string `execute-ticket`: it appears in the skills listing inside every
session's system-reminder and inflates the result to 82%.

| Metric | Baseline (2026-07-27) |
|---|---|
| execute-ticket sessions | 20 |
| assistant turns | 8,618 |
| orchestrator output tokens | 9.68 M |
| cache-read (context re-carry) | 2.92 B |
| **cost-equivalent split** | **cache-read 292 M-equiv (86%) vs output 48 M-equiv (14%)** |
| avg context per turn | 339 k |
| turns above 300 k context | 4,575 (53%), carrying 72% of all context reads |
| peak context (worst sessions) | 812 k / 731 k / 724 k / 681 k |
| `Agent` tool calls, all sessions | **42** |
| sessions using **zero** subagents | **10 of 20** |
| `Read` share of tool-result bytes | 13.47 MB = **84.7%** |
| `Read` calls / avg / >60 KB / largest | 485 / 27.8 KB / **77** / **630 KB** |
| `Agent` avg bytes returned | 2.2 KB — **~12× cheaper per unit of information** |

Cost-equivalent weights: input ×1, cache-write ×1.25, cache-read ×0.1, output
×5 (Opus ratios, not billing). Bake these as named constants in Phase 1.

**Reading of the baseline.** 86% of `execute-ticket`'s cost is re-carrying its
own context, not producing work. The proximate cause is `Read` (85% of bytes in,
77 results over 60 KB). The fix already exists and already works — `Agent`
returns 2.2 KB where `Read` returns 27.8 KB — it is simply almost never reached
for, and in half of all sessions never at all.

**Root cause — the instruction is advisory and traceless.** In
`skills/execute-ticket/SKILL.md` §2: §2.4 QA is *"MANDATORY, every phase, all
gates the ticket names"* + a named class list → **obeyed** (2,449 `Bash` calls).
§2.2 delegation is *"Delegate heavy/wide work … to subagents"* → advisory verb,
no trigger, no default, no recorded output → **ignored**. Every other obligation
in shipyard leaves a trace (Ledger line, commit hash, `job.end` JSONL); this one
leaves none.

**Why upstream matters.** `subagent` appears **zero times** in
`skills/write-ticket/SKILL.md`, `skills/feature/SKILL.md`,
`skills/bugfix/SKILL.md`; and only as advisory prose in
`skills/polish-ticket/SKILL.md:37` and `:75-77` (§B). The builder is asked to
improvise a delegation strategy at build time, under context pressure, on a
ticket that never budgeted one.

**Mechanism to consume, not duplicate.** `install.sh:79-80` already writes a
"delegate to specialists" table into `<project>/.agents/build.md` from checked-in
`.claude/agents/*.md`, and `skills/coverage-audit/SKILL.md:192-207` generates
one. `tests/specialist-archetype.bats` + `tests/shipyard-add-specialist.bats`
cover it. The registry of *who* to delegate to exists; no pipeline step uses it.
(shipyard itself has **no** `.claude/agents/` — the consuming code must handle
absence.)

## Context / pointers (read these; do not guess)

| What | Where |
|---|---|
| Gate menu + Traps | `.agents/gates.md` |
| Config (trunk `main`, `test_cmd`, `typecheck`, `can_merge=false`) | `.agents/config.toml` |
| House rules, fleet-live warning | `CLAUDE.md` |
| Skill list shipped to projects | `install.sh:120` `GENERIC_SKILLS` |
| Skill symlink step (fleet-live) | `install.sh:755` |
| Test helpers (`make_stub`, `$QUARTET_ROOT`) | `tests/helpers.bash` |
| Precedent for asserting on SKILL.md content | `tests/shipyard-status.bats:35-37` |
| Deck generator (do **not** need to run it) | `scripts/gen-deck-data.py` |

**Green baseline, measured 2026-07-27 on this box (record; compare against it):**

```
bats tests/                       → 274 tests, 0 failures, 57.6s real
bash scripts/check-deck-fresh.sh  → "check-deck-fresh: deck is in sync", rc=0
bash -n <syntax sweep> && python3 -m py_compile scripts/gen-deck-data.py → rc=0
bash scripts/leak-check.sh        → "leak-check: clean", rc=0
python3 -VV                       → Python 3.12.3
```

Note the drift: `CLAUDE.md` claims "273 tests, ~23s"; actual is **274 / 57.6s**.
Phase 6 corrects that line — it is in scope precisely because a stale gate
description is how a real regression gets waved through.

## Orchestration protocol (the builder is an orchestrator)

Keep your context lean; delegate heavy/wide work with tight briefs; **re-verify
everything yourself before every commit** — never trust a subagent's "green".
Hand every subagent this clause verbatim:

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

This ticket dogfoods its own artifact: **every phase below carries a
`Delegation:` line, and the builder appends a matching `builder:` line to the
Ledger.** If the operating context forbids subagents, that is a legitimate
`inline` — but the reason must be *recorded*, not omitted. An `inline` with no
stated reason is the exact defect this ticket exists to kill.

## The artifact being introduced

Per phase in a ticket:

```
Delegation: subagent — <one-line brief: what it gets, what it returns>
Delegation: inline (<reason drawn from the exception list>)
```

Per phase in the Ledger, appended by the builder:

```
builder: subagent (<N> agents) | inline (<reason>)
```

**Exception list — the only legitimate reasons for `inline`:**
1. a single-file edit in a file already read;
2. a gate command whose output the orchestrator must read itself to satisfy
   verify-before-commit;
3. a change under ~30 lines;
4. an operating constraint that forbids subagents (record it verbatim).

**Return-shape contract** every brief imposes: ≤ 40 lines — files changed;
commands run + exit codes; evidence lines (JSONL / HTTP code / test counts);
blockers. Longer evidence goes in the ticket Ledger, not the orchestrator's
context.

**Read discipline** (the rule that moves the 85%): the orchestrator never Reads
to explore. More than two `Read`s to answer one question, or any `Read` of a file
over ~500 lines → that is a subagent brief. Ask for the answer, not the file.

## Decisions

### Locked (do not re-litigate)

| # | Decision | Rationale |
|---|---|---|
| L1 | Prose-only changes to skill bodies; **no frontmatter, no `GENERIC_SKILLS` change** | Keeps `docs/shipyard-data.json` byte-identical; any deck diff is a defect in this ticket |
| L2 | No new config key | The consumed registry (`.agents/build.md` specialist table) already exists; adding a knob whose unset value is today's behavior would make the default *non*-delegation, defeating the ticket |
| L3 | `verify-before-commit` (`execute-ticket` §2.5) is untouched and reaffirmed | Delegation must not become a laundering path for unverified work |
| L4 | Measurement lands **before** behavior change (Phase 1 first) | A baseline recorded by the same script that will judge the outcome |
| L5 | Owner authorized the fleet-live skill change (2026-07-27, this session) | `install.sh:755` symlinks skills into all 6 installed projects; `can_merge=false` + human PR stamp + green CI remain the wall |
| L6 | Thresholds live in the ticket, not in code | Phase 7 is a judgment checkpoint, not an automated gate that could be tuned to pass |

### Open, with defaults (builder applies and records — never blocks)

| # | Question | Default to apply |
|---|---|---|
| O1 | Phase 7 threshold values | The six in Phase 7 as written |
| O2 | Inline threshold "~30 lines" | Keep as a soft heuristic in prose, not a hard number in a test |
| O3 | Report output format | Human table by default; `--json` for machine use |
| O4 | Report default window | 30 days; `--days N` / `--all` to override |
| O5 | `execute-ticket` §2.2 wording | The patch drafted in this session's analysis, adapted to fit surrounding prose |

### User-decision class

**None.** Nothing here spends money, is outward-facing, is destructive, or is a
design fork with no sensible default. L5 is authorized by the invocation.
→ **Auto-gate PROCEEDS to `execute-ticket`.**

## Traps to pin (from `.agents/gates.md` + discovered while polishing)

- **Fleet-live edits.** `skills/*` are symlinked into every project's
  `.claude/skills/` (`install.sh:755`) — an edit is live for all 6 installed
  projects at the next timer fire. No staging, no per-project copy.
- **NEW — `leak-check.sh` scans `git ls-files` only** (`scripts/leak-check.sh:39`).
  An **untracked** new file is silently skipped, so a clean run on a new file is
  vacuous. Every phase adding a file must `git add -N <file>` (or stage it)
  before running leak-check. *(Discovered 2026-07-27 while polishing this ticket;
  Phase 6 adds it to the gate file's Traps appendix.)*
- **Deck coupling.** Frontmatter/`GENERIC_SKILLS` are untouched (L1), so
  `check-deck-fresh.sh` must remain byte-identical. A diff there = defect.
- **Hermetic tests.** No bats case may reach the network, GitHub, a model, or
  **the real transcript store**. Phase 1's tests synthesize fixture transcripts
  in a temp dir and point the script at them via `CLAUDE_PROJECTS_DIR`.
- **No home-path literals** anywhere (`leak-check`): transcript root resolves as
  `${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}`.
- **Post-merge determinism.** `[release] test_cmd`/`typecheck` run verbatim and
  eval'd — nothing added here may make them interactive or network-dependent.

## Phases

Each phase = one clean commit, `git add <files>` explicitly (never `-A`),
Co-Authored-By trailer, `git status` clean before moving on.

---

### Phase 1 — Measurement harness + recorded baseline (3 pts)

**Delegation:** subagent — brief: "write `scripts/delegation-report.py` to spec
§Phase 1 + `tests/delegation-report.bats` with synthesized fixture transcripts;
return the file diff summary, `bats tests/delegation-report.bats` output, and the
script's run against the real store." Return shape: ≤40 lines.

**Slice.** Create `scripts/delegation-report.py`:
- Transcript root: `${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}`, glob `*/*.jsonl`.
- Attribution exactly as specified in Problem/Background (Skill tool_use with
  `input.skill == "execute-ticket"`, or `<command-name>execute-ticket` in a user
  string message). **Never** the bare-substring match.
- Emit: sessions; turns; output tokens; cache-read; cost-equivalent split using
  named weight constants; avg + peak context/turn; count and % of turns >300 k;
  `Agent` call count; sessions with zero `Agent` calls; per-tool returned bytes
  with share and average; count of results >60 KB and the largest.
- Once Phase 2 lands, also count Ledger `builder:` lines by kind across
  `docs/tickets/*.md` (absent section → report 0, never crash).
- Flags: `--days N` (default 30), `--all`, `--json`, `--skill <name>`
  (default `execute-ticket`).
- Pure stdlib. No network. Read-only.

Create `tests/delegation-report.bats`: a temp `CLAUDE_PROJECTS_DIR` with
hand-written fixture JSONL — (a) a session that never invokes the skill →
excluded; (b) a session whose only mention is the bare string in a
system-reminder → **excluded** (this is the case that proves the attribution
rule); (c) a real `Skill` invocation → included, with known token counts so the
asserted totals are exact; (d) a session with `Agent` calls → zero-agent count
excludes it. Use `make_stub`/`$QUARTET_ROOT` per `tests/helpers.bash`.

**Gate classes:** Shell · bats · Public-repo hygiene.
**Exact commands:**
```bash
bash -n scripts/delegation-report.py 2>/dev/null || true   # not shell; skip
python3 -m py_compile scripts/delegation-report.py
python3 scripts/delegation-report.py --all                 # real store
python3 scripts/delegation-report.py --all --json | python3 -m json.tool >/dev/null
bats tests/delegation-report.bats
git add -N scripts/delegation-report.py tests/delegation-report.bats
bash scripts/leak-check.sh
bats tests/
```
**Observable DoD:**
- `python3 scripts/delegation-report.py --all` prints sessions=20, zero-agent
  sessions=10, Agent calls=42, `Read` share ≈84.7% — the baseline table
  reproduced within rounding. Any material divergence is a bug in the script,
  not a new baseline.
- `bats tests/delegation-report.bats` — all pass; fixture case (b) proves the
  bare-substring trap is avoided (assert it reports 0 sessions, not 1).
- `leak-check` clean **with the new files `git add -N`'d** (see Traps).
- `bats tests/` still 274+ passing, 0 failures.

---

### Phase 2 — `execute-ticket`: delegation as the default, with a trace (2 pts)

**Delegation:** inline (single-file prose edit in a file already read —
exception 1).

**Slice.** Rewrite `skills/execute-ticket/SKILL.md` §2.2 to invert the default:
delegate unless on the exception list; add the two hard rules (no exploratory
Read; ≤40-line return shape); require the `builder:` Ledger line in §2.6; add a
Non-negotiable ("Delegate by default — an inline phase with no recorded reason
is a defect"). Keep the verbatim anti-cheating clause and §2.5 untouched;
reaffirm §2.5 explicitly in the new text.

Create `tests/delegation-contract.bats` with the Phase-2 cases (Phases 3–5
append to this same file).

**Gate classes:** bats · Public-repo hygiene · Deck coupling (must show no diff).
**Exact commands:**
```bash
git stash && bats tests/delegation-contract.bats ; git stash pop   # MUST fail first
bats tests/delegation-contract.bats
bats tests/
bash scripts/check-deck-fresh.sh
bash scripts/leak-check.sh
```
**Observable DoD:**
- The contract cases are **shown failing against pre-change
  `execute-ticket/SKILL.md`** and the failing output is pasted into the Ledger
  (repo test convention). A case that cannot fail is a finding, not a test.
- After the edit: `bats tests/delegation-contract.bats` green; `bats tests/` green.
- `check-deck-fresh.sh` prints "deck is in sync" (byte-identical, no regen).

---

### Phase 3 — `write-ticket`: draft the Delegation Plan (2 pts)

**Delegation:** inline (single-file prose edit — exception 1).

**Slice.** `skills/write-ticket/SKILL.md`: Step 4 template gains a per-phase
`Delegation:` line (intent only — a one-line brief sketch, not a hardened brief);
Step 3 gains "interrogate via subagent sweep, not bulk Read"; Anti-patterns gains
"a phase with no Delegation line". Preserve the three-skill separation this repo
enforces — write-ticket names intent, polish-ticket writes the brief.

**Gate classes / commands:** as Phase 2 (contract cases appended to
`tests/delegation-contract.bats`, shown failing first).
**Observable DoD:** contract case asserting `Delegation:` in the Step 4 template
fails pre-change, passes post-change; `bats tests/` green; deck in sync; leak
clean.

---

### Phase 4 — `polish-ticket`: harden plans into briefs (2 pts)

**Delegation:** inline (single-file prose edit — exception 1).

**Slice.** `skills/polish-ticket/SKILL.md` §B becomes: for every phase, convert
the `Delegation:` intent into a concrete self-contained brief (inputs, exact
question, return shape, verbatim anti-cheating clause) **or** an
exception-listed `inline` + reason. Consume `<project>/.agents/build.md`'s
specialist table when present and name the specialist in the brief; **handle its
absence** (shipyard has none). §H Ledger gains the `builder:` field.

**Gate classes / commands:** as Phase 2.
**Observable DoD:** contract cases (brief-hardening + `builder:` Ledger field +
graceful absence of a specialist table) fail pre-change, pass post-change;
`bats tests/` green; deck in sync; leak clean.

---

### Phase 5 — Front doors: `/feature` and `/bugfix` (2 pts)

**Delegation:** inline (two single-file prose edits, each well under 30 lines —
exceptions 1 + 3).

**Slice.** `skills/feature/SKILL.md` Step 1 (assumption probes) and
`skills/bugfix/SKILL.md` steps 1 (reproduce) and 3 (falsify rival causes) are
wide read sweeps run inline today, bloating context *before* a ticket exists.
Each gains: run the sweep as a subagent under the return-shape contract; the
front door keeps the verdict, not the file dumps. **The reproduction stays
first-class** — `/bugfix` still may not emit a ticket without one, and the
subagent must return the actual failing output, not a summary of it.

**Gate classes / commands:** as Phase 2.
**Observable DoD:** contract cases for both files fail pre-change, pass
post-change; a case asserts `/bugfix`'s "no reproduction = no ticket" rule is
still present verbatim (guard against weakening it while editing);
`bats tests/` green; deck in sync; leak clean.

---

### Phase 6 — Gate class + docs + full battery (2 pts)

**Delegation:** inline (small edits across gate/doc files, each under 30 lines —
exception 3).

**Slice.**
- Add a **Delegation contract** gate class to `skills/gates.md.template` and to
  this repo's `.agents/gates.md`: "any ticket phase declares `Delegation:`; any
  Ledger phase records `builder:`; an `inline` states a reason from the exception
  list."
- Add the **leak-check-scans-tracked-files-only** trap (discovered 2026-07-27) to
  the gate file's Traps appendix.
- Document the artifact in `docs/ADAPTING.md` and `README.md`.
- Correct `CLAUDE.md`'s stale "273 tests, ~23s" to the measured current value.

**Gate classes:** ALL.
**Exact commands:**
```bash
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py scripts/delegation-report.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
node scripts/check-deck-render.mjs        # exit 3 = playwright absent = SKIP, not failure
./install.sh --doctor --project .
git status --short
```
**Observable DoD:** every command above green (`--doctor` exit 0;
`check-deck-render` exit 0 or 3); `git status --short` empty; the corrected test
count in `CLAUDE.md` matches the actual `bats tests/` output.

---

### Phase 7 — Outcome verification against the baseline (1 pt, TIME-DEFERRED)

**Delegation:** inline (a single report run + a Ledger append — exception 2).

**This is the only phase that proves the ticket's actual goal, and it cannot
complete at merge time.** It requires real post-change runs.

**Trigger:** after **≥5** real `execute-ticket` sessions have run post-merge
(interactive or headless build crew). Command:
```bash
python3 scripts/delegation-report.py --days 30
```

**Thresholds (default O1; a miss reopens the ticket with evidence — weakening a
threshold is cheating the gate, per the honest-blocker protocol):**

| Metric | Baseline 2026-07-27 | Target |
|---|---|---|
| sessions using zero subagents | 50% | ≤ 10% |
| avg context per turn | 339 k | ≤ 200 k |
| turns above 300 k context | 53% | ≤ 25% |
| cache-read share of cost-equiv | 86% | ≤ 70% |
| ticket phases recording `builder: subagent` | n/a | ≥ 70% |
| `Read` share of returned bytes | 85% | ≤ 60% |

**Observable DoD:** the report's post-change table appended to the Ledger beside
the baseline, each threshold explicitly marked **met / missed** with its number.
Fire a completion notify: `"$QUARTET_NOTIFY_CMD" "delegation-plan-pipeline" "<result>"`.

---

## Testing Strategy

- `tests/delegation-contract.bats` — per skill file, assert the required contract
  anchors (delegation default, exception list, return-shape, `builder:` Ledger
  field, and the preserved `/bugfix` no-repro rule). Every case **shown failing
  against pre-change files first**, with the failing output recorded in the
  Ledger.
- `tests/delegation-report.bats` — the measurement script against synthesized
  fixture transcripts; hermetic via a temp `CLAUDE_PROJECTS_DIR`. Includes the
  negative case proving the bare-substring attribution trap is avoided.
- Existing battery unchanged and green throughout.

## Roll-up Definition of Done

- [ ] All 7 phases committed, `git status` clean in `~/code/shipyard`.
- [ ] `python3 scripts/delegation-report.py --all` reproduces the 2026-07-27
      baseline; `bats tests/delegation-report.bats` hermetic and green.
- [ ] `execute-ticket` delegates **by default** with a named exception list and a
      `builder:` Ledger trace.
- [ ] `write-ticket` emits a `Delegation:` line per planned phase.
- [ ] `polish-ticket` hardens every `Delegation:` intent into a brief (or an
      exception-listed `inline` + reason), consuming `.agents/build.md`
      specialists when present and tolerating their absence.
- [ ] `/feature` and `/bugfix` run their investigation sweeps as subagents;
      `/bugfix`'s no-reproduction rule intact.
- [ ] Delegation contract gate class + the leak-check trap in `.agents/gates.md`
      and `skills/gates.md.template`; documented in `ADAPTING.md` + `README.md`;
      `CLAUDE.md` test count corrected.
- [ ] `verify-before-commit` unchanged and still required.
- [ ] Full battery green: `bats tests/`, syntax sweep, `leak-check.sh`,
      `check-deck-fresh.sh` **byte-identical**, `install.sh --doctor --project .`
      exit 0, `check-deck-render.mjs` exit 0 or 3.
- [ ] Every phase's Ledger entry carries a `builder:` line (this ticket
      dogfoods its own artifact).
- [ ] Phase 7 comparison appended after ≥5 post-merge runs, thresholds marked.

## Dependencies

None blocking. Phase 7 is gated on real post-merge usage, not on other work.

## Risks & Mitigations

- **Fleet-live blast radius** — `install.sh:755` symlinks `skills/*` into all 6
  installed projects; live at the next timer fire. *Mitigation:* prose-only skill
  changes; contract tests land with the behavior text; `can_merge=false` means a
  human stamp + green CI gate the landing.
- **Delegation as a laundering path for unverified work.** *Mitigation:* §2.5
  untouched and reaffirmed (L3); the return-shape contract demands exit codes and
  evidence lines; the orchestrator re-runs gates itself (cheap — `Bash` results
  average 0.8 KB).
- **Over-delegation on trivial phases** costs more than it saves. *Mitigation:*
  the exception list is part of the contract; `inline` **with a reason** is a
  first-class passing outcome. The tracked metric is context, not agent count.
- **Baseline is machine-local**; transcript retention here is ~30 days.
  *Mitigation:* dated numbers, the producing script ships with them, Phase 7
  compares like-for-like on the same box.
- **Threshold gaming.** *Mitigation:* stated in Phase 7 and L6 — a miss reopens
  the ticket; weakening it is cheating the gate.
- **A contract test that only greps prose** can pass while the behavior text is
  nonsense. *Mitigation:* Phase 7 is the real outcome gate; the contract tests
  are guards against silent removal, and the ticket says so.

## Out of scope

- Changing `execute-ticket`'s verification model, gate classes, or the
  honest-blocker / user-decision protocols.
- Any runner, `install.sh` unit-generation, or config-schema change.
- Deck data regeneration or any `docs/shipyard-data.json` edit.
- Retrofitting existing tickets in `docs/tickets/` with Delegation Plans.
- Building an in-repo specialist roster for shipyard itself.

## Ledger

### Phase 1 — Measurement harness + recorded baseline

builder: inline (exception 4 — this session's operating constraint forbids
spawning subagents unless the operator requests them; the ticket's own
`Delegation:` line called for a subagent, and this deviation is recorded rather
than omitted, which is the behavior the ticket exists to enforce)

Shipped `scripts/delegation-report.py` (stdlib-only, read-only) +
`tests/delegation-report.bats` (11 cases, hermetic via `CLAUDE_PROJECTS_DIR`
into `$BATS_TEST_TMPDIR`).

**Baseline reproduced** — `python3 scripts/delegation-report.py --all`:
sessions=20, zero-subagent sessions=10 (50%), Agent calls=42, avg ctx/turn=344k,
peak=812k (top: 812/731/724/681/677k), turns >300k = 53% carrying 72% of all
context reads, `Read` = 84.7% of returned bytes (494 calls, 27.3 KB avg),
results >60KB = 77, largest = 631 KB, context-carry-vs-work = **86%**.
Turn/token counts drift slightly upward against the ticket's table (8,665 vs
8,618 turns; 9.75 M vs 9.68 M output) because *this* session is an
`execute-ticket` session still being appended to as the script runs — expected,
and itself evidence the attribution works.

**Two defects found by running it, both fixed and pinned failing-first:**
1. *Cost-split denominator was ambiguous.* First run reported "cache-read 75%"
   against the ticket's 86%: the script divided by total cost-equivalent
   (including cache-write) while the baseline divided by context+output. Now
   reports both, with `cache_read_pct_vs_output` (86%) explicitly labeled as the
   Phase 7 headline ratio.
2. *Ledger scan counted spec prose as phase entries.* First run reported
   `subagent=1` from this very ticket's contract example. Scan is now scoped to
   the section after the `## Ledger` heading. Reverting the fix makes tests 8+9
   fail (`not ok 8`, `not ok 9`); reverting the attribution rule to a bare
   substring match makes test 2 fail (`not ok 2`) — both demonstrated before
   restoring.

*Test-quality finding, self-caught:* test 8 originally named the Ledger-scoping
defect but could not fail on it — its fixture's prose line wasn't at line-start,
so the regex missed it either way. Fixture rewritten to a fenced line-start
block mirroring the real false positive; it now fails on the defect. Per the
ticket's own rule, a test that cannot fail is a finding, not a test.

Gate: `py_compile` OK · `bats tests/delegation-report.bats` 11/11 ·
`bats tests/` **285 passing, 0 failures** (274 baseline + 11) ·
`leak-check` clean (with new files `git add -N`'d — see Traps) ·
`check-deck-fresh` in sync.

Commit: _(this commit)_

---

Run it with `execute-ticket`.
