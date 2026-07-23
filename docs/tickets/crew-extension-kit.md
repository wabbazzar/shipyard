# Crew extension kit — /shipyard command, specialist role, hunk-safe critic gates

- **Created:** 2026-07-23
- **Owner:** wabbazzar
- **Status:** Polished — ready for `execute-ticket` (behind the human stamp)
- **Type:** feature (P1 is a bugfix)
- **Estimated Points:** 21 (P1 3 · P2 5 · P3 3 · P4 5 · P5 3 · P6 2)
- **Refs:** motivated by a downstream install where an operator hand-built a
  domain-specialist subagent + a file-conditional shoulder-critic gate and hit a
  false `block` from the critic's changed-file union. `.agents/gates.md` (gate
  classes), `docs/ADAPTING.md` (the triage router this ticket reuses).

## Goal

Let an installed crew **grow and learn** without hand-wiring. Three related
pieces, each behind config whose UNSET value is byte-identical to today's
behavior:

1. **(bugfix) Hunk-safe file-conditional critic gates.** The shoulder critic's
   `CHANGED FILES` list is a union of `git diff` and hook-queued paths, so a
   *tracked* file with **zero delta** can appear in the list with no hunk in the
   `DIFF`. A project-authored critic check that keys on changed-file *membership*
   then misfires (a false `block` on an untouched file). Fix the guidance and,
   behind a flag, mark no-hunk entries so a check can key on real hunks.
