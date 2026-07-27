# Ticket lifecycle folders: make the pipeline move tickets, not just write them

- **Created:** 2026-07-27
- **Owner:** wabbazzar
- **Status:** Phase 1 built (`79b3d25`); SCOPE REVISED 2026-07-27 by owner decision — determinism + default-on + fleet migration (see Scope Revision)
- **Priority:** high
- **Type:** feature
- **Estimated Points:** 11 (4 phases, cap 5/phase)
- **Refs (re-anchored 2026-07-27 — today's delegation commits shifted two):**
  `skills/write-ticket/SKILL.md:46-48` (dir keys) and **`:77-82`** (id
  resolution — ticket said `:73-81`), `skills/polish-ticket/SKILL.md:27`
  (hardcoded `docs/tickets/<name>.md` — confirmed), **`skills/execute-ticket/SKILL.md:181-190`**
  (Step 5 — Finish; ticket said `:180-188`), `skills/shipyard/shipyard.sh:284-305`
  (`learn` generic/install stubs), `skills/gates.md.template`,
  `skills/install/SKILL.md`. Aurora reference: `~/code/aurora@512b6bb`.

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

## Out of scope

- Adding `lifecycle_dirs` to **aurora's** live config (user-decision class — see
  Polish Notes; flag to the owner as a follow-up).
- Mechanical enforcement of the move (`scripts/check-ticket-lifecycle.sh`) —
  the move is enforced by instruction + gate class, as stated.
- Migrating **shipyard's own** tickets to the folder layout (O4).
- Retrofitting existing tickets on any project.
- Any runner or systemd unit change.

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

## Open questions — RESOLVED in Decisions below (O1, O2)

---

## POLISH NOTES (added 2026-07-27) — read before building

### ⚠ The promised verification surface does not exist for Phases 1–3

The plan says each of Phases 1–3 lands "a bats case shown failing against the
pre-change code FIRST", e.g. *"a bats case asserting id resolution picks the max
across three dirs"* and *"a case asserting the move happens on full completion"*.
**Those tests cannot exist as written.** Phases 1–3 change **prose in a
`SKILL.md`** — there is no executable code to drive, so nothing can assert that
id resolution "picks the max" or that a move "happens". A bats case can only
assert that *the instruction is present in the file*.

This is a real limitation of the design, not a nit, and it must be stated in the
ticket rather than discovered at build time — a test that cannot fail on the
real defect is a finding, not a test (`.agents/gates.md`, bats gate class).

**Restructured verification surface, per phase:**

| Phase | What changes | What is actually testable |
|---|---|---|
| 1 `write-ticket` | prose | **content contract** — the birth-folder rule and the never-reuse rule are present |
| 2 `polish-ticket` | prose | **content contract** — reads dir keys; "polish never moves a ticket" present |
| 3 `execute-ticket` | prose + gate template | **content contract** + the gate class exists in `skills/gates.md.template` |
| 4 `shipyard learn` | **real bash** in `shipyard.sh` | **behavioral** — run it against fixture projects and assert the written path |

Only Phase 4 gets a genuine failing-first behavioral test. Model the content
contracts on `tests/delegation-contract.bats` (shipped today) — including its two
hard-won rules: **assert a phrase that fits within one source line** (the
Markdown is hard-wrapped, so a regex spanning a break can never match), and
**a guard case must be shown *passing* pre-change** or it is guarding nothing.

**Consequence to accept explicitly:** with `lifecycle_dirs` on, the `git mv` is
enforced by *instruction plus a gate class*, exactly like every other
`execute-ticket` obligation — not by code. That is the same enforcement model as
the Delegation contract shipped today, and it is honest as long as the ticket
does not claim otherwise. If the owner wants mechanical enforcement, that is a
follow-up ticket (a `scripts/check-ticket-lifecycle.sh` run as a gate), and it is
**out of scope here**.

### ⚠ Aurora — the reference project — would get nothing

`~/code/aurora/.agents/config.toml` sets `ticket_dir` / `archive_dir` /
`backlog_dir` / `scan_dirs`, but **not** `lifecycle_dirs` (verified: `grep -c
lifecycle_dirs` → `0`). Under Open Question 1's proposed default (a separate
boolean required to enable moving), aurora — the project this ticket
generalizes, with 27 tickets already in `complete/` — gets **no** moving
behavior until its config gains the key.

The DoD's first line ("A project setting the four config keys gets…") therefore
describes **no project that currently exists**.

