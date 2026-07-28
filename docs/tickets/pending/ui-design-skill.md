# UI/UX design skill + a hard deck-completeness gate

- **Status:** draft (ready for `polish-ticket`; awaiting human stamp)
- **Priority:** medium
- **Type:** feature
- **Estimated Points:** 17 (P0 3 · P1 5 · P2 3 · P3 5 · P4 1)

## Summary

Two coupled deliverables:

1. **Phase 0 — a hard deck-completeness gate.** Land *first* a strict gate
   (`scripts/check-deck-complete.sh`, wired into the pre-commit hook **and** CI)
   that **fails the commit** if any skill is missing from the deck — not
   registered in `GENERIC_SKILLS`, missing its graph node, or relying on
   fallback prose. This closes the hole where a skill can be built and shipped
   while silently absent from the deck with every existing gate green. It makes
   "built the skill but forgot the deck" **impossible**, and it proves itself:
   creating the ui-design skill in P1 turns it RED until registration turns it
   green.
2. **Phases 1–4 — the ui-design skill.** A self-contained, model-agnostic UI/UX
   design skill at `skills/ui-design/SKILL.md` that distills the frontend-design
   craft (palette, type, layout, signature, copy, restraint, self-critique) into
   shipyard's skill format — registered on the deck, installed per project, and
   referenced by the crew skills so **any role consults it whenever the surface
   in question is a front-end**, at any stage. v1 ships the distilled craft only;
   the label-family / naming-consistency rule is explicitly deferred.

