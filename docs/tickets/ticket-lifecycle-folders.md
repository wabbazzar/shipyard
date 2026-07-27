# Ticket lifecycle folders: make the pipeline move tickets, not just write them

- **Created:** 2026-07-27
- **Owner:** wabbazzar
- **Status:** Proposed — ready for polish
- **Priority:** high
- **Type:** feature
- **Estimated Points:** 11 (4 phases, cap 5/phase)
- **Refs:** `skills/write-ticket/SKILL.md:46-49,73-81` (`ticket_dir` /
  `backlog_dir` / `archive_dir`, id resolution), `skills/polish-ticket/SKILL.md:27`
  (hardcoded `docs/tickets/<name>.md`), `skills/execute-ticket/SKILL.md:180-188`
  (Step 5 — Finish), `skills/shipyard/shipyard.sh:285,298` (`learn` writes bare
  `docs/tickets/learned-*.md` / `installer-question-*.md`),
  `skills/gates.md.template`, `skills/install/SKILL.md`

## Goal

The pipeline can **write** a ticket and **build** it, but nothing in it ever
**moves** a ticket. A finished ticket sits in the same directory as an unstarted
one forever, and the only way to know which is which is to open the file and read
a prose `Status:` line. Make lifecycle a first-class, checkable property: a
ticket lives in exactly one of three folders, the folder IS the status, and
`execute-ticket` is required to move it as part of the commit that finishes it.

```
<ticket_dir>/pending/     not finished — proposed, polished, blocked, partially built
<ticket_dir>/complete/    every phase built AND verified
<ticket_dir>/freezer/     parked by the owner — deferred, superseded, won't-do-now
```

Aurora adopted exactly this layout on 2026-07-27 (`aurora@512b6bb`: 36 tickets
migrated to `docs/tickets/{pending,complete,freezer}/<NNN>_<type>_<short_slug>.md`).
It works, but it is currently enforced only by aurora's own
`.agents/config.toml` `house_rules` string and a project-local gate class — every
other project on the fleet gets nothing, and the skills themselves have no idea
the folders exist. This ticket lifts it into core so it is the fleet default and
so the skills actively maintain it.

## Problem / Background

Four concrete gaps, each verifiable against the current code:

1. **`write-ticket` half-knows about the split.** `SKILL.md:46-49` already
   documents `ticket_dir` + `backlog_dir` + `archive_dir` and says "**scan all of
   them** when resolving the next id" (`:73-81`). But it never says *which* folder
   a new ticket is born in, and its stated default (`<ticket_dir>/XXX_<type>_<short_desc>.md`)
   is a flat path. A project that sets all three keys gets correct id resolution
   and an ambiguous write target.

2. **`polish-ticket` hardcodes the flat path.** `SKILL.md:27` states "Tickets
   live in `docs/tickets/<name>.md`" — it does not read `[write_ticket]` at all.
   On a lifecycle-foldered project it will describe, and may relocate, tickets
   wrongly.

3. **`execute-ticket` never graduates a ticket.** Step 5 (`SKILL.md:180-188`)
   re-runs the gate, sweeps leftovers, updates the Ledger, and notifies — but the
   ticket file stays exactly where it started. This is the load-bearing gap: the
   whole scheme is worthless if completion doesn't move the file, because then
   `pending/` silently accumulates finished work and stops being trustworthy.

4. **`shipyard learn` writes outside any lifecycle.** `shipyard.sh:285` and
   `:298` `mkdir -p "$dir/docs/tickets"` and write `learned-<slug>.md` /
   `installer-question-<slug>.md` — a hardcoded path, ignoring `ticket_dir`, and a
   filename that matches no project's naming convention. On aurora these would now
   land in the tree root next to `pending/`, unnumbered and unfoldered.

**Backward compatibility is the hard constraint.** Most fleet projects use a flat
ticket dir (shipyard itself uses flat kebab slugs, `docs/tickets/<slug>.md`).
Per the house rule, the new behavior lands behind config whose **unset value is
exactly today's behavior**: absent `lifecycle_dirs`, every skill behaves
byte-for-byte as it does now.

## Proposed config surface

One new optional `[write_ticket]` key, plus the three existing dir keys:

```toml
[write_ticket]
ticket_dir     = "docs/tickets/pending"    # where NEW tickets are written
archive_dir    = "docs/tickets/complete"   # where FINISHED tickets are moved
backlog_dir    = "docs/tickets/freezer"    # where PARKED tickets are moved
scan_dirs      = [ "docs/tickets/pending", "docs/tickets/complete", "docs/tickets/freezer" ]
lifecycle_dirs = true                      # UNSET/false = today's behavior exactly
```

`lifecycle_dirs = true` is what turns on the *moving*. A project may already set
`archive_dir` for id-scanning purposes without wanting `execute-ticket` to
relocate files; the explicit flag keeps that project unaffected.

## Implementation Plan

Every phase: a bats case shown failing against the pre-change code FIRST, then
the change. No test reaches GitHub, the network, or a model.

### Phase 1 — `write-ticket`: name the birth folder (points: 2)

