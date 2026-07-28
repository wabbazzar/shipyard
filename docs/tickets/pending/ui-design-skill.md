# UI-design skill and a deterministic deck-completeness gate

- **Created:** 2026-07-23
- **Owner:** wabbazzar
- **Status:** Polished — ready for `execute-ticket`
- **Priority:** medium
- **Type:** feature
- **Estimated Points:** 17 (P0 5 · P1 5 · P2 2 · P3 3 · P4 2)
- **Refs:** `scripts/gen-deck-data.py`, `scripts/check-deck-fresh.sh`,
  `install.sh` `GENERIC_SKILLS`, `docs/deck-editorial.json`,
  `.agents/gates.md`, `.githooks/pre-commit`, `.github/workflows/checks.yml`.

## Goal and measured baseline

Ship one self-contained, model-agnostic `ui-design` skill used by the ticket
pipeline and release critic whenever work has a front-end surface. Make it
impossible for an installed skill to be absent or fallback-authored on the
Shipyard deck while current gates remain green.

Measured on `main` at `54fa906`, 2026-07-28:

- `skills/` has **8 directories**: 7 installed shared skills plus the
  intentionally non-`GENERIC_SKILLS` installer workflow.
- `GENERIC_SKILLS` has **7** entries. After this ticket: 9 directories and 8
  installed shared skills.
- `bats --count tests/` prints `380`.
- `scripts/check-deck-complete.sh` is absent.
- `python3 scripts/gen-deck-data.py --check` exits 0 with zero output because
  argv is currently ignored; it is not a check.
- Python 3.12.3, Bats 1.10.0, Node v24.12.0, `gh` 2.83.2, and jq 1.7 are
  available. `py_compile`, current shell syntax, and deck freshness exit 0.

## Locked decisions

| Decision | Result |
|---|---|
| Skill | `skills/ui-design/SKILL.md`; roles `[design, build, release, human]`, `disposition: adapted`, `kind: shared`. |
| Content | Subject/audience grounding; named palette; type roles; structural layout and one signature element; responsive/accessibility/reduced-motion floor; concise copy; critique loop. No provider, plugin, model, or named screenshot tool. |
| Naming-consistency rule | Deferred; not smuggled into v1. |
| Completeness | `gen-deck-data.py --check --root <repo>` owns the logic; a thin `check-deck-complete.sh` is justified as the stable hook/CI gate, not documentation. |
| Exemption | Only `skills/install`; a named constant with a reason. |
| Docs | Update existing `README.md` Skills-parity and `docs/INSTALL.md` L5 only. No new guide or heading. |
| Deck | Authored entries under design/build/release plus one graph node; regenerate `docs/shipyard-data.json`; both published deck URLs must catch up after push. |
| Work mode | This checkout on `main`; no branch/worktree. Scope every `git add`; full gates before every commit. |

There are no open decisions. No spend, new dependency, service, port, or manual
deployment is required. The bridge closeout ticket should land first because it
also edits `README.md` and `docs/INSTALL.md`; this is file serialization, not a
design blocker.

## Orchestration and fleet hazards

The orchestrator delegates the bounded briefs below, then independently reads
every diff and reruns every named gate.

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives. If it needs a spend,
> outward-facing action, or destructive change, stop and report instead.

`skills/**` and `install.sh` are fleet-live. A commit touching them triggers
`.githooks/post-commit` → `reconcile-skills.sh --all`; never use a worktree
because it would repoint the fleet at that worktree. Existing generated
`AGENTS.md` files remain no-clobber; Codex discovers the new link natively under
`.agents/skills/`, while `.claude/skills/` remains Claude/Hermes compatibility.

Generated `docs/shipyard-data.json` is never hand-edited. Prose belongs in
`docs/deck-editorial.json`; structural data comes from frontmatter and
`GENERIC_SKILLS`.

## Common phase gate

Every phase, before its scoped commit:

```bash
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
scripts/ticket-lifecycle.sh --project . --check
```

Run `node scripts/check-deck-render.mjs`; exit 0 is PASS and exit 3 is the
documented Playwright SKIP. A red common gate blocks the phase commit.

## P0 — deterministic deck-completeness gate (5 points)

