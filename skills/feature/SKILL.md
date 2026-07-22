---
name: feature
roles: [design, human]
disposition: new
kind: frontdoor
description: >
  Front door for a new capability. Triggers on "add X", "I want …", "build a
  …", or "/feature <desc>". It does the clarify-and-set-a-DoD-first intake —
  surface assumptions and verify them one probe at a time, wait for the human
  to confirm the open ones, then lock a concrete Objective, a checklist
  Definition of Done, and Boundaries — and only then calls write-ticket with a
  feature scope (acceptance = the DoD is met). It STOPS at the human gate: the
  ticket is queued for a stamp unless the user explicitly says "and build it".
  It does NOT build the feature — that is execute-ticket, behind the gate.
  Callable headless by the design crew after an ask enters the loop, and
  interactively by a human operator — identical file, no forks.
---

# feature — clarify, set a Definition of Done, then write the ticket

An ask like "add search" is not yet buildable. The job here is to close the
gap between a one-line wish and a ticket someone could build unattended, and to
close it in the right order: **verify what you're assuming, agree on what
"done" means, and only then write the ticket.** A feature ticket whose
acceptance criteria were guessed is worse than no ticket — it launders a guess
into tracked work.

**You are the feature-shaped front of the loop.** A machine ask (a stamped
design proposal) or a human ask (`/feature`, "I want…", "build a…") both
converge on `write-ticket`; your job is the intent-specific intake that runs
*before* it — assumptions-and-verify, then a locked DoD — after which you hand
`write-ticket` a scope and step back. You establish **what "done" is**;
`write-ticket` writes the ticket; `polish-ticket` hardens it; `execute-ticket`
builds it. Keep those jobs distinct — **do not build the feature here.**

## Step 1 — Surface assumptions and verify (one probe per candidate)

Before you can say what "done" looks like, pin down what you're assuming. Draft
three-to-seven candidate assumptions from the real project context, spanning
three categories, then run **one targeted, side-effect-free check per
candidate** — a repo read, a config read, a read-only probe — not a sweep:

- **Technical** — runtime, data model, persistence, the module the feature
  touches, the transport. Canonical sources: package manifests, build/CI
  configs, and the actual source the feature lands in. Cite `path:line` or a
  named symbol.
- **Product** — who this serves and where the feature ends. Usually has no
  local source; it goes straight to Unverified. Don't fabricate confirmation.
- **Process** — who signs off, how the ask becomes tracked work, which house
  rules and DoD convention govern. Canonical sources: the project's
  `.agents/config.toml`, `CLAUDE.md`/`README.md`, the most recent ticket.

Probes must be side-effect-free: no writes, no mutations, no calls that bill or
page. If the only way to verify is to write, the assumption stays Unverified.
If a needed lookup (e.g. web search) is unavailable in the harness, mark it
Unverified with the reason — never guess a citation.

Emit the result **in chat** (not into the ticket — the ticket body is gated by
the confirmation below), under this shape:

```
ASSUMPTIONS I'M MAKING:

## Verified
- <category>: <fact> (<single-line citation: path:line | URL | command + one-line summary>)
- …

## Unverified
- <category>: <open item or the reason one check couldn't settle it>
- …
```

Each Verified bullet stays single-line with its citation. Verified is whatever
subset of the candidates passed its check — no floor, no cap; coverage is
across the three categories, not the two subsections. **Classifying a Technical
or Process candidate Unverified without recording the one check you attempted
is a refusal-worthy shortcut** (see Anti-patterns): attempt the check and cite
it; an attempt that came back ambiguous is fine, a skipped check is not.

**Then WAIT.** Surface the Unverified list and wait for the human to confirm or
correct it before you write any acceptance criteria. **Default to a structured
question prompt (AskUserQuestion or the harness equivalent) with concrete
options per item** — that is what gets answered; a wall of bullets often gets
skimmed. Plain-chat confirmation is acceptable only when the list is short and
every item is a true/false check rather than a choice. If Unverified is empty,
surface the Verified list with the **highest-stakes** item called out and ask
the human to confirm *that one specifically* — a vague "looks good" doesn't
count when they may not have read the list.

Keep this proportionate: verify only what genuinely changes the build. A clear,
low-stakes request does **not** earn a seven-item interrogation — over-asking a
clear ask is as much a failure as under-verifying a load-bearing one.

## Step 2 — Lock the Definition of Done (a checklist, using the project's convention)

Only once the Unverified list is signed off (or the highest-stakes Verified
item confirmed) do you write acceptance. Settle three things, all concrete:

- **Objective — concrete, not vague.** "It should be fast" is not an objective;
  "returns within 200ms at p99 for payloads under 1KB" is. Every user-visible
  outcome you name must be precise enough that a test could be derived from it.
