---
name: bugfix
roles: [design, human]
disposition: new
kind: frontdoor
description: >
  Turn a bug report into a routed ticket — reproduce-and-root-cause FIRST, then
  hand a bug scope to write-ticket. Triggers on "fix bug", "X is broken",
  "diagnose this regression", "/bugfix <desc>". Before any ticket exists it captures
  a reproduction (failing test, reliable manual steps, or an error/stack/log
  signature), pins the violated observable contract, falsifies rival causes with
  evidence, and names the coverage gap that let the bug through. It then calls
  write-ticket with a bug scope whose acceptance is "the captured repro passes
  AND the named coverage gap is closed," runs polish-ticket, and STOPS at the
  human gate (ticket queued for a stamp) unless the user explicitly says "and
  build it." It WRITES AND ROUTES a ticket; it does NOT fix the bug and does NOT
  commit the failing test — that is execute-ticket, behind the human gate.
  Callable headless by the design crew and interactively by a human — identical
  file, no forks.
---

# bug — turn a defect report into a routed, reproduced ticket

A fix written before a reproduction is a guess. This skill is the bug-shaped
front door to the ticket pipeline: it does the intent-specific intake that
`write-ticket` does not — **reproduce first, root-cause with evidence, name the
coverage gap** — and only then converts what it learned into a bug scope that
`write-ticket` accepts. It establishes **that the bug is real and where it lives**;
`write-ticket` establishes **what and why** as a ticket; `polish-ticket` hardens
**how to build it safely**; `execute-ticket` builds it (behind the human gate).
Keep those jobs distinct: **do not fix the bug here, and do not commit the
failing test here.** The reproduction you capture travels *in* the ticket;
`execute-ticket` commits the failing test at build time, where it becomes the
permanent regression test.

**You are the front of the loop for bugs.** A machine ask (a medic/build
incident that names a defect) or a human ask (`/bugfix <desc>`, "X is broken") both
converge here. You do the reproduce-first intake, then call `write-ticket` with a
scope — you never open a ticket that isn't backed by a reproduction.

## Procedure

### 1 — Reproduce first (no reproduction = no ticket)

Do not write a ticket until you have **one** of:
- a **failing test** that exercises the defect,
- **manual reproduction steps** that fail reliably (exact commands, inputs,
  environment, and the observed vs expected result), or
- a **captured error / stack trace / log signature** from the real system.

"No reproduction = no fix; you might be fixing the wrong thing." If you cannot
produce any of the three, the outcome is **not** a ticket — it is a
"needs-more-information" report that documents exactly what you tried (version,
data, environment) and what you observed. Do not close as "not reproducible"
without that record.

### 2 — Pin the violated observable contract (the repro must fail *because of* the bug)

The reproduction pins the **observable contract being violated** — a returned
value, a state change, an emitted event, an HTTP response, a rendered result —
**not the implementation**. Refuse:
- **Mock-shape assertions** (`expect(mock).toHaveBeenCalledWith(...)`) when the
  real contract is a value or state change. Test the contract, not the wiring.
- **A repro that passes for the wrong reason.** Run it against the *unfixed*
  code and confirm it fails *because of* the bug, not because the setup is
  wrong. A repro that can't fail on the real defect is not a reproduction.

### 3 — Falsify rival causes (Expected / Actual / Verdict)

Before asserting a root cause, name **2–3 plausible causes** — not just the
first one. For each, write down what you'd observe *if* that cause were true
(**Expected**), what a probe — a log, a breakpoint, a one-off experiment —
actually shows (**Actual**), and whether that rules the cause in or out
(**Verdict**). Example:
- *Cause A: input arrives unsorted.* Expected: log shows out-of-order keys.
  Actual: keys are sorted. **Verdict: ruled out.**
- *Cause B: cache returns a stale entry.* Expected: second call skips the loader.
  Actual: loader never runs on the repro. **Verdict: ruled in.**

Fixating on the first plausible cause is how you fix the wrong thing. **One
survivor supported by the evidence** becomes the root cause you carry into the
ticket.

### 4 — Root cause (four one-line answers, carry them into the ticket)

Write down a one-line answer to each — these become the ticket's Problem /
Background:
- **Where is the defect actually?** In the called function, the caller, their
  shared assumption, or upstream of both? A null that crashes in `parse()` may
  originate in the loader that should never have produced it.
- **When did it start?** `git log` / `git blame` the affected lines. For a
  regression the breaking commit often tells you why; even otherwise the
  surrounding commit messages surface original intent.
