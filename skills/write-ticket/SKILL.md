---
name: write-ticket
roles: [design, human]
disposition: new
kind: pipeline
description: >
  CREATE a project ticket (docs/tickets/*.md) from an ask — turn "we should
  build X" or "Y is broken" into a comprehensive, numbered, implementation-ready
  ticket with an explicit Definition of Done. Use when the user says "write a
  ticket for X", "create a ticket", "draft a ticket for this", or hands you a
  feature/bugfix/refactor ask that should become tracked work. This is the
  REQUIREMENTS-GATHERING precursor to polish-ticket: you establish WHAT and WHY
  (scope, acceptance criteria, phased plan); polish-ticket then hardens HOW to
  build it safely. You do NOT build the work and you do NOT harden the ticket —
  you produce the ticket that polish-ticket accepts without structural rework.
  Reads the project's own ticket conventions from a [write_ticket] config block
  (never bakes them). Callable headless by the design crew after an ask enters
  the loop, and interactively by a human operator — identical file, no forks.
---

# write-ticket — turn an ask into a buildable ticket

A ticket written from assumptions is worthless. The job here is to interrogate
the real project — its conventions, its code, the actual gap — and emit a
ticket so complete that `polish-ticket` only has to harden it, never
restructure it. This skill establishes **what and why**; `polish-ticket`
establishes **how to build it safely**; `execute-ticket` builds it. Keep those
three jobs distinct — do not harden here (no per-phase gate assembly, no
verification-surface commands — that is polish-ticket's job) and do not build.

**You are the front of the loop.** A machine ask (a stamped design proposal) or
a human ask (`/bugfix`, `/feature`, or a direct "write a ticket for…") both
converge here. `/bugfix` and `/feature` do the intent-specific intake
(reproduce-first / clarify-first) and then call you with a scope; a direct
invocation does the intake inline.

## Step 0 — Read the project's conventions (never bake them)

Every project numbers, types, and phases its tickets differently. Read those
parameters; do not assume them. Sources, in order:

1. **`<project>/.agents/config.toml` `[write_ticket]` block** — the authority.
   Keys it may set (all optional; sensible defaults below):
   - `context_files` — the files to read before writing (spec, conventions,
     data-model docs). Read every one.
   - `ticket_dir` — where tickets live (default `docs/tickets/`). May be split
     into `ticket_dir` + `backlog_dir` + `archive_dir`; **scan all of them**
     when resolving the next id.
   - `types` — the allowed `type` enum (default
     `feature | bug | refactor | chore | docs | test`). Normalize the
     `feat_`→`feature_` filename drift.
   - `point_scale` + `phase_point_cap` — estimation scale (default fibonacci
     `1,2,3,5,8,13`) and the max effort per phase (default 5).
   - `phase_taxonomy` — an optional fixed phase vocabulary (e.g. a project that
     labels phases `1-CLI | 2-UI | …`). **Most projects have none** — omit the
     `Phase:` metadata line entirely rather than inventing a taxonomy.
   - `commit_scopes` — the conventional-commit scopes this project uses.
   - `test_cmds` — the commands a phase's Testing Strategy should name.
   - `viewport` — the render viewport for UI-facing acceptance (a phone PWA is
     checked at mobile width).
   - `house_rules` — project mandates every ticket must respect (commit
     attribution policy, worktree hygiene, a rebuild-after-edit rule, the
     single notification path).
2. **The project's gate file** (`<project>/.agents/gates.md`) — fallback for
   test/build commands and house rules when the config block is silent. This is
   the same file `polish-ticket` reads; you cite the gate classes that will
   apply, you do not assemble the verification surface (polish does that).
3. **The most recently written ticket** in the ticket dir — inherit its section
   structure, status-header convention, and numbering; don't reinvent a house
   style the project already has.

**Absent a `[write_ticket]` block AND no prior ticket to mirror**, default to: a
flat `<ticket_dir>/XXX_<type>_<short_desc>.md` name (3-digit zero-padded id),
the section template below, fibonacci points capped at 5/phase, and **no** fixed
phase taxonomy.

## Step 1 — Resolve the next ticket id

Scan the ticket dir (and any `backlog/` + `archive/` split), find the highest
`XXX_` prefix across all of them, add 1, zero-pad to the project's width
(default 3). If the dir doesn't exist yet, start at `001`. Never reuse a number.

## Step 2 — Clarify only what genuinely blocks (default-and-record)

Don't interrogate a clear ask. The style is **default-and-record**: lock a
sensible default into the ticket's own decisions table for the user to veto at
review, and ask a one-at-a-time question **only** for an ambiguity that would
change what gets built and that you can't settle by reading. State up front how
many (if any) questions you need — "I need to ask 2 clarifying questions" — then
ask one, wait, ask the next. A ticket that stalls on questions a config read or
a code read would have answered is a tax on the user's time.

(When called by `/bugfix` or `/feature`, the intent-specific clarification —
reproduce-first or assumptions-and-verify — has already happened; don't repeat
it. Take the scope they hand you.)

## Step 3 — Interrogate the real code (carry file:line, not prose)

Before writing the plan, read the actual source the work touches: the module,
the similar prior implementation, the types in use, whether the file paths you
name exist or will be created. Every technical claim in the ticket is anchored
to a real `path:line` or a named symbol — "a ticket written from assumptions is
worthless." If you're guessing, you haven't read enough.

## Step 4 — Emit the ticket

Write to `<ticket_dir>/<id>_<type>_<short_desc>.md`. Sections (adapt headings to
the project's prior-ticket style; keep the substance):

- **Metadata** — Status, Priority, Type (from the enum), Estimated Points, and
  `Phase:` **only if** the project declares a `phase_taxonomy`.
- **Summary** — 1–2 sentences: what needs to be done.
- **Problem / Background** — why this work exists, the gap it closes, context
  for the decision. For a bug, this carries the reproduction the `/bugfix` intake
  captured (the acceptance anchor).
- **Technical Requirements** — data structures/types, code locations (files to
  create vs modify, with `path:line`/function names), dependencies. Cite the
  project's spec/convention docs where they govern.
- **Implementation Plan** — phased into thin vertical slices, **each ≤ the
  per-phase point cap and independently verifiable + committable**. Per phase:
  goal, concrete steps, files touched, and what proving-it-works looks like at a
  high level (the exact gate commands are polish-ticket's to assemble — name the
  gate *class*, not the command line).
- **Testing Strategy** — the test kinds and the project's test commands
  (`test_cmds`) that cover the new behavior; for a bug, the regression test that
  closes the named coverage gap.
- **Acceptance Criteria / Definition of Done** — a **checklist** of concrete,
  observable outcomes ("without a checklist, 'done' is opinion"). Use the
  project's existing DoD convention; do not reinvent one. Each item is
  verifiable, not aspirational ("returns within 200ms at p99", not "fast").
- **Dependencies** — blocked-by / blocks / external, or "None".
- **Risks & Mitigations** — the real ones, with a mitigation each.
- **Out of scope** — what this ticket deliberately does not do (keeps the build
  from sprawling).

Follow the project's commit standards, including its **attribution policy** —
many projects forbid AI attribution in ticket-file commits; read
`house_rules`/CLAUDE.md and honor it. Commit the ticket file itself per the
project's worktree hygiene.

## Step 5 — Hand off

Say the ticket is a **draft ready for `polish-ticket`** — you established scope
and acceptance; polish-ticket hardens the verification surface and phasing for
autonomous build. Unless the user said "and build it," stop at the human gate:
the ticket is queued/surfaced for a stamp, exactly as a stamped design proposal
would be. `/bugfix` and `/feature` respect the same gate.

## Adaptation Contract

- **Parameter surface** (what install/config supplies, so this skill stays
  generic): the `[write_ticket]` block in `<project>/.agents/config.toml`
  (context files, ticket dir + optional backlog/archive split, type enum, point
  scale + per-phase cap, optional phase taxonomy, commit scopes, test commands,
  viewport, house rules) with the project's gate file as fallback. None of these
  are baked into this skill — it reads them from the project.
- **Learning surface** (where lessons accumulate): the project's own ticket
  conventions. When a project evolves how it writes tickets (a new section, a
  changed numbering scheme, a new house rule), that lands in its `[write_ticket]`
  block or its most-recent ticket's shape, and every future ticket — human- or
  agent-written — inherits it. A portable lesson (a section every project should
  carry) instead becomes an edit to the Step 4 template here, shipped as a core
  PR.

## Anti-patterns to refuse

- **Writing from assumptions.** No ticket before you've read the config, the
  governing docs, and the real code. Guessing paths or types produces a ticket
  that wastes the builder's time.
- **Hardening here.** Assembling per-phase gate commands, verification surfaces,
  or the anti-cheating orchestration brief is `polish-ticket`'s job. Stop at
  scope + acceptance; hand off.
- **Building here.** Editing app code, running the fix, implementing the
  feature — that's `execute-ticket`, behind the human gate. A ticket-writer that
  starts coding has overreached.
- **Inventing a phase taxonomy.** Most projects have none. Omit `Phase:` unless
  the config declares one.
- **Baking a project's specifics into this file.** Ticket dir, type enum,
  scopes, commands — all config-driven. This file ships in a public repo; it
  names no project.
- **A vacuous Definition of Done.** "It works" is not acceptance. Every DoD item
  is an observable check.