- **Acceptance Criteria / Definition of Done — a checklist.** *Without a
  checklist, "done" is opinion.* Each item is an observable, verifiable outcome,
  not an aspiration. **Use the project's existing DoD convention — do not
  reinvent one**; read it from the project's config/gate file/most-recent ticket
  (the same sources `write-ticket` reads) and mirror its shape.
- **Boundaries — `always` / `ask-first` / `never`, ≥1 entry under each, and at
  least one *structural* entry under `never`** (no new top-level dependency, no
  new module boundary) so the build can't sprawl into hypothetical futures.

This is the whole of your judgment surface. You do not phase the work, assemble
gate commands, or read every touched file to `path:line` — that is
`write-ticket`'s interrogation and `polish-ticket`'s hardening. You produce a
verified assumption set + a concrete Objective, DoD checklist, and Boundaries.

**Out of scope for v1 — aesthetic/design-readiness review.** For a UI-shaped
feature, checking for a grounded aesthetic reference and running a design review
before writing design-intent acceptance criteria (new-spec's ui-shaped step 4d)
is deliberately **not** done here. Note the feature is UI-shaped so a human can
run that pass separately; do not attempt it inline.

## Step 3 — Hand off to write-ticket with a feature scope

Call `write-ticket` with **type `feature`** and the scope you just locked: the
confirmed assumptions, the concrete Objective, the DoD checklist, and the
Boundaries. Its acceptance = **the DoD is met.** `write-ticket` does the ticket
interrogation (conventions, next id, real code to `path:line`, phased plan) and
emits the ticket file; it will not repeat the clarify step you already did —
take care to pass the scope so it doesn't.

## Step 4 — Stop at the human gate

`/feature` **writes and routes** a ticket; it does not build the feature. After
`write-ticket` emits the draft, run it through `polish-ticket` if that is the
project's flow, then **STOP** — the ticket is queued/surfaced for a stamp,
exactly as a stamped design proposal would be. Do **not** proceed to
`execute-ticket`. The one exception: the user explicitly said **"and build
it"** in the same breath — only then does the build run, and it runs through
`execute-ticket`, not by you editing app code here.

## Adaptation Contract

- **Parameter surface** (what install/config supplies, so this skill stays
  generic): everything `write-ticket` reads from `<project>/.agents/config.toml`
  and the project's gate file — context files, ticket dir, type enum, point
  scale, house rules — **plus the project's Definition-of-Done convention** (its
  DoD/acceptance-checklist shape and its Boundaries convention), read from the
  same config / gate file / most-recent ticket rather than baked here. This
  skill inherits write-ticket's parameter surface wholesale; it adds no config
  keys of its own.
- **Learning surface** (where lessons accumulate): the project's own DoD and
  Boundaries conventions. When a project sharpens how it defines "done" (a new
  acceptance shape, a new mandatory boundary), that lands in its config /
  most-recent ticket and every future `/feature` intake — human- or
  agent-driven — inherits it. A portable lesson (a clarify step every project
  should run) instead becomes an edit to the Procedure here, shipped as a core
  PR. This file names no project.

## Anti-patterns to refuse

- **A vague Objective.** "It should be fast" / "make it better" is not an
  objective. Sharpen it to a testable outcome before writing acceptance.
- **Empty Boundaries.** All three subsections (`always` / `ask-first` /
  `never`) need at least one entry, and `never` needs at least one *structural*
  entry. A feature with no boundaries sprawls.
- **No Acceptance Criteria.** "It works" is not acceptance. Every DoD item is an
  observable check drawn from the project's own DoD convention.
- **Writing acceptance before the Unverified list is confirmed.** The assumption
  probe and the human sign-off gate the DoD, even when the original ask sounded
  definitive. Scaffold nothing into the ticket until the open items are settled.
- **Unverified without a recorded check.** Marking a Technical or Process
  candidate Unverified without citing the one read/probe you attempted is a tax
  on the user's time — attempt and cite the check first.
- **Over-asking a clear request.** The clarify step is for what genuinely
  changes the build. Interrogating a low-stakes, unambiguous ask is as much a
  failure as guessing a load-bearing one.
- **Reinventing the Definition of Done.** Use the project's existing DoD
  convention; do not invent a parallel acceptance shape.
- **Doing new-spec's design-readiness pass.** Aesthetic reference + design
  review before writing UI acceptance criteria is out of scope for v1 — note the
  surface is UI-shaped, don't run it inline.
- **Building the feature.** Editing app code, running the change, implementing
  it — that's `execute-ticket`, behind the human gate. A `/feature` slice that
  starts editing app code has overreached; it writes and routes a ticket and
  stops.
