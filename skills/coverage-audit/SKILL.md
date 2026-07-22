---
name: coverage-audit
description: >
  Audit a project's automated coverage for gaps, using its Claude Code session
  transcripts as ground truth. Use when the user asks "is the release critic
  actually doing useful checks", "what is coverage missing", "coverage-audit
  <project>", "find bugs the tests didn't catch", "what would catch the bugs
  the user keeps reporting", or wants to tune the crew (release / build / on-call
  / docs) for a project. Reads session transcripts under
  ~/.claude/projects/<encoded-project-path>/, finds user-reported bugs the test
  suite missed, categorizes them, and triages each fix as project-specific
  (.agents/<role>.md), generic (core agents/<role>/role.md), or install-time
  configurable. The triage taxonomy IS the adaptation router. Callable headless
  (the design crew mines it for proposals; the release critic mines it for
  rubric lines) and interactively by a human — identical file, no forks.
---

# coverage-audit

The crew (release critic, build, on-call, docs) is only as useful as its
instruments. Hook-mode runs that report 0 catches across hundreds of pushes can
mean either "trunk is genuinely stable" OR "the checks are watching what doesn't
break while real bugs live somewhere they don't see." This skill resolves that
ambiguity using the user's Claude Code session history as ground truth — every
time the user pointed out a bug, the test suite had missed it. Surface those,
categorize, and recommend specific enhancements.

> **Role IDs.** This skill speaks in canonical role IDs. Legacy names map:
> `guardian → release` (the release-readiness critic), `augur → build`,
> `medic → on-call`, `scribe → docs`. A project's per-role prompt file is
> `<project>/.agents/<role>.md`; the shared core prompt is
> `agents/<role>/role.md` in the harness repo.

## When to invoke

The trigger is one of:
- "coverage-audit <project>" / "audit the release critic on <project>" / equiv.
- "is the critic doing useful checks" / "what is coverage missing"
- "find bugs the tests didn't catch in the last N days"
- "what should we add to catch X" (where X is a recurring class)
- "before installing the crew on <new project>, what should we configure"

If unsure whether this skill applies, ask: "do you want me to read the
session transcripts and find bugs that slipped past the test suite, or
something else?"

## Inputs

Required:
- **project_name / project_path** — the project's directory. The session dir is
  Claude Code's encoding of that absolute path: every `/` becomes `-`. For a
  project at `/home/user/code/myproj` the session dir is
  `~/.claude/projects/-home-user-code-myproj/`. Build the path from the
  project's real absolute path — don't hardcode a slug.

Optional:
- **time_window_days** — default 30. Older sessions on disk are skipped.
- **sample_size** — default 200 sessions (most-recent by mtime). Full read
  of all sessions burns token budget for marginal returns.
- **force_full_scan** — default false. If true, walk every session in
  the time window. Use only when sample-based audit found nothing.

## Methodology

### 1. Confirm the data is there

```bash
SLUG="$(printf '%s' "$PROJECT_ABS_PATH" | sed 's#/#-#g')"
SESSION_DIR="$HOME/.claude/projects/$SLUG"
ls "$SESSION_DIR" | head -3
ls "$SESSION_DIR"/*.jsonl 2>/dev/null | wc -l
```

If the dir is empty or doesn't exist, stop and report. Either the
project path is wrong or no sessions have been recorded.

### 2. Sample sessions

Pick the N most-recent .jsonl files by mtime. Each file is one Claude
Code session. JSONL schema:

```json
{"type":"user|assistant","ts":"ISO-8601","message":{"role":"user|assistant","content":"..."}}
```

`content` is sometimes a string, sometimes an array of `{type:"text", text:"..."}`
blocks. Filter to `type:"user"` and `message.role:"user"` to isolate
human-typed turns (vs agent-spawned subagent inputs).

### 3. Grep for user-bug-report patterns

Look for user messages matching any of these patterns (case-insensitive):

| Pattern | What it indicates |
|---|---|
| `(this\|it\|.*) is broken` / `doesn't work` / `still not working` | first-report bug |
| `you said .*done.*but` / `you missed` / `didn't fix` | post-completion-claim correction |
| `regression` / `used to work` / `worked before` | something that was working broke |
| `[Tt]ests passed but` | the test suite signed off, user disagrees |
| `this continues to happen` / `over and over` / `recurring` | flagged repeat — high signal |
| `fyi` / `just so you know` / `noting that` | proactive feedback |
| explicit error reports: `error:` / `cannot` / `fails to` / `404` / `500` | runtime failures |
| mobile/safari/phone-specific complaints | platform-specific |