The Phase 0 gate is **shipyard-repo-local** (the deck, `gen-deck-data.py`, and
`checks.yml` are shipyard's own artifacts — not per-installed-project), so it is
*not* a fleet-live runner change. The ui-design skill file + `install.sh` +
caller edits (P1/P3) still are.

## Build context & verified toolchain (baselined 2026-07-23)

Run on a **branch off `main`** — never on `main`. `skills/**` and `install.sh`
are read live by every installed project on the next timer fire (merge-is-live;
`.agents/gates.md` Traps "Fleet-live edits"), and `can_merge=false` + human
stamp + green CI are the wall. Branch suggestion: `feat/ui-design-skill`.
Rollback = delete the branch; nothing is live until merge.

Every gate this ticket relies on was run during polishing and is green — use
these as the baseline a regression is measured against:

| Gate | Command | Baseline (2026-07-23) |
|------|---------|-----------------------|
| bats suite | `bats tests/` | **138 tests, all pass**, exit 0 |
| leak-check | `bash scripts/leak-check.sh` | `leak-check: clean`, exit 0 |
| deck freshness | `bash scripts/check-deck-fresh.sh` | `deck is in sync`, exit 0 |
| deck regen idempotent | `python3 scripts/gen-deck-data.py && git diff --stat docs/shipyard-data.json` | no diff, exit 0 |
| shell syntax | `bash -n install.sh` | exit 0 |

So the bats suite grows across P0 (the completeness-gate cases) and P2 (the
seven-skill install/doctor/uninstall assertions) from **138 → 138+N**, each new
case shown **failing-first** against the pre-change code per the harness
convention. `check-deck-complete.sh` does not exist yet — P0 creates it; its
green baseline is "the current 6-skill deck is complete."

## Build protocol (orchestrator + honesty)

The builder is an **orchestrator**: delegate wide/heavy work (drafting the
distilled skill body, sweeping the test enumerations) to subagents with tight
briefs; keep the orchestrator lean; re-verify every gate personally. Embed this
verbatim in every subagent brief:

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, and report exact output (exit codes, the bats
> tally, the `git diff --stat`), not adjectives.

No model invocation is added by this ticket, so no `timeout`/token-cap surface
changes — but if that assumption breaks, `tests/token-caps.bats` is law.

## Problem / Background

The `/feature` intake already carves a seam it can't fill: `skills/feature/SKILL.md:116-119`
defers "a grounded aesthetic reference and running a design review before writing
design-intent acceptance criteria" to *"new-spec's ui-shaped step 4d"* — a
skill/step that **does not exist** (`grep -rn new-spec skills/` returns only
these forward-references at `feature/SKILL.md:116,118,119,179,181`). There is no
UI/UX, frontend, or visual-design capability anywhere in the crew; the only
"visual" mention is a bug-class row at `skills/coverage-audit/SKILL.md:122`
("jsdom has no layout — needs a real browser"). So when a crew role touches a
front-end — mentat writing a UI ticket, helldiver building one, proctor
critiquing a shipped view — it has no shared craft standard to consult, and UI
work regresses to templated defaults or misses (the aurora label-family miss
that motivated this).

The source material is Claude's `frontend-design` plugin, a single
self-contained `SKILL.md` (verified: the plugin cache is one `SKILL.md` +
`LICENSE`, no reference files). shipyard is going **harness/model-agnostic**
(see `docs/tickets/harness-agnostic-runners.md`), so the skill must be a
**self-contained distillation** — no reference to the external plugin, no
provider/tool/model name baked in — not a pointer to a Claude-only asset.

**Placement decision (settled at intake):** this is not a phase-bound add-on.
The trigger is a *property of the work* ("a front-end is in question"), not a
*stage*. So it is one **shared** skill with the same shape `coverage-audit`
already uses (`skills/coverage-audit/SKILL.md:2-4`: `roles: [design, release,
human]`, `disposition: adapted`, `kind: shared`), extended to build:
`roles: [design, build, release, human]`, `disposition: adapted`, `kind: shared`.

## Decisions (default-and-record — veto at review)

| # | Decision | Default locked in | Why |
|---|----------|-------------------|-----|
| D-1 | Skill id / dir | `ui-design` (`skills/ui-design/SKILL.md`) | Distinct from the source `frontend-design`; reads in a caller sentence ("consult the ui-design skill"). |
| D-2 | Frontmatter | `roles: [design, build, release, human]`, `disposition: adapted`, `kind: shared` | Mirrors `coverage-audit`, the existing shared-skill precedent; extended to build. |
| D-3 | v1 content | Distilled craft only; label-family rule **deferred** | Chosen at intake. Keeps v1 a clean distillation; the naming-consistency rule lands later or as a project trap. |
| D-4 | Caller wiring scope (P3) | Minimal, additive references in the skills that touch a UI surface: `write-ticket` + `polish-ticket` (fills the `new-spec` seam), `execute-ticket`, and the release critic path | Every caller edit is fleet-live; keep the blast radius to one additive "if the surface is a front-end, consult ui-design" line per caller, non-UI path byte-unchanged. |
| D-5 | Update `feature/SKILL.md`'s `new-spec` forward-ref? | **Yes** (P3) — repoint `feature/SKILL.md:118` and `:179` from the non-existent `new-spec` at the `ui-design` skill | The forward-ref currently dangles at a skill that doesn't exist; now it has a real target. Prose-only reword, no frontmatter/behavior change, so the deck stays fresh. |
| D-6 | Deck-completeness gate strictness + shape | **Strict** — fail unless every non-exempt skill is in `GENERIC_SKILLS` **and** has a `graph.skills` node **and** an authored crew editorial entry in each member crew (no `default_prose` reliance). Implemented as a `--check` mode of `gen-deck-data.py` (reuses its own `read_generic_skills`/`load_skills`/`member_crews`/editorial parse — **zero logic drift**), wrapped by `scripts/check-deck-complete.sh`, wired into `.githooks/pre-commit` **and** `checks.yml`. Exempt allowlist: `install` (documented in the script). | User-chosen: "make it a very hard gate." Reusing the generator's logic guarantees the gate and the generator agree on placement. Repo-local scope. |

## Technical Requirements

**New file — `skills/ui-design/SKILL.md`** (self-contained, model-agnostic).
Frontmatter per D-2, all three of `roles`/`disposition`/`kind` present (missing
any hard-errors `scripts/gen-deck-data.py`, see `parse_frontmatter`). Body
distills the source craft, harness-agnostically:

- **Ground it in the subject** — pin a concrete subject/audience/job before designing.
- **Palette** — 4–6 named hex values; avoid the three documented AI-default looks.
- **Type** — display + body + utility roles, deliberate scale/weights.
- **Layout & signature** — a layout concept + the one memorable element; structure encodes content, not decoration.
- **Motion / restraint** — deliberate, reduced-motion respected; "remove one accessory."
- **Copy** — active voice, sentence case, name things by what the user controls; failure/empty states as direction.
- **Self-critique loop** — brainstorm → plan → critique-against-generic → build → critique again; capability check for a screenshot pass phrased **generically** (no named tool).
- **Quality floor** — responsive to mobile, visible keyboard focus, reduced motion.

No `frontend-design`/plugin/provider/model reference anywhere in the body
(model-agnostic + leak-check clean).

**Registration (the 4 coupled edits — `.agents/gates.md:48-52` "Deck coupling"):**

1. `install.sh:110` — add `ui-design` to `GENERIC_SKILLS` (currently
   `"polish-ticket execute-ticket coverage-audit write-ticket bugfix feature"`).
   This one list drives install-symlink, `--doctor`, and uninstall.
2. `docs/deck-editorial.json` — add a crew skill-block entry (`_file: ui-design`,
   with `name`/`disposition`/`source`/`summary`/`detail`, mirroring the
   `coverage-audit` entry) under **each** crew the roles resolve to (design,
   build, release — `member_crews` in `gen-deck-data.py`), and a
   `graph.skills` node `{ "_file": "ui-design", "label": "…" }`. Add graph
   `edges` only if a caller relationship should render.
3. `python3 scripts/gen-deck-data.py` — regenerate `docs/shipyard-data.json`
   (no trailing newline; byte-identical round-trip) and commit it in the same change.
4. `skills/gates.md.template` / `.agents/gates.md` — no change needed (the Deck
   coupling class already covers this).

**Install / discovery** is automatic once in `GENERIC_SKILLS`: `install.sh`
step 4.5 symlinks `$QUARTET_DIR/skills/ui-design` → `<project>/.claude/skills/ui-design`;
`--doctor` audits it; uninstall removes only the symlink. Tests that count the
generic skills must move from **six → seven**:
`tests/install-skills.bats:7,9,39,52` (the `for s in …` loops and the "six"
comments), plus any parallel enumeration in `tests/doctor.bats` /
`tests/uninstall.bats`.

**Caller references (P3, additive only):** the skills that touch a UI surface
name `ui-design` conditionally. Minimum set (D-4): `write-ticket` +
`polish-ticket` UI-shaped handling, `execute-ticket`, and the release critic
path. Each is a single additive "if the surface is a front-end, consult the
ui-design skill" line — the non-UI path stays byte-identical.

**New gate — `scripts/check-deck-complete.sh` + `gen-deck-data.py --check` (P0):**
Today `gen-deck-data.py:89` enforces `GENERIC_SKILLS → file exists`, and
`check-deck-fresh.sh` (CI only; **not** in the pre-commit hook, which runs only
`leak-check --staged`, `.githooks/pre-commit:4`) catches a *forgotten
regeneration*. Neither enforces the reverse or completeness — a
`skills/<id>/SKILL.md` never added to `GENERIC_SKILLS` is **silently invisible**
with all gates green (`checks.yml:29` stays green). Missing graph node /
authored editorial for a listed skill isn't hard-failed either (only *unknown*
editorial ids error, `gen-deck-data.py:150,182`). The gate closes all three:

- Add a `--check` mode to `gen-deck-data.py` (it currently takes no argv — add a
  minimal `sys.argv` branch in `main()`, `gen-deck-data.py:117`). In check mode
  it **writes nothing**; it reuses `read_generic_skills`, `load_skills`,
  `member_crews`, and the editorial parse to assert, for the resolved skill set:
  (1) every non-exempt `skills/*/SKILL.md` id ∈ `GENERIC_SKILLS`; (2) every
  listed id has a `graph.skills` node; (3) every listed id has an **authored**
  crew editorial `_file` entry in each crew `member_crews` resolves it into (no
  `default_prose` fallback). On any gap: print each missing (skill, reason) and
  exit nonzero. Exempt allowlist `{install}` is a named constant with a comment.
- The repo root must be overridable (env, e.g. `$DECK_ROOT`, default = the
  script's own repo) so the P0 bats case can run the checker against a
  synthesized fixture with a deliberately-unregistered skill and see it fail.
- `scripts/check-deck-complete.sh` — thin wrapper (mirror `check-deck-fresh.sh`'s
  shape) that runs `python3 scripts/gen-deck-data.py --check` and reports.
- Wire it: append it to `.githooks/pre-commit` (after the leak-check `exec` —
  restructure so both run), add a `- run: bash scripts/check-deck-complete.sh`
  step to `checks.yml` beside the `check-deck-fresh` step (line ~29), and add
  `scripts/check-deck-complete.sh` to the `bash -n` sweep list (`checks.yml:20`).

## Implementation Plan

### Phase 0 — Hard deck-completeness gate, wired into pre-commit + CI (3 pts)
Steps:
- Add the `--check` mode to `scripts/gen-deck-data.py` (writes nothing; strict
  rules per D-6; `{install}` exempt).
- Add `scripts/check-deck-complete.sh` wrapper.
- Wire into `.githooks/pre-commit` and `checks.yml` (new step + `bash -n` sweep).
- Add bats cases in a new `tests/deck-complete.bats`, **failing-first**: against
  a fixture skill dir absent from `GENERIC_SKILLS` (and a listed skill missing
  its graph node / editorial), the gate must **exit nonzero**; with a complete
  set it exits 0.

Verification surface (exact commands):
- Failing-first proof: point the checker at a fixture with an unregistered skill
  → `bash scripts/check-deck-complete.sh` (or `DECK_ROOT=<fixture> python3
  scripts/gen-deck-data.py --check`) **exits nonzero** and names the skill;
  then against the real repo → **exits 0** ("6-skill deck complete"). Record both.
- `bats tests/deck-complete.bats` green; `bats tests/` green (no regression).
- `python3 -m py_compile scripts/gen-deck-data.py` → exit 0 (CI parity).
- `bash -n scripts/check-deck-complete.sh .githooks/pre-commit` → exit 0.
- Prove the wiring bites: with the real repo complete, a normal `git commit`
  still succeeds (gate green); simulate an incomplete state on a throwaway
  branch/fixture and confirm the pre-commit hook **blocks** it.

Observable DoD: `check-deck-complete.sh` exits 0 on the current 6-skill deck and
nonzero on a synthesized incomplete deck; the pre-commit hook and a
`checks.yml` step both invoke it; `tests/deck-complete.bats` green;
`bats tests/` green at the new count.

### Phase 1 — Author the skill + register + deck (5 pts)
Steps:
- Write `skills/ui-design/SKILL.md` (self-contained distillation, D-1/D-2/D-3).
- Add `ui-design` to `install.sh:110 GENERIC_SKILLS`.
- Add editorial prose entries (design/build/release crew blocks) + a
  `graph.skills` node in `docs/deck-editorial.json`.
- `python3 scripts/gen-deck-data.py`; stage the regenerated
  `docs/shipyard-data.json` in the **same** commit.

Verification surface (exact commands, all must pass before commit):
- `grep -nEi 'frontend-design|anthropic|claude|opus|sonnet|screenshot tool' skills/ui-design/SKILL.md` → **no** provider/tool/plugin leak (model-agnostic).
- `bash scripts/leak-check.sh` → `leak-check: clean`, exit 0.
- `python3 scripts/gen-deck-data.py && git diff --stat docs/shipyard-data.json` → the JSON changed *once* for this skill, then re-running leaves **no** further diff (idempotent).
- `bash scripts/check-deck-fresh.sh` → `deck is in sync`, exit 0.
- `bash scripts/check-deck-complete.sh` → exit 0 (**the P0 gate now proves
  ui-design is fully on the deck** — registered, graphed, authored). Before
  registration is finished it exits nonzero and the pre-commit hook blocks the
  commit; that RED→green transition is the enforcement working. Record it.
- `bash -n install.sh` → exit 0.

Observable DoD: `check-deck-fresh.sh`, `check-deck-complete.sh`, and
`leak-check.sh` all exit 0; the leak grep returns nothing;
`docs/shipyard-data.json` shows a `ui-design` entry under the
design/build/release crews and a graph node.

### Phase 2 — Install / discovery coverage (3 pts)
Steps:
- Update the six→seven skill enumerations in `tests/install-skills.bats:7,9,39,52`
  and any parallel enumeration in `tests/doctor.bats` / `tests/uninstall.bats`.
- **Failing-first:** add/adjust the assertion, run it against the pre-change
  `GENERIC_SKILLS` (or before the P1 install.sh edit is on the branch) and show
  it RED, then green after — per the harness convention.

Verification surface (exact commands):
- Failing-first proof: `git stash -- install.sh && bats tests/install-skills.bats` → the seven-skill case FAILS; `git stash pop && bats tests/install-skills.bats` → PASSES. (Record both tallies.)
- `bats tests/` → **138+N pass**, exit 0 (N = the assertions added).
- `./install.sh --project <fixture> --dry-run` → announces it WOULD symlink `ui-design`; writes nothing.
- `./install.sh --doctor --project .` → exit 0, audits the `ui-design` symlink.

Observable DoD: full `bats tests/` green at the new higher count; the
failing-first transition recorded in the Ledger; `--doctor` exits 0.

### Phase 3 — Caller references + repoint the dangling forward-ref (5 pts)
Steps:
- Add one conditional "if the surface is a front-end, consult the `ui-design`
  skill" pointer to the D-4 caller set (`write-ticket`, `polish-ticket`,
  `execute-ticket`, release-critic path). Additive only — the non-UI path stays
  byte-identical.