2. **(feature) A domain-specialist archetype** as an optional installable role:
   a persistent, knowledge-bearing *reviewer* that guards one subsystem's
   hard-won decisions (its objectives, invariants, and what's been tried) against
   fresh-context erosion — the sixth role archetype the crew doesn't yet ship.
3. **(feature) A `/shipyard` command** (`skills/shipyard/`): `status` (what's
   installed here, where each project block lives), `add-specialist <subsystem>`
   (scaffold #2 and wire it into gates/critic/write_ticket), and `learn
   "<lesson>"` (route a lesson through the ADAPTING.md triage taxonomy to a
   project note or a core change).

**With config unset, no runner emits a different command line, no critic prompt
changes, and no new unit knob is active** — the whole kit is additive until a
project opts in.

## Problem / Background

### 1 — the phantom changed-file gap (verified in this repo)

`agents/release/critic-watch.sh` gathers the review context (lines cited from the
current tree):

- `changed` starts as `git diff --name-only <trunk|HEAD>` (`:246-250`).
- It is then **unioned** with hook-queued paths (`:252-269`) — gitignored and
  out-of-project entries are dropped, but an in-project **tracked** path stays.
- Untracked queued files get a synthesized `--no-index` hunk so brand-new files
  reach the critic as reviewable content (`:273-286`) — but this branch
  `continue`s for tracked files (`git ls-files --error-unmatch … && continue`,
  `:281`).
- The empty-diff skip (`:287-300`) only fires when the **entire** `diff` is
  whitespace — not when one file among several has no hunk.
- The prompt then presents `CHANGED FILES:` and `DIFF:` as separate blocks
  (`:301-323`).

Net: a tracked file queued by the hook but with **zero working-tree delta**
appears under `CHANGED FILES` with **no hunk** under `DIFF`. `critic-role.md`
tells the critic its input is "the changed-file list" and "the git diff"
(`agents/release/critic-role.md:10-16`) without stating that the former is a
superset of the latter. A downstream `.agents/release.md` check written as *"if
the changed-files list includes X, grade X"* therefore fires on a file that was
never touched and emits a `block` it cannot substantiate ("listed but no diff").

**Reproduction (observed downstream):** a project added a file-conditional
optimizer gate to `.agents/release.md`; a hook-queued but reverted optimizer
file sat in `CHANGED FILES` with no hunk; the critic returned
`block|<file>|listed in CHANGED FILES but NO diff was provided`. The gate was
correct; the *input contract* was the defect.

### 2 — no domain-specialist archetype

The five roles (`agents/{design,build,release,medic,scribe}`) are lifecycle
janitors. None is a standing **subsystem expert** — a reviewer that carries a
module's objectives, invariants, tuning rationale, and rejected approaches so a
fresh-context agent does not silently re-litigate a settled decision. Downstream,
this had to be hand-built (a `.claude/agents/<x>-specialist.md` + a living
decision-log doc + manual gate/critic/write_ticket wiring). It is a repeatable
pattern the crew should scaffold.

### 3 — no in-repo "extend / learn" command

`install.sh` scaffolds the crew and `docs/ADAPTING.md` documents the five
feedback channels and the triage router (`ADAPTING.md:34-45,74-79`:
**project-specific → `.agents/<role>.md`**, **generic → core `agents/<role>/`
PR**, **install-time → installer question**). But nothing in-repo *guides* an
operator through extending a role or *captures* a lesson into that router. A
lesson learned mid-session (like #1 above) evaporates unless someone hand-writes
the note or the PR.

## Technical Requirements

### Files to modify

- `agents/release/critic-role.md` — document the `CHANGED FILES ⊇ files-with-hunks`
  contract and instruct file-conditional checks to key on **DIFF hunks**.
- `agents/release/critic-watch.sh` — behind a config flag, reconcile/label the
  union list so no-hunk tracked entries are distinguishable in the prompt
  (`:252-323` region).
- `agents/lib/load-config.sh` (or wherever `CFG_JSON` keys are read) — surface the
  new flag; default OFF ⇒ today's prompt byte-for-byte.
- `install.sh` — add `shipyard` to `GENERIC_SKILLS` (`:110`; it then auto-links
  via `:677-679` and lists in the generated skills index `:748-749`); bake any
  new unit env knob and document it in the README table.
- `docs/ADAPTING.md` — add the specialist archetype as a documented extension and
  reference the `/shipyard learn` router.
- `README.md` — document `/shipyard` and the specialist role; any new env knob.
- `docs/shipyard-data.json` — regenerate via `scripts/gen-deck-data.py` after any
  SKILL.md-frontmatter / `GENERIC_SKILLS` change (house rule).

### Files to create

- `skills/shipyard/SKILL.md` (+ any helper scripts under `skills/shipyard/`).
- `agents/specialist/role.md` — the generic archetype role (concatenated after a
  project block, mirroring the other roles' role/project split).
- `agents/specialist/decision-log.template.md` — the living-knowledge doc template.
- `tests/*.bats` — red-first cases (see Testing Strategy).

### House-rule constraints (shipyard has NO `[write_ticket]` block — these come from `CLAUDE.md` + `.agents/gates.md`)

- **Every new behavior behind a config key whose unset value = today's behavior**,
  proven by a `bats` case shown failing against pre-change code first
  (`tests/helpers.bash` PATH shim; no test reaches GitHub, the network, or a
  model).
- **Exit codes are load-bearing:** `2` = bad invocation/config, `3` = deliberate
  no-op. The `/shipyard` subcommands honor this.
- **Never a bare `claude -p`** — any model call in `add-specialist`/`learn`
  carries a wall-clock timeout and a token cap (`tests/token-caps.bats` enforces).
- **SKILL.md-frontmatter / `GENERIC_SKILLS` change ⇒ regen `docs/shipyard-data.json`**
  (`scripts/gen-deck-data.py`); `scripts/check-deck-fresh.sh` gates it.
- **New unit env knob ⇒ baked by `install.sh` AND in the README table.**
- **leak-check is law** — repo is public; no owner/machine-specific data in any
  tracked file (`scripts/leak-check.sh`). Templates use placeholders, never a
  real downstream project name/path.

## Orchestration protocol (how to build this)

The builder is an **orchestrator**: delegate heavy/wide work (a per-file audit,
a fixture sweep, an adversarial re-read of a generated prompt) to subagents with
tight self-contained briefs; keep the orchestrator lean; **re-verify every gate
yourself** before committing — never trust a subagent's "green." Hand every
subagent this clause verbatim:

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

**Branch strategy — merge-is-live.** This ticket edits shipyard's OWN fleet-live
core (`agents/**`, `install.sh`). A merge to `main` is executed by every
installed project's units on the next timer fire, so ALL work stays on a feature
branch (e.g. `feat/crew-extension-kit`) until every gate is green; the merge to
`main` waits for the human PR stamp (`[medic]/[build] can_merge = false` — keep
it false). Nothing here flips a safety-default key.

## Discovery baseline (captured 2026-07-23; re-verify if stale)

- **Toolchain present on this box:** `bats 1.10.0`, `codex`, `hermes`, `claude`
  all on PATH (`which bats codex hermes claude`). bats suite is hermetic — no
  test may reach the network/GitHub/a model (`tests/helpers.bash` PATH shims).
- **Clean baseline (HEAD `8addd76`):** `bash scripts/leak-check.sh` → clean;
  `bash scripts/check-deck-fresh.sh` → clean. Run both once on the branch base
  before touching anything so a later failure is attributable.
- **Refreshed citations (current tree, drifted from the draft after the
  harness-agnostic merge landed `spawn_model` in the spawn region):**
  `agents/release/critic-watch.sh` — `changed` from `git diff --name-only`
  (`:247`/`:250`), hook-union (`:252-269`), untracked `--no-index` synth with
  the tracked-file `continue` (`:277-284`, guard at `:281`), whole-diff-empty
  skip (`:286-298`), prompt `CHANGED FILES:`/`DIFF:` blocks (`:315-323`).
  `install.sh` — `GENERIC_SKILLS` at `:110`; per-role `Environment=` baking loop
  at `:545` with harness/model/provider already baked at `:557-559` (mirror that
  pattern for any new knob); skill symlink loop `:677`; generated skills-index
  `:748`. `docs/ADAPTING.md` — the three-way router lives under
  "coverage-audit triage → rubric + proposals (the router)" and "The routing
  rule (stated once)" (cite the section names, not line numbers — they drift).
- **token-caps.bats is already spawn-aware** (`:219` asserts no bare `claude -p`
  in any runner + the dispatcher's `timeout "$timeout_val"` guard). Every model
  call P4/P5 add MUST route through `spawn_model` (`agents/lib/spawn.sh`) with a
  non-empty `--timeout`, or `token-caps.bats` fails — that is the intended gate.

## Traps pinned (from `.agents/gates.md` appendix + generic)

- **Fleet-live edits** (`agents/lib/**`, `agents/*/runner.sh`, `install.sh`): a
  worktree test passing is NOT proof it's safe fleet-wide — reason about every
  installed project's config shape. Branch-until-stamped (above).
- **Post-merge determinism:** `[release] test_cmd`=`bats tests/` +
  `typecheck` run VERBATIM (eval'd, no Claude) in post-merge mode. Anything a
  phase adds to that path must be self-contained + side-effect-light.
- **Deck coupling:** adding `shipyard` to `GENERIC_SKILLS` and creating
  `skills/shipyard/SKILL.md` (with `roles:`/`kind:` frontmatter) BOTH trigger a
  `docs/shipyard-data.json` regen (`python3 scripts/gen-deck-data.py`), committed
  in the same change; `check-deck-fresh.sh` gates it. Named steps in P3/P6.
- **Worktree + gitignored data:** worktrees check out from `origin`, so
  gitignored `data/`/`tmp/` are absent there — no bats case may depend on them
  (current cases synthesize their own fixtures; keep it that way).
- **leak-check is law** (public repo): templates are placeholder-only; never a
  real downstream project name/path. `leak-allow` only documents placeholder
  patterns.

## Implementation Plan

Thin vertical slices; each ≤ 5 pts, independently committable, and behind a flag
defaulting to current behavior. Suggested order P1 → P6. **Each phase: work on
the feature branch, add its red-first bats case, run the phase's full
verification surface below, re-verify yourself, then one clean commit
(`git add <files>` explicitly — never `-A`) with the Co-Authored-By trailer, and
append the commit hash + honest note to the Ledger.**

### P1 — Hunk-safe critic gates (bugfix, 3 pts)

**Goal.** A file-conditional critic check can reliably tell "this optimizer file
actually changed" from "this file is a phantom queue entry."

**Steps.**
- `critic-role.md`: add an "Input contract — CHANGED FILES vs DIFF" note stating
  the list is a superset of files-with-hunks and that any file-conditional check
  MUST key on the presence of real `+`/`-` hunks for that path, and that a
  listed-but-no-hunk file is at most a `note`, never a `block`.
- `critic-watch.sh`: behind a new config flag (default OFF ⇒ prompt unchanged),
  reconcile the union list — either drop tracked no-hunk entries from
  `CHANGED FILES` or annotate them (e.g. a `(no hunks)` marker) so the model can
  distinguish them. Keep the untracked `--no-index` synth path intact.
- Surface the flag through the config loader; unset ⇒ byte-identical prompt.

**Verification surface (exact).**
- **Red-first bats** — new case in `tests/` (mirror an existing critic-watch
  case for the harness; use `make_fixture_project`/`make_git_topology`/
  `run_runner` from `helpers.bash`, `make_stub` the harness so nothing reaches a
  model). Seed the hook queue with a tracked **zero-delta** path plus a real
  hunk in another file; assert: (a) flag OFF ⇒ the composed prompt
  (`CHANGED FILES:`/`DIFF:` blocks) is **byte-identical** to pre-change output
  (capture the pre-change prompt as the golden), (b) flag ON ⇒ the no-hunk entry
  carries the `(no hunks)` marker (Decision 1). Show it **failing against
  pre-change `critic-watch.sh` first**, then green. `bats tests/harness-*.bats`
  or the file you add.
- **Syntax:** `bash -n agents/release/critic-watch.sh agents/lib/load-config.sh`.
- **Config-additivity:** the flag's unset value reproduces today byte-for-byte
  (covered by the flag-OFF assertion above — that IS the regression pin).
- **Full suite + hygiene:** `bats tests/` green; `bash scripts/leak-check.sh`
  clean.

### P2 — Domain-specialist archetype (feature, 5 pts)

**Goal.** A generic role a project can install to guard one subsystem.

**Steps.**
- `agents/specialist/role.md`: the archetype — a knowledge-bearing reviewer that
  (a) reads a project decision-log + the subsystem code before answering,
  (b) reviews a change against prior decisions and names the verification it
  demands, (c) reproduces "why does X happen" against the real system rather than
  a plausible story, (d) maintains its decision log. It reviews; it does not
  redesign. Mirror the role/project-block split the other five roles use.
- `agents/specialist/decision-log.template.md`: sections for objectives, choices
  & rationale, tried-and-rejected, invariants, open tensions — placeholder
  content only (leak-safe).
- `docs/ADAPTING.md`: document the archetype and when to reach for it.

**Verification surface (exact).**
- **Red-first bats** — a case asserting `agents/specialist/role.md` and
  `agents/specialist/decision-log.template.md` exist and carry the required
  section anchors (objectives / choices & rationale / tried-and-rejected /
  invariants / open tensions) via `grep -q`; shown failing before the files
  exist. `bats tests/`.
- **Leak-safety of new files:** `bash scripts/leak-check.sh` clean (templates
  placeholder-only — no downstream project name/path).
- **Deck:** P2 adds NO skill and touches NO `roles:`/`kind:` frontmatter and NOT
  `GENERIC_SKILLS`, so no regen is due — confirm with
  `bash scripts/check-deck-fresh.sh` (must stay clean without regen). If that
  changes, `python3 scripts/gen-deck-data.py` and commit the JSON.
- **Syntax (docs only):** none — Markdown templates; no `bash -n` needed.

### P3 — `/shipyard` skill skeleton + `status` (feature, 3 pts)

**Goal.** `/shipyard` (no arg / `status`) reports what's installed here.

**Steps.**
- `skills/shipyard/SKILL.md`: the command surface + trigger description.
- `status`: enumerate installed units/timers, where each `.agents/<role>.md`
  project block lives, and run `install.sh --doctor`. Read-only; exit `3` when
  nothing is installed.
- `install.sh`: add `shipyard` to `GENERIC_SKILLS` (`:110`); confirm the symlink
  (`:677-679`) and generated skills-index (`:748-749`) pick it up.
- Regenerate `docs/shipyard-data.json` (`scripts/gen-deck-data.py`).

**Verification surface (exact).**
- **Red-first bats** — a case asserting `skills/shipyard/SKILL.md` exists with
  valid `roles:`/`kind:` frontmatter, that `shipyard` is in `GENERIC_SKILLS`
  (`grep -E 'GENERIC_SKILLS=.*shipyard' install.sh`), and — against a
  `make_fixture_project` — that `status` exits `3` on a bare dir and `0` on one
  with units installed (drive it read-only; no real `systemctl`/network — stub
  or fixture the enumeration). Shown failing first.
- **Deck coupling (MANDATORY here):** `python3 scripts/gen-deck-data.py` then
  `bash scripts/check-deck-fresh.sh` must be clean, and the regenerated
  `docs/shipyard-data.json` is committed **in this phase's commit**.
- **Install wiring:** `bash -n install.sh`; `./install.sh --dry-run --project .`
  (or a fixture dir) shows the `shipyard` symlink + its skills-index line without
  writing. `bash scripts/leak-check.sh` clean.
- **Full suite:** `bats tests/` green.

### P4 — `/shipyard add-specialist <subsystem>` (feature, 5 pts)

**Goal.** One command scaffolds P2's archetype and wires it in.

**Steps.**
- Instantiate `agents/specialist/*` templates for the named subsystem into the
  project (`.claude/agents/<subsystem>-specialist.md` + a decision-log doc under
  the project's docs dir).
- Wire it: append the decision log to `[write_ticket].context_files`, add a
  "consult the specialist" note to `.agents/gates.md`, and add a **hunk-keyed**
  (P1) file-conditional block to `.agents/release.md` scoped to the subsystem's
  files. Bad invocation ⇒ exit `2`.
- Any model call to draft the decision log carries a timeout + token cap (never a
  bare `claude -p`).

**Verification surface (exact).**
- **Red-first bats** — against a `make_fixture_project`: `add-specialist <sub>`
  lands `.claude/agents/<sub>-specialist.md` + a decision-log doc in the
  project's docs dir AND performs the three wirings (assert with `grep -q`: the
  decision log appended to `[write_ticket].context_files`, the "consult the
  specialist" note in `.agents/gates.md`, a **hunk-keyed** file-conditional block
  in `.agents/release.md` — the block references DIFF hunks, NOT changed-file
  membership, per P1). Missing arg ⇒ exit `2` (`run ...; [ "$status" -eq 2 ]`).
  Shown failing first.
- **Model-call caps (MANDATORY):** any call that drafts the decision log routes
  through `spawn_model` with a non-empty `--timeout` — `bats tests/token-caps.bats`
  stays green (it greps for bare `claude -p` and the dispatcher guard). In the
  scaffold test, `make_stub` the harness so no model is reached.
- **Hygiene:** `bash scripts/leak-check.sh` clean (no downstream name leaks from
  the fixture into a tracked file); `bash -n` on any script touched.

### P5 — `/shipyard learn "<lesson>"` (feature, 3 pts)

**Goal.** Capture a lesson into the ADAPTING.md router deterministically.

**Steps.**
- Classify the lesson as **project-specific** / **generic** / **install-time**
  (`ADAPTING.md:34-45,74-79`) and route it: a project-specific note into
  `.agents/<role>.md`, a generic one into a drafted core-change stub
  (a `docs/tickets/` entry or a role-file patch proposal), an install-time one
  into an installer-question proposal. Ambiguous/empty ⇒ exit `2`.
- Any model-assisted classification carries a timeout + token cap.

**Verification surface (exact).**
- **Red-first bats** — against a fixture: a project-specific lesson lands a note
  in `.agents/<role>.md`; a generic lesson drafts a `docs/tickets/` stub; an
  install-time lesson drafts an installer-question proposal (assert the
  destination file/content per class with `grep -q`). Empty/ambiguous lesson ⇒
  exit `2`. Shown failing first.
- **Model-call caps (MANDATORY):** any model-assisted classification routes
  through `spawn_model` with `--timeout` — `bats tests/token-caps.bats` green;
  `make_stub` the harness in the test.
- **Hygiene:** `bash scripts/leak-check.sh` clean; `bash -n` on scripts touched.

### P6 — Docs + deck sync + full-suite green (chore, 2 pts)

**Goal.** README/ADAPTING current; deck data fresh; whole suite green.

**Steps.**
- README: `/shipyard`, the specialist role, and any new env knob (with the knob
  baked by `install.sh`). ADAPTING: the learn-loop cross-reference.
- Regenerate `docs/shipyard-data.json`; run the full battery.

**Verification surface (exact) — the end-to-end re-run.**
- `bats tests/` fully green (all new cases + the pre-existing 168+).
- `bash scripts/leak-check.sh` clean.
- `python3 scripts/gen-deck-data.py` produces no diff, then
  `bash scripts/check-deck-fresh.sh` clean.
- Syntax sweep: `bash -n install.sh agents/lib/*.sh agents/*/runner.sh agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit && python3 -m py_compile scripts/gen-deck-data.py`.
- `./install.sh --doctor --project .` exits `0`.
- `git status` clean in the repo; worktree/branch ready for the human PR stamp
  (do NOT merge to `main` — `can_merge=false`, merge-is-live).

## Testing Strategy

Per `[write_ticket].test_cmds` — `bats tests/`, `bash scripts/leak-check.sh`,
`bash scripts/check-deck-fresh.sh` — every phase adds the hermetic `bats` case
that closes its gap, **shown red against pre-change code first** (house rule):

- P1: phantom-annotation/prune fires only with the flag on; flag-off prompt is
  byte-identical to today.
- P2: templates carry the required section anchors and are placeholder-only.
- P3: `status` exit codes (`0` installed / `3` bare); skill linked.
- P4: scaffold lands files + the three wirings; missing arg ⇒ `2`; generated
  release block is hunk-keyed; model call token-capped.
- P5: three-way triage routing; empty ⇒ `2`; model call token-capped.
- Cross-cutting: `token-caps.bats` covers every new model call;
  `check-deck-fresh.sh` covers every frontmatter/`GENERIC_SKILLS` change;
  `leak-check` covers every tracked file.

## Acceptance Criteria / Definition of Done

- [ ] **P1** — `critic-role.md` documents the CHANGED-FILES-⊇-DIFF contract; with
      the new flag OFF the critic prompt is byte-identical to today; with it ON a
      tracked zero-delta file is annotated/pruned so a check can key on hunks; a
      listed-but-no-hunk file can no longer produce a substantiated `block`.
- [ ] **P2** — `agents/specialist/role.md` + `decision-log.template.md` exist,
      carry the required section anchors, are placeholder-only, and are documented
      in ADAPTING.md.
- [ ] **P3** — `/shipyard` (status) reports installed units/timers + project-block
      locations + `--doctor`; `shipyard` is in `GENERIC_SKILLS` and links on
      install; `docs/shipyard-data.json` regenerated; exit `3` when nothing is
      installed.
- [ ] **P4** — `/shipyard add-specialist <subsystem>` scaffolds the agent + a
      decision-log doc AND performs the three wirings (write_ticket context, gates
      note, hunk-keyed release block); missing arg ⇒ exit `2`; every model call is
      timeout+token-capped.
- [ ] **P5** — `/shipyard learn "<lesson>"` routes to the correct one of
      project-specific / generic / install-time per the ADAPTING taxonomy; empty
      ⇒ exit `2`; model call token-capped.
- [ ] Every new behavior sits behind a config key whose unset value reproduces
      today's behavior, each proven by a `bats` case shown red-first.
- [ ] `bats tests/`, `leak-check.sh`, `check-deck-fresh.sh` all green; no
      owner/machine-specific data in any tracked file; README + ADAPTING updated;
      `install.sh --doctor` clean.

## Dependencies

- **Blocked-by:** none. (P1 is standalone; P4 depends on P2 templates + P1's
  hunk-keying; P4/P5 depend on P3's skill skeleton.)
- **Blocks:** nothing external.
- **Related:** `harness-agnostic-runners.md` (shares the `spawn_model`
  timeout/token-cap discipline the model calls in P4/P5 must use).

## Risks & Mitigations

- **A prompt-format change in P1 silently alters existing critics.** → The change
  is behind a flag defaulting OFF; a bats case asserts byte-identical prompt with
  the flag unset.
- **Scaffolder (P4) writes into a project inconsistently across harnesses.** →
  Scaffold from the P2 templates only; assert against a fixture project in bats;
  no network/model in the test (PATH shim).
- **A model call regresses to a bare `claude -p`.** → `token-caps.bats` fails the
  build; route every call through the shared spawn dispatcher.
- **Leak of the motivating downstream project's data into templates.** → Templates
  are placeholder-only; `leak-check` gates every phase.
- **Deck data drifts from the new skill's frontmatter.** → `check-deck-fresh.sh`
  gates; regen is a named step in P3 and P6.

## Out of scope

- A declarative `[release.diff_gates]` config schema (glob → severity/route/doc
  injected generically by `critic-watch.sh`) — a cleaner successor to per-project
  prose gates, but a separate ticket; this one only makes the prose-gate path
  hunk-safe and scaffoldable.
- Making the shoulder critic itself *spawn* the specialist subagent (it is a
  single findings-only call by design); the specialist runs on the human/ticket
  path.
- Any change to the downstream project that motivated this; it already carries
  its hand-built specialist.

## Decisions (default-and-record — veto at review)

| # | Question | Default locked in |
|---|---|---|
| 1 | Prune vs annotate no-hunk entries in P1 | **Annotate** (`(no hunks)` marker) — lower blast radius than dropping from the list; the critic still sees the name. |
| 2 | One combined ticket or three | **One** — P4 `add-specialist` scaffolds P2's archetype and P1 makes its critic wiring safe; splitting would thread the same fixtures three ways. |
| 3 | Where the scaffolded decision-log doc lands in a target project | **The project's existing docs dir** (discovered, not hardcoded) — mirrors how the motivating install placed it. |
| 4 | `learn` generic-route output | **A `docs/tickets/` stub** (not a direct role-file edit) so a human/agent reviews before it lands in a core role file. |

No user-decision-class blockers remain: every phase is additive-behind-a-flag,
no phase spends money in CI (model calls are stubbed in tests; any live drafting
is manual acceptance), nothing is outward-facing or destructive, and no
safety-default key changes. `execute-ticket` may build straight through, applying
the four locked defaults above.

## Ledger

_(empty — `execute-ticket` appends per phase: the slice plan written BEFORE
working, the commit hash after, and an honest note on anything deferred or any
gate that could not be made green by legitimate means.)_

| Phase | Plan / commit | Notes |
|---|---|---|
| P1 | `[release].hunk_safe_gates` flag + `_annotate_no_hunk` in critic-watch.sh; input-contract note in critic-role.md; red-first `hunk-safe-gates.bats` + fixture. **`a8d61eb`** | Green. Flag-OFF byte-identity pinned; flag-ON marks phantom only. Red-first verified (test 1 fails on pre-change code via `git stash`). Note: critic-role.md's own note contains "(no hunks)", so assertions key on filename+marker, not the bare marker. |
| P2 | `agents/specialist/{role.md,decision-log.template.md}` (placeholder-only archetype); ADAPTING.md section; red-first `specialist-archetype.bats`. | Green. 4 anchors asserted; red-first verified (files moved aside → all fail). No skill/frontmatter touched ⇒ deck stays fresh without regen. |
| P3 | `skills/shipyard/{SKILL.md,shipyard.sh}` (status fully; add-specialist/learn routed to exit 2 for now); `shipyard` added to `GENERIC_SKILLS`; red-first `shipyard-status.bats`. | Green (6 cases red-first). Live-verified against the real self-hosted shipyard crew: status→0 lists 5 timers+blocks+doctor; bare→3; unknown→2. Deck regen was a **no-op**: `roles:[human]` frontdoor contributes nothing to crew/graph, so `gen-deck-data.py` produced no JSON diff (check-deck-fresh clean). Live doctor flags "shipyard symlink missing" for shipyard's own gitignored self-install — correct drift, resolved by a reinstall (not this ticket's job). |
| P4 | | |
| P5 | | |
| P6 | | |

**Roll-up DoD:** all six phases committed on `feat/crew-extension-kit` (worktree
clean, `git status` empty); `bats tests/` + `leak-check.sh` +
`check-deck-fresh.sh` + the `bash -n`/`py_compile` sweep + `install.sh --doctor`
all green; no background processes left running; branch handed to the human PR
stamp with `can_merge` still `false` (merge-is-live — do NOT self-merge).

---

**To build:** run `execute-ticket` on this file. It is polished and behind the
human stamp; the builder works on `feat/crew-extension-kit`, verifies each
phase's surface above, and stops at the PR gate.