For each match, capture:
1. **Verbatim complaint** (≤200 chars)
2. **Context** — the previous 1–2 user/assistant turns (what was being
   built / what was claimed)
3. **Bug category** — see classification rubric below
4. **Triage answer** — see triage rubric below

### 4. Classification rubric

Bucket each bug into ONE of these. Multiple buckets = pick the most
specific.

| Category | Examples | Why current automated coverage misses it |
|---|---|---|
| **UI/visual** | clipped modal, can't scroll to last item, button covered | jsdom has no layout — needs a real browser |
| **Mobile-Safari-only** | bottom-nav overlap, dvh, safe-area, momentum scroll | doesn't reproduce in jsdom |
| **Mobile-specific (other)** | viewport, touch handlers, PWA install | needs real-device or emulated viewport |
| **Sync / cross-user** | A edits, B sees stale; share doesn't propagate | DB audit checks shape, not propagation |
| **Chat/tool routing** | agent picks wrong tool, acts on wrong entity | routing eval too slow to run per-push |
| **State/lifecycle** | cache stale, back-button navigation | needs a real app-flow replay |
| **Auth / session bootstrap** | logged in but data missing, guest leak | needs live session replay |
| **Schema / migration** | migration breaks existing data | sometimes caught by tests, often not |
| **Performance** | slow load, slow turn, memory leak | no perf benchmarks in suite |
| **Other** | doesn't fit | flag for human review |

Also explicitly check `<project>/data/fyi-requests.jsonl` if it exists —
those are explicit user-feedback entries to the build crew, the highest-signal
class.

### 5. Triage rubric — where does the fix live? (this IS the adaptation router)

Every miss routes to exactly one layer. The three buckets below ARE the
adaptation router named in `docs/ADAPTING.md` — project-specific taste to a
per-role file, portable doctrine to a core PR, a recurring question to the
installer interview. Classify each recommendation:

#### A. **Project-specific** (`<project>/.agents/<role>.md`)

The check or rule is meaningful only for THIS project's structure /
domain. Example: "tool-routing check for a project that has a chat agent;
a project without one has nothing to route." → goes in
`<project>/.agents/release.md`.

Other examples:
- Specific table-name DB integrity assertions (schema-coupled invariants)
- Tool-name-specific routing regressions (specific tool ID checks)
- Project-specific UI conventions (button-shape rules)

#### B. **Generic** (`agents/<role>/role.md` or `agents/<role>/runner.sh`)

The check applies to ANY project that meets a criterion. Example: "every
PWA project benefits from a service-worker precache integrity check" → goes
in `agents/release/role.md` as a conditional, gated by `[release].is_pwa =
true` in config.toml. A generic recommendation ships as a **core PR** —
leak-checked, fleet-live on merge.

Other examples:
- Cross-user data isolation pattern (any project with multiple users)
- Service-worker precache integrity (any PWA)
- Browser smoke for any project with routed pages
- "Page mounts without console errors" (any web app)