- **Repoint the dangling `new-spec` refs (D-5):** at `skills/feature/SKILL.md:118`
  replace "(new-spec's ui-shaped step 4d)" with a reference to the `ui-design`
  skill; at `skills/feature/SKILL.md:179` replace "Doing new-spec's
  design-readiness pass." likewise. This is a **prose reword** of feature's
  out-of-scope note — it keeps feature's *behavior* identical (the readiness
  pass is still not run inline), only naming a real skill instead of a
  nonexistent one. Do **not** touch feature's frontmatter (`name`/`roles`/
  `disposition`/`kind`) — so the deck stays byte-fresh.

Verification surface (exact commands):
- `grep -rn 'new-spec' skills/` → **zero hits** after the edit (the forward-ref no longer dangles).
- `git diff skills/write-ticket skills/polish-ticket skills/execute-ticket <release-critic-path>` → each caller pointer is a **pure addition** (no line removed/reworded on the non-UI path); `git diff skills/feature/SKILL.md` → touches only the two prose lines above, **no frontmatter line**.
- `bats tests/` → still **138+N pass**, exit 0 (no existing case regressed — prose changes touch no tested behavior).
- `bash scripts/leak-check.sh` → exit 0; `bash scripts/check-deck-fresh.sh` → `deck is in sync`, exit 0 (proves the feature reword left frontmatter untouched).
- Fleet reasoning (write it in the Ledger): the caller pointers and the feature
  reword are prose a role *may* consult; they add no config key, no new gate, no
  changed exit code — so every installed project's non-UI runs are unaffected on
  the next timer fire.