**Delegation: subagent (1) — own only `scripts/gen-deck-data.py`,
`scripts/check-deck-complete.sh`, and `tests/deck-complete.bats`. First add
fixture tests and run them against current main: `--check --root` is ignored, so
an unregistered fixture skill incorrectly exits 0; record that meaningful RED.
Then implement the checker and wrapper. Return ≤40 lines: files changed;
failing/passing commands and exit codes; exact diagnostics; blockers. Include
the anti-cheating clause above.**

Implementation:

1. Add explicit CLI parsing: normal no-arg generation remains byte-identical;
   `--check [--root <repo>]` writes nothing; unknown args exit 2.
2. In check mode, sort and report every gap, exit 1 on gaps and 0 only when:
   every `skills/*/SKILL.md` except named `DECK_EXEMPT_SKILLS = {"install"}` is
   in `GENERIC_SKILLS`; every generic skill has one `graph.skills` `_file`
   node; and every crew in `member_crews(roles)` has its own authored `_file`
   entry (never `default_prose`).
3. The wrapper only resolves repo root, invokes the Python check, and preserves
   its status.
4. Orchestrator wires the wrapper after staged leak-check in
   `.githooks/pre-commit` (remove the final `exec` so both blocking gates run),
   adds a dedicated CI step and syntax coverage in
   `.github/workflows/checks.yml`, and adds the command to both
   `.agents/gates.md` and `skills/gates.md.template`. The former is Shipyard's
   gitignored live project gate: mirror the tracked template wording there and
   record the line in the Ledger, but never try to stage it.

`tests/deck-complete.bats` covers unregistered skill, missing graph node,
missing per-role editorial, only-`install` exemption, complete fixture, sorted
multi-gap output, and no-write behavior. It must also execute a fixture commit
with the copied hook and prove incomplete deck exit nonzero.

Phase-specific verification:

```bash
bats tests/deck-complete.bats
python3 scripts/gen-deck-data.py --check --root .
bash scripts/check-deck-complete.sh
rg -n 'check-deck-complete' .githooks/pre-commit \
  .github/workflows/checks.yml .agents/gates.md skills/gates.md.template
```

Observable DoD: the real repo reports `deck-complete: 7 installed skills
complete`; fixture gaps are named and fail; check mode leaves its output file
hash unchanged; hook and CI invoke the wrapper.

## P1 — skill, registration, deck, and discovery (5 points)

**Delegation: subagent (2, disjoint ownership). Agent A owns only
`skills/ui-design/SKILL.md` and `tests/ui-design-contract.bats`: add contract
tests first, show them failing because the skill is absent, then author the
self-contained skill. Agent B owns only `tests/install-skills.bats`,
`tests/harness-install.bats`, `tests/relink.bats`, `tests/doctor.bats`, and
`tests/uninstall.bats`: add explicit `ui-design` expectations and show them
failing before registration. Each returns ≤40 lines with files, RED/GREEN
commands and exact status, evidence, blockers; include the anti-cheating clause.
Agents must not edit each other's files.**

The orchestrator adds `ui-design` as the eighth `GENERIC_SKILLS` entry, adds
authored design/build/release entries and one graph node to
`docs/deck-editorial.json`, updates only the existing skill-list prose in
`README.md` and `docs/INSTALL.md`, then regenerates
`docs/shipyard-data.json`. Preserve bridge-ticket wording already present.

The contract test pins frontmatter and one-line anchors for every content area;
provider/plugin/model terms are absent. Discovery tests pin both skill roots,
new-fixture `AGENTS.md`, doctor drift, relink repair/dry-run, uninstall ownership,
and no-clobber behavior. Update stale “six/seven skills” comments to the exact
eight installed skills.

Phase-specific verification:

```bash
bats tests/ui-design-contract.bats tests/install-skills.bats \
  tests/harness-install.bats tests/relink.bats tests/doctor.bats \
  tests/uninstall.bats
python3 scripts/gen-deck-data.py
python3 scripts/gen-deck-data.py --check --root .
bash scripts/check-deck-fresh.sh
bash scripts/check-deck-complete.sh
jq -e '[.crew[] | select(.id=="design" or .id=="build" or .id=="release") |
  .skills[] | select(.name and (.name|ascii_downcase|contains("ui")))] |
  length == 3' docs/shipyard-data.json
jq -e '.graph.skills | any(.id=="ui-design")' docs/shipyard-data.json
```