- **Could the same class exist elsewhere?** Grep for the same pattern / same
  call sites / same assumption. If yes, decide whether scope widens or you name
  an explicit non-goal ("fix here only") and file follow-ups.
- **Why wasn't it caught?** Name the **specific coverage gap** — an untested
  branch, a contract no test pinned, an input class no fixture covered. The
  ticket's acceptance closes *that* gap, not just the one input you observed.

### 5 — Scope to the minimum diff (root, not symptom)

Frame the fix as the **smallest change that turns the reproduction green** and
addresses what step 4 identified — not the symptom. Note (as an Out-of-scope
line for the ticket) any adjacent issues, and flag symptom-only shapes to keep
out of scope: catch-all handlers that swallow the error, defensive checks at
every call site when the invariant belongs upstream, retries around
nondeterminism, or a feature flag that hides the broken path. If a candidate fix
would leave the reproduction from step 1 still failing — or would let it pass
without addressing the root cause — it is the wrong scope.

### 6 — Hand off to write-ticket with a BUG scope

Call **`write-ticket`** with a scope of type `bug`. `write-ticket` does the
generic ticket work (reads the project's `[write_ticket]` config and prior
tickets, resolves the id, emits the sections); you supply the bug-specific
payload it should not have to re-derive:
- **The reproduction artifact** — the failing test / reliable steps / captured
  signature from step 1 — to live in the ticket's Problem/Background as the
  acceptance anchor. (It travels *in* the ticket; you do **not** commit it.)
- **The root-cause findings** from step 4 (where / when / elsewhere / why-missed).
- **Acceptance criteria** = the captured reproduction now passes **AND** the
  named coverage gap is closed (the regression test the builder will add pins
  the missing invariant, not just the one observed input).
- **The minimum-diff scope + out-of-scope** notes from step 5.

Because you already did the reproduce-first intake, `write-ticket` must **not**
repeat it — it takes your scope as given. After it emits the draft, run
**`polish-ticket`** to harden the verification surface and phasing.

### 7 — Stop at the human gate (do NOT auto-build)

`/bugfix` runs **intake → write-ticket → polish-ticket and STOPS.** The polished
ticket is queued/surfaced for a human stamp, exactly as a stamped design
proposal would be. **Unless the user explicitly said "and build it,"** do not
call `execute-ticket`, do not edit app code, do not commit the failing test.
Report: the reproduction you captured, the root cause, the ticket path, and that
it is queued for a stamp.

## Adaptation Contract

- **Parameter surface** (what install/config supplies, so this skill stays
  generic): `/bugfix` owns no project specifics of its own — it **inherits
  `write-ticket`'s configuration** (the `[write_ticket]` block in
  `<project>/.agents/config.toml`: context files, ticket dir + optional
  backlog/archive split, type enum, point scale + per-phase cap, commit scopes,
  house rules) plus the **project's test commands from its gate file**
  (`<project>/.agents/gates.md` — the commands the captured reproduction is
  expressed in and that the regression test must run under). None of these are
  baked here; the reproduce-first *discipline* is universal, the *commands* are
  read from the project.
- **Learning surface** (where lessons accumulate): the project's Traps /
  coverage-gap history in `.agents/gates.md`. Each root cause's "why wasn't it
  caught" answer (step 4) is a coverage gap; as those accrete in the gate file's
  Traps appendix, future `/bugfix` runs consult them to falsify causes faster and
  to recognize a recurring class. A portable lesson (a reproduce-first step every
  project should take) instead becomes an edit to the Procedure here, shipped as
  a core PR.

## Anti-patterns to refuse

- **Fixing forward without a reproduction.** The obvious fix is wrong about a
  third of the time, and you can't tell which third until the reproduction fails
  red first. No ticket before step 1 produces a real repro.
- **Adjusting the spec or the test to match the buggy behavior.** If the spec
  and the observed behavior disagree, one of them is wrong — surface it in the
  ticket, don't paper over it by weakening the contract the repro pins.
- **Closing as "not reproducible" without trying.** Document what was tried, on
  what version, with what data, before giving up. "Couldn't reproduce on my
  machine" is a hypothesis to test, not a closing condition.
- **Overreaching into the fix.** Editing app code, running the fix, or
  committing the failing test — that's `execute-ticket`, behind the human gate.
  A `/bugfix` slice that starts editing application code has overreached; `/bugfix`
  writes and routes a ticket, it does not build one.
- **Baking a project's specifics into this file.** Ticket dir, type enum, test
  commands, scopes — all inherited from `write-ticket`'s config and the gate
  file. This file ships in a public repo; it names no project.