- `skills/write-ticket/SKILL.md` Step 0: document `lifecycle_dirs` alongside the
  existing dir keys, and state plainly that **new tickets are always written to
  `ticket_dir`** — which under a lifecycle layout is the pending folder. Ids are
  resolved by scanning all of `scan_dirs` (already specified at `:73-81`; make the
  "never reuse, never renumber" rule explicit).
- Step 4's write target becomes `<ticket_dir>/<id>_<type>_<short_desc>.md`
  unchanged — the only change is that `ticket_dir` may now be a lifecycle folder.
- Gate: bats case asserting id resolution picks the max across three dirs, and a
  case asserting a flat-config project's write target is unchanged.

### Phase 2 — `polish-ticket`: read the config instead of hardcoding (points: 2)

- Replace the hardcoded `docs/tickets/<name>.md` at `SKILL.md:27` with "tickets
  live where `[write_ticket]`'s dir keys say they live; read them, never guess."
- Polish **never moves** a ticket — it hardens in place. State that explicitly so
  no agent invents a move here.
- Gate: bats case on a lifecycle-configured fixture asserting polish leaves the
  file path untouched.

### Phase 3 — `execute-ticket`: graduate the ticket on completion (points: 5)

This is the phase that makes the scheme real.

- Add a **Ticket lifecycle** step to Step 5 — Finish (`SKILL.md:180-188`): when
  `lifecycle_dirs` is on and every in-scope phase is green and committed,
  `git mv <ticket_dir>/<file> <archive_dir>/<file>` **in the same commit that
  lands the final verified phase**, with the `Status:` line updated to carry the
  commit hashes. The filename never changes — only the folder.
- Partial completion (phases deferred, blocked on a user decision) leaves the
  ticket in `ticket_dir` and says so in the Ledger. **Only the owner** sends a
  ticket to `backlog_dir`; an autonomous run never freezes a ticket by itself.
- Add the corresponding gate class to `skills/gates.md.template` so new installs
  inherit it, mirroring the one aurora now carries at `.agents/gates.md`
  ("Ticket lifecycle — APPLIES: yes (final phase of every ticket)").
- Gate: bats case asserting the move happens on full completion; a case asserting
  it does NOT happen on partial completion; a case asserting a flat-config
  project sees no move at all.

### Phase 4 — `shipyard learn` + installer honor the layout (points: 2)

- `skills/shipyard/shipyard.sh:285,298`: read `ticket_dir` from the project's
  `.agents/config.toml` (the same `lib/load-config.sh` path the runners use)
  instead of the hardcoded `docs/tickets`, and fall back to `docs/tickets` when
  unset. Keep the `learned-` / `installer-question-` prefixes — these are
  deliberate draft stubs, not conforming tickets — but drop them in the project's
  actual pending dir so they are visible where tickets are looked for.
- `skills/install/SKILL.md`: add the lifecycle layout to the installer interview
  as an explicit question (default **off**, i.e. today's flat behavior), and have
  a "yes" answer create the three dirs and write the four config keys.
- Regenerate `docs/shipyard-data.json` (`python3 scripts/gen-deck-data.py`) if any
  SKILL.md frontmatter changed.
- Gate: bats case on `shipyard learn` routing to a configured pending dir and to
  the flat fallback; `bash scripts/leak-check.sh`; `bash scripts/check-deck-fresh.sh`.

## Definition of Done

- [ ] A project setting the four config keys gets: new tickets born in `pending/`,
      ids resolved across all three folders, polish in place, and an automatic
      `git mv` to `complete/` in the final phase's commit.
- [ ] A project setting none of them behaves **byte-for-byte** as it does today —
      proven by a bats case, not asserted.
- [ ] `shipyard learn` stubs land in the project's configured ticket dir.
- [ ] The installer can set the layout up, and new installs inherit the gate class.
- [ ] `bats tests/`, `scripts/leak-check.sh`, `scripts/check-deck-fresh.sh` green.

## Reference implementation

Aurora, commit `512b6bb` (`~/code/aurora`) — the migration this ticket
generalizes. Worth reading before Phase 3:

- `docs/tickets/README.md` — the conventions as written for humans
- `.agents/config.toml` `[write_ticket]` — the dir keys + the `house_rules`
  lifecycle paragraph
- `.agents/gates.md` — the "Ticket lifecycle" gate class to lift into the template
- `CLAUDE.md` §Ticket Hygiene

Aurora's naming (`<NNN>_<type>_<short_slug>.md`, 3-digit never-reused id) is
already the documented shipyard default at `write-ticket/SKILL.md:73`; it is the
**folders**, not the names, that this ticket adds to core.

## Open questions

1. Should `lifecycle_dirs` be a separate boolean at all, or should the presence of
   `archive_dir` be sufficient to enable moving? (Proposed: keep it separate —
   `archive_dir` currently means "also scan here for ids", and silently overloading
   it would change behavior for any project that already sets it.)
2. Should `execute-ticket` refuse to finish if the `Status:` line and the folder
   disagree (e.g. a ticket in `complete/` that says "not built")? (Proposed: yes,
   report it as a gate failure — but only when `lifecycle_dirs` is on.)