After the scoped commit, verify the post-commit relink gave every active fleet
repo a resolving `.agents/skills/ui-design` and `.claude/skills/ui-design`.
Report, but do not overwrite, any real directory at either destination.

## P2 — design-intake callers (2 points)

**Delegation: subagent (1) — own `tests/ui-design-contract.bats` plus
`skills/feature/SKILL.md`, `skills/write-ticket/SKILL.md`, and
`skills/polish-ticket/SKILL.md`. Add caller assertions first and record RED;
then add conditional, one-line referrals. Replace both dangling `new-spec`
references with `ui-design`; preserve non-UI flow. Return ≤40 lines with scoped
diff, commands/status, evidence, blockers; include the anti-cheating clause.**

Phase-specific verification:

```bash
bats tests/ui-design-contract.bats
! rg -n 'new-spec' skills/
git diff HEAD -- skills/feature/SKILL.md skills/write-ticket/SKILL.md \
  skills/polish-ticket/SKILL.md
```

The diff must be referral-only, with no frontmatter change and all content
assertions fitting within one hard-wrapped source line.

## P3 — build and cold-release callers (3 points)

**Delegation: subagent (1) — own `tests/ui-design-contract.bats`,
`skills/execute-ticket/SKILL.md`, and `agents/release/critic-role.md`. Add
caller assertions first and record RED; then add conditional referrals:
execute-ticket applies the skill before UI implementation/real viewport
verification, and the cold critic reads `.agents/skills/ui-design/SKILL.md`
only when real diff hunks affect a front-end. Preserve the critic's hunk-safe
rule and output schema. Return ≤40 lines with files, commands/status, evidence,
blockers; include the anti-cheating clause.**

Phase-specific verification:

```bash
bats tests/ui-design-contract.bats tests/shoulder-mode.bats \
  tests/hunk-safe-gates.bats
git diff HEAD -- skills/execute-ticket/SKILL.md agents/release/critic-role.md
bash scripts/check-deck-fresh.sh
```

The caller changes are additive instructions only: no runner, config, event,
exit-code, or non-UI behavior changes.

## P4 — end-to-end, Pages-current, and graduation (2 points)

**Delegation: inline (the orchestrator must personally read the final gates,
rendered deck result, fleet links, CI, and published bytes).**

Run the common gate, targeted suites, `./install.sh --doctor --project .`, and
`./install.sh --relink --dry-run --project .`; require doctor 0 and dry-run
`0 would be repaired`. Confirm `bats --count tests/` is greater than 380 and the
full suite passes that exact count. Confirm the scoped diff contains no new
prose guide.

Commit on `main`, push normally, require current-SHA CI completed/success:

```bash
gh run list --workflow checks.yml --branch main --limit 1 \
  --json databaseId,headSha,status,conclusion,url
```

GitHub Pages deploys from `main:/docs`; the configured pre-push cascade mirrors
the same deck. Poll both URLs for HTTP 200 and require each downloaded
`shipyard-data.json` SHA-256 to equal local `docs/shipyard-data.json`:

```text
https://wabbazzar.com/shipyard/shipyard-data.json
https://wabbazzar.com/writing/the-shipyard/shipyard-data.json
```

If either remains stale after a bounded two-minute poll, stop with the HTTP
codes/hashes; do not claim Pages current. Once gates, CI, and both URLs agree,
append exact evidence to the Ledger and run:

```bash
scripts/ticket-lifecycle.sh --graduate \
  docs/tickets/pending/ui-design-skill.md
```

Include the move in the final evidence commit and push it.

## Definition of Done

- [x] Deterministic completeness check fails fixtures for all three omission
      classes, writes nothing, passes the real deck, and blocks in hook + CI.
- [x] `ui-design` is the eighth installed shared skill, self-contained and
      model-agnostic, with the locked craft/accessibility content.
- [x] Both discovery roots install, doctor, relink, dry-run, uninstall, and
      no-clobber behavior are covered by failing-first tests.
- [x] Deck has authored design/build/release entries and graph node; generated
      JSON is fresh, complete, and renders.
