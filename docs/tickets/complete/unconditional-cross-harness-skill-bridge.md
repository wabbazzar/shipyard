# Make Shipyard skills discoverable in every installed project

- **Created:** 2026-07-27
- **Owner:** wabbazzar
- **Status:** Built + verified — bridge and canonical documentation complete
- **Priority:** high
- **Type:** bugfix
- **Estimated Points:** 1 remaining (evidence/documentation closeout)
- **Refs:** `install.sh` (`write_skill_bridge`, `SKILLS_DESTS`, `--doctor`,
  `--relink`), `tests/harness-install.bats`, `tests/relink.bats`,
  `tests/doctor.bats`, `README.md` Skills-parity, `docs/INSTALL.md` L5.

## Goal

An interactive Codex, Claude, or Hermes session opened in any Shipyard-installed
repository discovers the same project-local Shipyard skill files. Installation
and repair must remain universal, idempotent, and ownership-safe.

The implementation is already landed. A cold agent must **not** rebuild it.
The only remaining work is a concise clarification in the two existing
canonical install documents, current verification evidence, and ticket
graduation.

## Current truth

The original prototype landed at `6650518` and was merged by `e1a9b31`. It made
the root `AGENTS.md` bridge unconditional, preserved an existing project-owned
bridge, and added doctor/relink/dry-run coverage.

Codex does not use `.claude/skills/` as its native repository discovery root.
Commit `60b75c9` corrected the prototype by installing the same shared skills
under both:

- `.agents/skills/` — Codex-native project discovery;
- `.claude/skills/` — Claude/Hermes compatibility.

The generated root `AGENTS.md` names `.agents/skills/<name>/SKILL.md`.
`write_skill_bridge` is shared by normal install and `--relink`; it never
clobbers an existing file or symlink. `--doctor` detects a missing bridge and
missing links in either root. `--relink --dry-run` reports drift and writes
nothing.

On 2026-07-28, the targeted command below returned 35/35 passing:

```bash
bats tests/harness-install.bats tests/relink.bats tests/doctor.bats
```

## Locked decisions

| Decision | Locked result |
|---|---|
| Discovery scope | Project-local only; never install into a global Codex, Claude, or Hermes home. |
| Codex root | `.agents/skills/`; `.claude/skills/` remains the compatibility root. |
| Existing `AGENTS.md` | Project-owned; never overwrite, append, or reject its contents. |
| Repair scope | Links plus a missing generated bridge only; no timer, unit, gate, or config rebake. |
| Public explanation | Edit existing `README.md` and `docs/INSTALL.md` only; create no new document. |
| Host UI boundary | Shipyard controls repository files, not a host-managed/global skill-picker catalog or UI. |

There are no open decisions and no spend, publication, destructive change, or
live-automation change in the remaining phase.

## Historical implementation

### Phases 1–2 — universal bridge and Codex-native discovery — complete

Prototype builder: another agent (`6650518`, merged by `e1a9b31`).
Codex-native correction builder: inline (`60b75c9`).

Acceptance already implemented:

- Claude-only and mixed-harness installs create the bridge when absent.
- Existing `AGENTS.md` content remains byte-for-byte unchanged.
- `.agents/skills/` and `.claude/skills/` link to the same Shipyard sources.
- Doctor reports missing bridge/link drift.
- Relink repairs missing links/bridge; dry-run writes nothing.

Do not modify `install.sh`, `skills/install/SKILL.md`, or the three targeted
test files during closeout unless a real gate exposes a new regression. If one
does, stop and report the exact failure; this ticket does not authorize an
unplanned implementation pass.

## Remaining phase — canonical docs, evidence, graduate (1 point)

**Delegation: inline (two tightly coupled canonical-doc sentences plus gate
commands whose output the orchestrator must personally read).**

> Converge honestly or report the precise blocker with the actual evidence —
> NEVER fake green, weaken a check, or hand-wave "should work". Run the real
> command, read the real file, curl the real port, and report exact output
> (exit codes, JSONL lines, HTTP codes), not adjectives.

### Change

Edit only the existing Skills-parity paragraph in `README.md` and L5 in
`docs/INSTALL.md`; add no heading and no new file. Add at most one concise
three-sentence paragraph per file. Each location must state:

1. Shipyard installs project-local links in `.agents/skills/` for Codex and
   `.claude/skills/` for Claude/Hermes, all resolving to the same source files.
2. The generated `AGENTS.md` is repository guidance and never clobbers an
   existing project-owned file.
3. Shipyard cannot add entries to a host-managed/global skill-picker catalog or
   control how that UI labels repository-discovered skills.

Do not promise that every host UI visibly lists these skills. The observable
contract is repository discovery and readable symlink targets.

### Verification

From the Shipyard checkout:

```bash
bats tests/harness-install.bats tests/relink.bats tests/doctor.bats
./install.sh --doctor --project .
./install.sh --relink --dry-run --project .
```

Require 35/35 targeted tests, doctor exit 0, and relink dry-run exit 0 with
`0 would be repaired` and `AGENTS.md: exists — leaving as-is`.

Verify Codex's deterministic discovery surface without spending a model call:

```bash
for skill in write-ticket polish-ticket execute-ticket; do
  test "$(readlink -f ".agents/skills/$skill")" = \
    "$(readlink -f "skills/$skill")"
  grep -Fq ".agents/skills/$skill/SKILL.md" AGENTS.md
done
```

Then run the full project gates from `.agents/gates.md`:

```bash
bats tests/
bash -n install.sh agents/lib/*.sh agents/*/runner.sh \
  agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh
gh run list --workflow checks.yml --branch main --limit 1 \
  --json databaseId,headSha,status,conclusion,url
```

The latest run for the current `main` SHA must be completed/success. Append
exact exit codes, test counts, dry-run summary, resolved paths, and CI JSON to
the Ledger. Finally run:

```bash
scripts/ticket-lifecycle.sh --graduate \
  docs/tickets/pending/unconditional-cross-harness-skill-bridge.md
```

Include the ticket move in the same final closeout commit as the two
documentation edits.

## Definition of Done

- [x] Claude-only installs receive a generated root `AGENTS.md`.
- [x] Existing project-owned `AGENTS.md` files are unchanged.
- [x] Codex-native `.agents/skills/` and compatibility `.claude/skills/` links
      resolve to the same Shipyard skill sources.
- [x] Doctor detects missing bridge/link drift; relink repairs it; dry-run
      creates nothing.
- [x] Targeted bridge/install/doctor tests pass 35/35.
- [x] Existing canonical install docs state both discovery roots and the
      host-managed/global skill-picker boundary, with no new documentation.
- [x] Current targeted, deterministic discovery, full-gate, doctor, dry-run,
      and CI evidence is recorded below.
- [x] Ticket graduates to `complete/` in the documentation closeout commit.

## Ledger

### Prototype and Codex-native correction

builder: another agent for prototype; inline for native-root correction.

- `6650518` — unconditional bridge, ownership boundary, doctor/relink coverage.
- `e1a9b31` — prototype merged to `main`.
- `60b75c9` — `.agents/skills/` Codex-native discovery added alongside
  `.claude/skills/`.
- Targeted verification on 2026-07-28: 35/35 passing.

### Documentation and evidence closeout

builder: inline (two tightly coupled canonical-doc edits under 30 lines, plus
gate commands whose output the orchestrator must personally read).

Plan: update only the existing README Skills-parity paragraph and INSTALL L5
paragraph, then prove the targeted bridge contract, deterministic Codex links,
doctor/relink behavior, complete project gates, and current CI before
graduating. No product implementation or new documentation is planned.

Result: the two existing canonical paragraphs now state both discovery roots,
generated-bridge ownership, and the host-managed picker boundary. Targeted
bridge/install/doctor tests passed 35/35; doctor returned clean checks a–j;
relink dry-run reported `0 would be repaired, 15 already ok` and preserved
`AGENTS.md`. Deterministic probes resolved write-ticket, polish-ticket, and
execute-ticket from `.agents/skills/` to this repository's source directories.
The complete Bats suite passed 380/380; syntax, Python byte-compile, leak,
deck freshness, deck render, and lifecycle checks passed. GitHub checks run
`30391785223` completed successfully for polished-ticket commit `7d68954`.

---

Run the remaining phase with `execute-ticket`.