Adding that key to aurora changes the behavior of live automation the owner
deliberately configured, on a repo with its own autonomous crew → **user-decision
class**. It is scoped **OUT** of this ticket (see Out of scope) so the build is
not blocked. Flag it to the owner on completion as a one-line follow-up.

### Smaller than written: Phase 4

`skills/shipyard/shipyard.sh` **already** sources `agents/lib/load-config.sh`
(`:43`) and populates `CFG_JSON` (`:46`), and already resolves a per-dir config
path (`:170`). Phase 4 does not need new config machinery — only to read
`ticket_dir` out of the JSON it already has, with a `docs/tickets` fallback.
Note the `learn` subcommand operates on `$dir`, which is **not** always
`$PROJECT_DIR`; read that target's own config, not the ambient one.

## Decisions

### Locked

| # | Decision | Rationale |
|---|---|---|
| L1 | Unset `lifecycle_dirs` ⇒ **byte-for-byte** today's behavior | The repo's config-gated-additivity gate class; proven by a test, not asserted |
| L2 | Phases 1–3 ship **content-contract** tests; only Phase 4 gets behavioral tests | Prose has no executable surface — see Polish Notes |
| L3 | The filename never changes; only the folder | Aurora's rule; the id is the chronology |
| L4 | Polish **never** moves a ticket | Stated so no future agent invents a move step |
| L5 | An autonomous run never freezes a ticket | Only the owner sends work to `backlog_dir` |
| L6 | No `docs/shipyard-data.json` regen expected | No `roles:`/`kind:` or `GENERIC_SKILLS` change; a deck diff is a **defect** |

### Open, with defaults (builder applies and records — never blocks)