- [x] Existing canonical README/install prose names eight skills; no new guide.
- [x] Feature/write/polish/execute and the cold critic conditionally consult the
      skill; no dangling `new-spec`, runner, config, or non-UI behavior change.
- [ ] Full suite exceeds the 380-test baseline; syntax, leak, lifecycle, deck
      freshness/completeness/render, doctor, relink dry-run, and CI are green.
- [ ] Both published deck JSON hashes match local; ticket is graduated in the
      final commit.

## Ledger

Each phase appends: plan, `builder:` line, files, failing-first evidence,
independently rerun commands with exit codes/test counts, commit SHA, and honest
deferred/blocker notes.

- P0 — complete. `builder: subagent (1 gate agent)` owned
  `gen-deck-data.py`, the wrapper, and nine fixture tests; the orchestrator
  wired and reviewed hook/CI/gate references. RED on the pre-change generator:
  focused suite 1/8 passed and 7/8 failed because `--check --root` was ignored.
  GREEN: focused 9/9, including a byte-identical copied hook blocking a real
  fixture commit with `GAP rogue: missing from GENERIC_SKILLS`; full suite
  389/389. Syntax, `py_compile`, leak, lifecycle, deck fresh/complete/render,
  doctor, and diff checks all exited 0. Real check reported
  `deck-complete: 7 installed skills complete`. Files:
  `scripts/gen-deck-data.py`, `scripts/check-deck-complete.sh`,
  `tests/deck-complete.bats`, `.githooks/pre-commit`,
  `.github/workflows/checks.yml`, `skills/gates.md.template`; mirrored live
  `.agents/gates.md` without staging it. Commit: `45b50dd`; CI
  `30393365020` completed successfully.
- P1 — ready for scoped commit. `builder: subagent (1 reusable agent; 2
  disjoint briefs)` authored the skill/7 contract tests, then five install
  suites; the orchestrator registered it, authored three deck cards and one
  graph node, regenerated JSON, and edited only existing README/INSTALL prose.
  RED A: 0/7 while the skill was absent. RED B: 38/51, with all 13 failures
  naming absent `ui-design` install/doctor/relink/uninstall/bridge behavior.
  GREEN: focused 58/58; full 400/400; syntax, `py_compile`, leak, lifecycle,
  deck fresh/complete/render, jq crew/graph assertions, and diff checks exited
  0. Completeness reports 8 installed skills. The generic validator rejects
  Shipyard's required extended frontmatter; Shipyard's own parser accepts it.
  Pre-commit live doctor truthfully reports the two new links missing; the
  post-commit fleet hook owns that transition, which is verified before P2.
  Commit: `4114c55`. Fleet relink gave Shipyard and six active repos both
  resolving discovery links, with zero worktree targets; doctor was clean and
  relink dry-run reported 0 repairs. CI `30394263137` caught one stale P0
  assertion still expecting 7 installed skills; follow-up `cb0ccb2` updated it
  to 8, passed 400/400 locally, and CI `30394625074` completed successfully.
- P2 — ready for scoped commit. `builder: subagent (1 caller agent)` added
  three failing-first caller contracts and referral-only changes in feature,
  write-ticket, and polish-ticket. RED: existing 7 passed and all 3 new caller
  tests failed on missing referrals. GREEN: focused 10/10; both dangling
  `new-spec` references are gone; frontmatter and non-UI flow are unchanged;
  full 403/403; syntax, `py_compile`, leak, lifecycle, deck
  fresh/complete/render, doctor, and diff checks passed. Commit: `936f350`; CI
  `30395237827` completed successfully.
- P3 — ready for scoped commit. `builder: subagent (1 caller agent)` added two
  failing-first contracts and additive referrals in execute-ticket and the cold
  critic. RED: 33/35, with both new callers absent. GREEN: focused 35/35;
  all 21 shoulder-mode and both hunk-safe cases pass; cold inputs, output
  schema, non-UI flow, runners, config, events, and exit codes are unchanged.
  Full 405/405; syntax, `py_compile`, leak, lifecycle, deck
  fresh/complete/render, doctor, and diff checks pass. Commit: this scoped P3
  commit; SHA/CI are recorded in P4.
- P4 — pending

---

Run it with `execute-ticket`.