When the recommendation is generic, also specify what config flag
gates it (so projects without that surface don't run it):
`[release].browser_smoke.routes = ["/live", "/schedule"]`,
`[release].is_pwa = true`, `[release].chat_eval_smoke.ids = [...]`.

#### C. **Install-time question**

The check is generic-with-flag, but the flag's value depends on a
project-specific answer the install needs. Add the question to the
installer interview so it surfaces before the install commits a config.

Examples:
- "Does this project have a chat/tool surface? → if yes, add a routing eval
  smoke + nightly battery"
- "Is this a PWA? → if yes, add the sw-precache check"
- "Are there multi-user data flows (sharing, comments, follows)? → if
  yes, add a cross-user contamination audit"
- "What's the UI route prefix for the most-touched user-facing pages?
  → that's the path-gate for browser smoke"
- "Is there a daily DB integrity invariant (e.g., 'no orphan rows in X
  table')? → write it as a SQL check in `.agents/release.md`"
- **"Does the project have `.claude/agents/` checked in? → if yes, list
  the subagents and tell the build crew when to delegate to which one.**
  When build creates its worktree off origin/trunk, those subagents come
  along automatically (they're git-tracked) and Claude Code auto-discovers
  them from cwd. Without explicit delegation guidance in
  `<project>/.agents/build.md`, build tends to write code inline rather
  than spawning the project's own specialist. Bump `[build].budget_incident`
  (and `[build].budget`) to absorb the subagent token cost."

When the installer interview hits this question, the inspection step is:

```bash
ls "$PROJECT_DIR"/.claude/agents/*.md 2>/dev/null
```

For each agent file found, read its `name:` and `description:` front-
matter. Generate a "Delegate to in-repo specialists" table in the new
project's `.agents/build.md` mapping `When → Spawn`.

### 6. Output template

Produce a single markdown report with these sections, in order:

```markdown
## Audit summary

- Sessions opened: N (of M in time window)
- Distinct user-reported incidents: K
- Explicit /fyi entries: J
- Time window: <start> to <end>

## Top bug categories

| Category | Count | Representative example |
|---|---|---|
| ... | ... | "...verbatim user quote (≤200 chars)..." (session-id <date>) |

## Why current coverage misses these

A 2-3 sentence diagnosis of the gap between what the checks look at and what
actually breaks. Reference the specific steps they DO cover.

## Recommended enhancements

For each enhancement, output:
**N. <short name>**
- **Triage**: project-specific (.agents/<role>.md) | generic (agents/<role>/role.md) | install-time prompt
- **What it catches**: 1-line + cite incident count from this audit
- **How to wire it**: concrete file path and check shape
- **Config gate** (if generic): the toml flag that enables it
- **Cost**: rough wall-clock and per-run token estimate

## Install-time questions to add

Bullet list of questions the installer interview should ask BEFORE
dropping `<project>/.agents/` files. Each maps to a config.toml flag
or a `.agents/<role>.md` section.

## Caveats

- Sample size and any selection bias
- Whether the audit relied on full content or grep/sample
- Anything the audit could NOT determine from session text alone
```

## Constraints / honesty rules

- **Never invent bugs.** If the grep finds nothing or only first-reports
  (no test-suite-missed pattern), say so. The output "coverage is
  appropriately scoped, no enhancements needed" is a valid answer.
- **Cite the source.** Every "incident count" must be backed by a
  session id (or fyi entry id) you actually saw. Padding numbers
  destroys trust.
- **Triage is the value-add.** Recommending generic checks is easy;
  the user's question is "what belongs in MY project vs the core framework
  vs the installer interview" — answer that explicitly for every rec.
- **Cap at 5 recommendations.** More than that and the user can't act
  on them. Rank by "incident-count-weighted ROI" — a check catching
  6 incidents beats one catching 1, even if the latter is fancier.
- **Stay under 500 words in the report body.** This is a triage
  document, not a textbook.

## Two consumers, one skill

The audit feeds both loops, symmetrically:
- **Design (proposals):** the categorized missed-bug classes become feature/
  fix proposals — recurring pain becomes design signal, not a one-off patch.
- **Release (rubric):** those same classes are exactly what the
  release-readiness rubric in `.agents/release.md` should check for on this
  project. A missed class becomes a new rubric line.

## Adaptation Contract

- **Parameter surface** (what install configures): the project's absolute path
  (→ the session-dir slug), the role names in play (theme/role IDs), the
  `.agents/` file paths this skill writes recommendations toward, the
  `fyi-requests.jsonl` location.
- **Learning surface** (where lessons accumulate): the triage output itself —
  project-specific findings land in `<project>/.agents/<role>.md`, generic
  findings become core `agents/<role>/role.md` PRs, and recurring questions
  become new lines in the installer interview. The taxonomy in §5 is the
  router that decides which.

## Common mistakes to avoid

- **Confusing first-report with completion-claim correction.** Both are
  signal, but the latter is stronger (means the agent said "done" before
  verifying). Note which is which in the representative examples.
- **Recommending a browser smoke globally without checking if the project
  actually has a UI.** A pure-API service has nothing to render.
- **Recommending project-specific fixes generically.** Triage matters — a
  routing check belongs only where a routing surface exists.
- **Skipping the install-time questions.** The user asked for these
  explicitly — they want the analysis to inform future installs.
- **Burning your token budget on full reads.** 200 sessions sampled is
  almost always enough. Read full content only on the matching turns.