Observable DoD: `grep -rn new-spec skills/` returns nothing; `git diff` shows
additive-only caller edits and a two-line feature reword with no frontmatter
change; full suite green at the P2 count; leak-check + deck-fresh exit 0.

### Phase 4 — End-to-end gate re-run (1 pt)
Re-run the whole ticket's gate from a clean worktree:
`bats tests/ && bash scripts/leak-check.sh && bash scripts/check-deck-fresh.sh
&& bash scripts/check-deck-complete.sh && bash -n install.sh
scripts/check-deck-complete.sh .githooks/pre-commit` → all exit 0. Confirm
`git status` is clean and `docs/shipyard-data.json` is committed alongside its
frontmatter source.
Observable DoD: the one-liner above exits 0 end-to-end; worktree clean.

## Testing Strategy

- `bats tests/` — the install/doctor/uninstall symlink cases updated to seven
  skills, shown failing-first; hermetic (`make_stub` for systemctl/gh/claude, no
  network/model).
- `bash scripts/leak-check.sh` — the new SKILL.md carries no home path, private
  email, key-shaped literal, or provider/tool name.
- `tests/deck-complete.bats` (new, P0) — the completeness gate exits nonzero on
  a synthesized incomplete deck (unregistered skill / missing graph node /
  missing authored editorial) and 0 on a complete one; shown failing-first.