| # | Question | Default |
|---|---|---|
| O1 | Separate `lifecycle_dirs` boolean, or infer from `archive_dir`? | **Separate boolean** (the ticket's own proposal): `archive_dir` currently means "also scan here for ids", and overloading it silently changes behavior for any project already setting it |
| O2 | Should `execute-ticket` fail when `Status:` and folder disagree? | **Yes, but only when `lifecycle_dirs` is on** — as a stated gate failure in prose |
| O3 | Where does the gate class text come from? | Lift aurora's `.agents/gates.md:128-140` near-verbatim into `skills/gates.md.template`, genericized (no aurora paths) |
| O4 | Does shipyard itself adopt the layout? | **No** — shipyard keeps its flat kebab slugs; this ticket adds *core support*, and dogfooding it here is a separate decision |

### User-decision class

**None blocking.** The one item (adding `lifecycle_dirs` to aurora's live config)
is scoped out; the build proceeds without it. → auto-gate **PROCEEDS**.

## Per-phase gate commands (from `.agents/gates.md`)

Phases 1–3 (prose + template):
```bash
bats tests/ticket-lifecycle.bats        # shown failing FIRST for each new contract case
bats tests/
git add -N <any new file>               # leak-check scans git ls-files only
bash scripts/leak-check.sh
bash scripts/check-deck-fresh.sh        # MUST stay byte-identical (L6)
```
Phase 4 (real bash) adds:
```bash
bash -n skills/shipyard/shipyard.sh
bash -n install.sh agents/lib/*.sh agents/*/runner.sh agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit
python3 -m py_compile scripts/gen-deck-data.py scripts/delegation-report.py
./install.sh --doctor --project .       # exit 0
```
Final phase re-runs the whole battery end-to-end.

**Baseline to beat (measured 2026-07-27, post-`d5822cd`):** `bats tests/` =
**313 passing, 0 failures**; leak-check clean; deck in sync; doctor exit 0;
**CI green on `main`** — check CI, not only the local suite (`.agents/gates.md`
Traps).

## Traps to pin

- **Fleet-live.** `install.sh:755` symlinks `skills/*` into all 6 installed
  projects; an edit is live at the next timer fire. Prose-only for Phases 1–3
  limits the blast radius; Phase 4 touches real bash — test it hardest.
- **`leak-check.sh` scans tracked files only** — `git add -N` new files first.
- **Hard-wrapped prose vs `grep`** — assert phrases that fit on one source line.
- **Deck coupling** — no frontmatter change is expected (L6); a `check-deck-fresh`
  diff means something unintended changed.
- **`git mv` in the *same* commit as the final phase** — a separate "move the
  ticket" commit leaves a window where the tree says the work is unfinished, and
  is the failure mode this ticket exists to prevent.

## Delegation Plan

Dogfooding the contract shipped today (`skills/execute-ticket/SKILL.md` §2.2).

- **Phase 1** — `Delegation: inline (single-file prose edit in an already-read file)`
- **Phase 2** — `Delegation: inline (single-file prose edit, well under 30 lines)`
- **Phase 3** — `Delegation: subagent — brief: draft the Step 5 lifecycle step +
  the genericized gate-class block from aurora's `.agents/gates.md:128-140`;
  return the two text blocks and nothing else, ≤40 lines`
- **Phase 4** — `Delegation: subagent — brief: implement the `ticket_dir` read in
  `shipyard.sh` learn + its failing-first bats cases; return files changed,
  commands run with exit codes, and the failing-then-passing test output, ≤40 lines`

Each phase records the matching `builder:` line in the Ledger.

## Ledger

### Phase 1 — `write-ticket`: name the birth folder

builder: inline (exception 1 — single-file prose edit in an already-read file,
as the Delegation Plan specified)

Step 0 now documents `lifecycle_dirs` alongside the existing dir keys, states
the folder-is-the-status mapping, and pins that **a new ticket is always born in
`ticket_dir`** — never written into archive/backlog, never moved by this skill.
Step 1 makes never-reuse explicit and adds never-**renumber** (a ticket keeps id
and filename for life; only its folder changes).

`tests/ticket-lifecycle.bats` created — 6 cases (4 contract, 2 guards).
**Shown failing first:** cases 1–4 `not ok` against pre-change `write-ticket`;
guards 5–6 pass pre-change, as guards must.

*Self-caught test defect:* case 4 first asserted the generic words
"unset|absent" + "flat", both of which already appear elsewhere in the file — it
passed pre-change and so could not fail on the defect. Narrowed to the specific
new clause (`absent .lifecycle_dirs`). Same class of finding as the delegation
work: a test that cannot fail is a finding, not a test.

Gate: `bats tests/` **319 passing, 0 failures** · `leak-check` clean (new test
file `git add -N`'d first) · `check-deck-fresh` in sync (byte-identical, L6).

Commit: `79b3d25`

### Phase 2 — `polish-ticket`: read the config, never move

builder: inline (exception 1 — single-file prose edit, as the Delegation Plan
specified)

`SKILL.md:27` no longer hardcodes `docs/tickets/<name>.md`: polish reads the
`[write_ticket]` dir keys (`ticket_dir` / `archive_dir` / `backlog_dir`), never
guesses a path, and hardens **in place**. Graduating is named as
`ticket-lifecycle.sh --graduate` (deterministic, `execute-ticket`'s final
commit); parking stays the owner's call alone. A misfiled ticket gets reported,
never silently relocated.

`tests/ticket-lifecycle.bats` +5 cases (4 contract, 1 guard). **Shown failing
first:** cases 7–10 `not ok` against pre-change `polish-ticket`; the
anti-cheating guard passes pre-change.

Gate: `bats tests/` **324 passing, 0 failures** · leak-check clean ·
deck-fresh in sync.

⚠ **Concurrent-agent note:** at 17:29:40, while this phase was being built,
another agent modified `install.sh`, `README.md`, `skills/install/SKILL.md` and
`tests/harness-install.bats` in this same working tree (a codex/hermes
`AGENTS.md` skill-bridge — unrelated to this ticket). Those files are NOT part
of this commit; `git add` was scoped to this phase's three files only. The 324
count includes their work, which is also green.

Commit: `bad5ac0`

### Phase 3 — `scripts/ticket-lifecycle.sh`: the deterministic engine

builder: subagent (1 agent) — the first phase in this session actually built by
delegation rather than under exception 4.

The engine that makes the lifecycle deterministic instead of advisory:
`--check` (exit 1 on drift — what CI and `--doctor` call), `--sort` (dry-run by
default) / `--sort --apply`, `--graduate <file>`, and **exit 3 as a deliberate
no-op** when `lifecycle_dirs` isn't set, so flat projects are untouched.
Freezer words are matched before complete words; an unparseable or absent
`Status:` falls to **pending** — a ticket is never guessed into `complete/`.

`tests/ticket-lifecycle-script.bats` — 14 cases, hermetic (fixture git repos in
`$BATS_TEST_TMPDIR`).

**Independently re-verified rather than trusted** (§2.5 — never trust a
subagent's green). Two levels:

1. *Behavior*, on a hand-built fixture outside the suite: `built + verified` →
   complete; `superseded by the built replacement` → **freezer**, not complete;
   no `Status:` line → stays pending; `--sort` dry-run left all four files in
   place; `--check` exited 1 and named both misfiled tickets.
2. *Test quality* — the agent's failing-first evidence was all exit 127
   ("command not found"), which only proves the file didn't exist yet. So the
   mapping was **mutation-tested** against three deliberate defects:

   | mutation | caught by |
   |---|---|
   | unparseable status defaults to `complete` | `not ok 3`, `not ok 5` |
   | freezer words never match (superseded→complete) | `not ok 3`, `not ok 6` |
   | `--sort` applies without `--apply` | `not ok 7` |

   Script restored byte-identical afterwards (`diff -q`), suite re-run green.

*Cosmetic, not fixed:* the `MISFILED:` line echoes the raw status with its
Markdown bullet artifacts (`status "** built + verified …"`). Harmless; noted
for a later pass rather than churned now.

Gate: `bats tests/` **338 passing, 0 failures** · `bash -n` OK · leak-check
clean (files `git add -N`'d first) · deck-fresh in sync.

Commit: `a207503`

### Phase 4 — `execute-ticket` calls the engine

builder: inline (exception 1 — single-file prose edit)

Step 5 — Finish now graduates the ticket by **running the engine**, not by hand:
`ticket-lifecycle.sh --graduate <ticket>`, staged **in the same commit that
lands the last verified phase** (a separate move-commit leaves a window where
the tree claims the work is unfinished). Only on full completion — deferred or
blocked phases leave the ticket in `pending/` with an honest Ledger note. An
autonomous run never writes to `freezer/`; that is the owner's call alone.
Flat projects are explicitly untouched (engine exits 3). Closes with
`--check` exiting 0, the same gate CI and `--doctor` run.

`tests/ticket-lifecycle.bats` +6 cases (5 contract, 1 guard). **Shown failing
first:** cases 12–16 `not ok` pre-change; the verify-before-commit guard passes
pre-change.

Gate: `bats tests/` **344 passing, 0 failures** · leak-check clean ·
deck-fresh in sync.

**Worktree note:** from this phase on, the build runs in
`.worktrees/ticket-lifecycle` (owner-approved) because another agent is editing
`install.sh` / `README.md` / `skills/install/SKILL.md` /
`tests/harness-install.bats` in the main checkout — the codex/hermes `AGENTS.md`
bridge. Their work was left untouched on `main`; a backup of their uncommitted
diff sits in this session's scratchpad. Per CLAUDE.md's worktree trap, `.agents/`
is gitignored and therefore **absent here** — the delegation-contract cases that
assert against it skip cleanly (built to do exactly that), and Phase 5's
`.agents/gates.md` edit must be made in the main checkout.

Commit: _(this commit)_

---

Run it with `execute-ticket`.

---

# SCOPE REVISION (owner decisions, 2026-07-27) — supersedes the plan above

The owner's direction: **deterministic where possible, on by default, and every
installed repo ends up with real ticket hygiene.** Four decisions, answered:

| # | Decision |
|---|---|
| D1 | **One vocabulary fleet-wide: `pending/` `complete/` `freezer/`.** Rename `backlog→pending`, `archive→complete` on bopthere, shredly, starbird. |
| D2 | **Auto-sort existing tickets by their `Status:` line**, dry-run first — but the *final* sort call on each repo is made by a **per-repo subagent (sonnet)** given the status-line reading as a recommendation. |
| D3 | **Enforcement: block in CI + `--doctor`, warn in pre-commit.** |
| D4 | **Keep existing filenames.** Only the folder changes. |

### What this changes about the original plan

The original ticket enforced the lifecycle with *prose only* — the reason
Phases 1–3 had no real tests. That is now the minority of the work. The core
becomes a **real script** that can be run, tested, and failed:

`scripts/ticket-lifecycle.sh` — the deterministic engine, with real bats cases:
- `--check` — every ticket's folder matches its `Status:`; **exit 1 on drift**
  (this is what CI and `--doctor` call);
- `--sort [--apply]` — `git mv` each ticket to the folder its status implies;
  **dry-run by default**, prints the full plan;
- `--graduate <file>` — move one finished ticket to `complete/`, for
  `execute-ticket` to call in the final phase's commit;
- exit `3` (deliberate no-op) when the project has no lifecycle configured, so
  flat projects are untouched.

`execute-ticket` no longer has to be *trusted* to move the file — it calls the
script, and `--check` catches it if it doesn't.

### Default ON — and the house-rule tension, resolved

The repo's config-gated-additivity rule says an unset key must mean exactly
today's behavior. The owner wants this **on by default**. Both hold, at
different layers:

- **Skills/script layer** — absent `lifecycle_dirs`, behavior is byte-identical
  to today. A project whose config nobody touches never changes. (Keeps the
  gate class honest, and keeps a stale checkout safe.)
- **Installer layer** — `install.sh` now writes `lifecycle_dirs = true`, creates
  the three folders, and offers migration. **On for every install and re-install**,
  which is how every fleet project actually gets it.

So "default off" survives only for a config nobody has run the installer against.

## Revised phases

Phase 1 is already built (`79b3d25`). Phases 2–8 below replace the original 2–4.

### Phase 2 — `polish-ticket`: read the config, never move (2 pts)
`Delegation: inline (single-file prose edit)`
Replace the hardcoded `docs/tickets/<name>.md` (`SKILL.md:27`); state that polish
hardens **in place** and never relocates. Content-contract cases.

### Phase 3 — `scripts/ticket-lifecycle.sh`: the deterministic engine (5 pts)
`Delegation: subagent — build the script + its bats suite to the spec above;
return files changed, commands run with exit codes, and the failing-then-passing
test output, ≤40 lines`
Status→folder mapping is the load-bearing detail: a `Status:` matching
built/complete/verified/shipped ⇒ `complete/`; parked/deferred/superseded/won't-do
⇒ `freezer/`; **anything else, including unparseable ⇒ `pending/`** (never guess
a ticket into `complete/`). Real failing-first bats cases against fixture repos.

### Phase 4 — `execute-ticket` calls the engine (2 pts)
`Delegation: inline (single-file prose edit)`
Step 5 — Finish gains: on full completion with `lifecycle_dirs` on, run
`ticket-lifecycle.sh --graduate <ticket>` and include the move **in the final
phase's commit**. Partial completion leaves it in `pending/`. An autonomous run
never writes to `freezer/`.

### Phase 5 — installer: default ON + the gate class (5 pts)
`Delegation: subagent — installer changes + doctor wiring + bats; return the
--dry-run diff, doctor output, and test results, ≤40 lines`
`install.sh` creates `pending/complete/freezer`, writes the four config keys plus
`lifecycle_dirs = true`, drops the lifecycle gate class into `.agents/gates.md`,
and wires `--doctor` to run `ticket-lifecycle.sh --check` as a **blocking** class.
Pre-commit hook warns (never blocks). CI gets a lifecycle job.

### Phase 6 — `shipyard learn` honors `ticket_dir` (2 pts)
`Delegation: inline (small bash change; shipyard.sh already has CFG_JSON at :46)`
Read the target repo's own `ticket_dir` (note: `learn` operates on `$dir`, not
always `$PROJECT_DIR`), fall back to `docs/tickets`. Real behavioral bats cases.

### Phase 7 — fleet migration, one subagent per repo (5 pts)
`Delegation: subagent PER REPO (sonnet) — 7 agents`
Per D1/D2/D4. Each agent gets one repo, runs `ticket-lifecycle.sh --sort`
(dry-run) for the status-line recommendation, makes the final call per ticket,
renames folders to the standard vocabulary, and commits on a branch. Repos:
aurora (rename none; add `lifecycle_dirs`), bopthere, shredly (62 flat + already
half-migrated), starbird, ice, caladan, 2pizzaclub (folders only, no tickets).
**No repo is pushed or merged without the owner's stamp** — each agent stops at
a branch and reports.

### Phase 8 — shipyard dogfoods it + full battery (2 pts)
`Delegation: inline`
shipyard adopts the layout for its own 11 tickets, reversing original O4 — a
harness that doesn't run its own hygiene rule has no business shipping it.
Full battery + CI green.

## Revised Definition of Done

- [ ] `ticket-lifecycle.sh --check` exits non-zero on a misfiled ticket, proven by test
- [ ] `--sort` is dry-run by default and never lands a ticket in `complete/` by guess
- [ ] A project with no lifecycle config is byte-for-byte unaffected (proven, not asserted)
- [ ] A fresh `install.sh` run yields the three folders, the config keys, and the gate class
- [ ] `--doctor` fails on lifecycle drift; pre-commit warns; CI has a lifecycle job
- [ ] All 7 fleet repos migrated on branches, one subagent each, filenames unchanged
- [ ] shipyard's own tickets are foldered
- [ ] `bats tests/`, leak-check, deck-fresh green; CI green on main