- `bash scripts/check-deck-fresh.sh` — `docs/shipyard-data.json` regenerates
  byte-identical after the frontmatter + `GENERIC_SKILLS` + editorial change.
- `bash scripts/check-deck-complete.sh` — passes only when every non-exempt
  skill is fully on the deck (P0's gate; run in pre-commit + CI).
- `bash -n install.sh` and a `bash -n` sweep for any touched shell.
- No new model invocation is added, so `tests/token-caps.bats` is unaffected
  (assert it stays green).

## Acceptance Criteria / Definition of Done

- [ ] `scripts/check-deck-complete.sh` + `gen-deck-data.py --check` exist and
      **fail (nonzero)** when a `skills/*/SKILL.md` (non-exempt) is absent from
      `GENERIC_SKILLS`, lacks a `graph.skills` node, or lacks an authored crew
      editorial entry — proven by `tests/deck-complete.bats` cases shown
      **failing-first**; the checker exits 0 on the current complete deck.
      `install` is the only exempt skill, and that exemption is a documented
      named constant.
- [ ] The completeness gate is wired into **both** `.githooks/pre-commit` and a
      `checks.yml` step, and appears in the `checks.yml` `bash -n` sweep. A
      commit that would ship an incomplete deck is blocked locally and in CI
      (demonstrated).
- [ ] `skills/ui-design/SKILL.md` exists, self-contained and model-agnostic — no
      reference to the `frontend-design` plugin or any provider/tool/model name
      (leak-check clean) — with valid frontmatter `roles: [design, build,
      release, human]`, `disposition: adapted`, `kind: shared`, plus `name` +
      `description`.
- [ ] Body distills the source craft: subject-grounding, palette (4–6 named
      hex), type roles, layout + one signature element, motion/restraint, copy
      guidance, and a build→critique→critique-again loop with the screenshot
      capability check phrased **without naming a tool**.
- [ ] `ui-design` is in `install.sh:110 GENERIC_SKILLS`; `docs/deck-editorial.json`
      has a `_file: ui-design` crew entry under design/build/release and a
      `graph.skills` node; `python3 scripts/gen-deck-data.py` regenerated
      `docs/shipyard-data.json` and it is committed in the same change;
      `check-deck-fresh.sh` green.
- [ ] After a real `install.sh` run, `<project>/.claude/skills/ui-design` is a
      symlink into `$QUARTET_DIR/skills/`; `install.sh --doctor` audits it and
      exits 0; uninstall removes only the symlink. A bats case proves the
      symlink is created, shown **failing against the pre-change `GENERIC_SKILLS`
      first**.
- [ ] The D-4 caller set names `ui-design` conditionally on a front-end surface;
      each edit is additive and a non-UI invocation's behavior is byte-unchanged
      (proven).
- [ ] `bats tests/` fully green; `bash scripts/leak-check.sh` clean;
      `bash scripts/check-deck-fresh.sh` green; `bash scripts/check-deck-complete.sh`
      green; `bash -n` sweep green; `tests/token-caps.bats` still green.

## Dependencies

- **External:** none. The distillation is authored from the already-cached
  `frontend-design` SKILL.md; no binary or network access required.
- **Internal ordering:** P1 is **blocked-by P0** — the completeness gate must be
  live before the skill is authored, so registering ui-design is what turns the
  gate green (the enforcement proving itself). P0 is self-contained (touches only
  `gen-deck-data.py`, a new script, the hook, CI, and a new bats file).
- **Blocks:** a future ticket that bakes the label-family / naming-consistency
  rule (D-3) into this skill or a project trap. **Blocked-by:** none external.

## Risks & Mitigations

- **Fleet-live blast radius** — `skills/**` and `install.sh` are read by every
  installed project on the next timer fire (`.agents/gates.md` Traps:
  "Fleet-live edits"). The new file is purely additive; the P3 caller edits are
  the risk → keep each an additive conditional line, prove the non-UI path
  byte-unchanged, land on a branch, human stamp + green CI remain the wall.
- **Deck drift / omission** — forgetting to regenerate `docs/shipyard-data.json`
  → `check-deck-fresh.sh`; forgetting to register/graph/author a skill at all →
  the **new P0 `check-deck-complete.sh`** (pre-commit + CI). Both are acceptance
  items.
- **Completeness gate too strict / false-positive** — a legitimate future
  deck-exempt skill (like `install`) would trip it → the exemption is an
  explicit, documented allowlist constant; adding a new exempt skill is a
  one-line, reviewed change. The gate reuses `gen-deck-data.py`'s own placement
  logic, so it cannot disagree with the generator about where a skill belongs.
- **Pre-commit friction** — the hook now runs completeness on every commit; a
  mid-authoring commit of a half-registered skill is blocked. That is the
  intended behavior (the whole point), but if it proves noisy the CI step is the
  hard wall and the hook line can be dropped without weakening the merge gate.
- **Distillation smuggles a Claude-ism** — a provider/tool name or "if your
  environment supports screenshots" phrased tool-specifically breaks
  model-agnosticism / leak-check → acceptance requires generic phrasing;
  leak-check + a manual read gate it.
- **Missing frontmatter field** — omitting any of `roles`/`disposition`/`kind`
  hard-errors `gen-deck-data.py` → caught immediately by P1's `check-deck-fresh`.

## Out of scope

- The label-family / naming-consistency rule (D-3) — explicitly deferred.
- Any broader rewrite of `feature/SKILL.md` beyond repointing the two dangling
  `new-spec` refs at `ui-design` (D-5) — feature's behavior stays identical.
- Any new "UI-shaped detection" heuristic baked into a runner, any new config
  key, any new module/dir outside `skills/ui-design/` + the known registration
  points, and any new top-level dependency or runtime/browser tooling
  requirement.
- Building any actual UI — this ships the *skill*, not a front-end.

## Ledger

_(builder appends per phase: plan taken, commit hash, gate output — the bats
tally, the `git diff --stat`, exit codes — and honest notes on anything
deferred.)_

- P0 —
- P1 —
- P2 —
- P3 —
- P4 —

## Run it

Hardened and ready for **`execute-ticket`** at
`docs/tickets/ui-design-skill.md`. It carries no user-decision-class blocker
(no spend, nothing outward-facing, nothing destructive; every open choice has a
locked default in the Decisions table) — so a cold agent can build it start to
finish once stamped. Land it on `feat/ui-design-skill`, not `main`.
