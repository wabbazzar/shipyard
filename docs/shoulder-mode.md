# Shoulder mode

Shoulder mode is the release crew's second surface: a cold-context critic that
reads a dev session's diff while the code is still being written, and delivers
findings back into that live session as notes.

The first surface — a nightly re-run of an already-green test suite — measured
out at 871 runs, 0 regressions caught. The authoring session had already
optimized against that signal. A reviewer that never sees the author's
reasoning is a different signal.

Three constraints shape the design:

1. **It never sees the transcript.** Input is the diff, the changed-file list,
   the project's `.agents/release.md`, and the rubric. A critic that reads the
   author's reasoning inherits the author's goals and blind spots (*goal
   contamination*) and grades the intent instead of the diff.
2. **It never blocks the dev agent.** The only thing running inside the dev
   agent's tool loop is a hook that appends one line to a file and exits 0.
   The expensive work happens in a separate long-lived process.
3. **It never writes code.** It emits findings; the dev agent or the human
   decides what to do with them.

---

## The pipeline

```
 dev session (claude)
   │ Edit / Write / MultiEdit
   ▼
 PostToolUse hook ─────────► agents/release/critic-queue.sh
   (returns immediately)        appends "<file> <epoch>" to
                                <project>/tmp/critic-queue-<session_id>
                                always exit 0
                                          │
                     ┌────────────────────┘
                     ▼
 agents/release/critic-watch.sh   (long-lived; polls every 30s)
   fires when: queue idle ≥ 5 min  OR  ≥ 8 distinct files queued
     ├─ budget gate      today's release.critique tokens < budget_tokens_daily?
     ├─ snapshot queue   (entries added mid-run survive)
     ├─ build the diff   git diff <trunk> + --no-index hunks for untracked
     │                   queued files; skip entirely if the diff is empty
     ├─ build the prompt critic-role.md + .agents/release.md + files + diff
     ├─ claude -p --output-format json      ← the only model spend
     ├─ parse `SEVERITY|file|finding` lines + .usage token counts
     ├─ emit release.critique event (files/block/warn/note/tokens)
     └─ deliver via $CLAUDE_NOTE_CMD <session> <summary>
            exit 0    → consume the snapshot, clear the queue
            exit 2/3  → NOT delivered (ambiguous target / session at a
                        prompt): keep the queue, reuse the cached critique
            other     → retry 3 passes, then give up loudly with a
                        release.critique.delivery_failed event
```

An optional, **disarmed-by-default** `Stop` hook
(`agents/release/critic-stop-gate.sh`) can hold a session open while
`block` findings are unaddressed.

---

## Component 1 — `critic-queue.sh` (the hook)

A `PostToolUse` hook with matcher `Edit|Write|MultiEdit`. It runs inline in the
dev agent's tool loop, so it does no LLM work, no network, and no blocking
work, and it **always exits 0** — malformed stdin, unwritable queue dir, not a
git repo, anything.

- Reads the hook JSON from stdin; takes `.tool_input.file_path` and
  `.session_id` (fallback `default`).
- Project dir = `$CLAUDE_PROJECT_DIR`, fallback cwd.
- Appends `<file_path> <epoch>` to `<project>/tmp/critic-queue-<session_id>`,
  or `/tmp/shipyard-critic-<uid>/<project-basename>/` when the project has no
  `tmp/`.

Two enqueue-time filters, both added after real noise:

| Filter | Why |
|---|---|
| Absolute paths outside `$CLAUDE_PROJECT_DIR` are dropped | a session working across two checkouts would otherwise get the other repo's files graded against *this* project's conventions and trunk |
| `git check-ignore`-d paths are dropped | result JSONs and scratch files under `tmp/` are runtime artifacts, never release candidates; they produced whole critic runs whose only "change" was e.g. `tmp/medic-result.json` — tokens and a ping for zero signal |

`check-ignore` failing open (no git, not a repo) keeps the old behavior.

## Component 2 — `critic-watch.sh` (debounce + spawn + deliver)

```
critic-watch.sh --project <dir> [--session <id>] [--once]
```

`--once` runs a single evaluation pass and exits (tests, cron); the default is
a poll loop.

**Trigger (the debounce window).** Per queue file: fire when
`idle ≥ CRITIC_IDLE_SEC` **or** `distinct files ≥ CRITIC_BATCH_FILES`. Idle is
measured from the queue file's mtime, so it tracks the last edit, not the last
poll. A 20-file burst at batch size 8 costs at most two critiques.

**Budget gate — before any model spend.** Sums today's `tokens` from successful
`release.critique` events and from both malformed-response event types, then
compares the result against `[release] budget_tokens_daily` (default
1,000,000). A completed model invocation counts once even when its output is
rejected. Over cap, the queue is **deferred, not discarded** — the review
happens in the next budget window — and a `release.critique.skipped`
`reason=budget` event fires once per session per UTC day (a marker file dedupes
it; the gate itself is hit on every poll).

**Critique caching.** If a findings file exists and is newer than the queue,
the critique is reused instead of re-spending the model. Without this, a
`claude-note` exit 2/3 (which deliberately keeps the queue) would re-run the
whole critique on every 30-second poll.

**Snapshot.** The queue is copied to `critic-snapshot-<session>` before the
(minutes-long) `claude` run. Successful delivery and non-required terminal
outcomes consume only the exact byte prefix in that snapshot. Anything the hook
appended while the model was thinking stays queued for the next pass instead of
being deleted unreviewed; if the prefix itself changed, acknowledgement is
deferred and both queue and snapshot are kept.

**Diff assembly.** Scoped to the exact queued edit batch, not the whole
branch — pulling every historical branch hunk into each batch made
long-lived branches exceed both execve and model input limits and let
unrelated older work contaminate current feedback.

- Trunk resolved via `agents/lib/detect-trunk.sh`, falling back to `HEAD`.
- The changed-file list is exactly the queued paths (deduped, filtered to
  this project, gitignore-excluded) — not the trunk-vs-branch diff's file
  list.
- Each queued tracked path gets its own `git diff <trunk> -- <path>` hunk;
  results are concatenated into the diff body.
- Untracked queued files never appear in `git diff`, so their hunks are
  synthesized with `git diff --no-index -- /dev/null <file>`. A brand-new file
  reaches the critic as reviewable content, not just a filename.
- **Empty diff → skip**, drop the queue, emit
  `release.critique.skipped reason=empty_diff`. Spawning anyway yields only
  "the diff body was empty" notes (observed 4× on one project). Note this also
  skips edits that were committed *and* pushed to trunk before the idle window
  fired — those are post-release, and shoulder mode's contract is pre-release
  review of pending work.

**Prompt.** `critic-role.md` + the project extension `.agents/release.md` +
the changed-file list + the diff. Model is the `claude` default unless
`CRITIC_MODEL` is set. The project extension and diff sections are each
capped (`_bounded_prompt_section`, e.g. 16000 bytes for the extension) to
keep the prompt portable across every selectable harness — Hermes exposes
only an argv query flag. A truncated section ends with a
`[SHIPYARD: ... omitted N trailing bytes ...]` notice; `critic-role.md`
tells the model to use read-only repo tools to inspect omitted content
before finalizing findings.

**Parsing.** `claude -p --output-format json` returns one object; the reply is
`.result` and real usage is `.usage.input_tokens + .usage.output_tokens`.
Findings are the lines matching `^(block|warn|note)\|`; they are written to
`critic-findings-<session>` and counted into the event.

The generic parser stays fail-closed. Empty normalized text, a missing or
duplicate `TOKENS_HINT|<none>` sentinel, an invalid output line, or an
unnormalizable successful harness envelope is malformed and never creates a
valid-response marker or reaches finding delivery. Malformed retry state is
separate from spawn, specialist, and delivery state. Its generation hashes the
immutable queue snapshot plus the current required-feedback turn, so the same
generation receives at most three model calls. A changed snapshot or a later
required-feedback turn starts at attempt 1; a valid parsed response clears stale
malformed state for its generation.

Attempts 1 and 2 keep the queue and emit
`release.critique.malformed_response`. Attempt 3 emits only
`release.critique.malformed_response_exhausted`; subsequent polls make no model
call for that generation. In ordinary mode, terminal exhaustion consumes only
the exact reviewed prefix. With `require_feedback=true`, it preserves the queue
and writes terminal status `malformed_response_exhausted`: review is
unavailable, not passed. The Stop gate remains a hard blocker until the human
or authoring agent records that blocker, changes the reviewed work, or begins a
later required-feedback turn that can form a new generation.

For local diagnosis, `tmp/critic-malformed-diagnostic-<session>` is an atomic,
owner-only mode-0600 schema-v1 JSON file. It contains only `reason`, bounded
`sentinel_count`, `invalid_line_count`, `response_bytes`, `response_hash`,
`harness`, `tokens`, `attempt`, opaque `generation`, and `updated_at`; it never
stores response prose, prompts, diffs, filenames, paths, or findings. Existing
diagnostic and retry targets must be regular, singly linked, current-owner
private files: unsafe symlink, owner, mode, or link-count states are refused.

**Spawn failure** (bad model, oversized prompt, missing binary) retries for 3
passes, then gives up loudly with `release.critique.spawn_failed` and drops the
queue — a persistent failure must not retry silently forever.

**Delivery.** `$CLAUDE_NOTE_CMD <session> <summary>`, where the summary is the
counts plus the first 10 `block`/`warn` lines. There is no hardcoded delivery
path in this repo: unset `CLAUDE_NOTE_CMD` means log-and-skip. Exit codes:

| exit | meaning | queue |
|---|---|---|
| 0 | delivered | consumed |
| 2 | ambiguous target | **kept** — retryable session state, no attempt cap |
| 3 | session sitting at an interactive prompt | **kept** — same |
| other | the note command itself is broken | kept for 3 passes, then `release.critique.delivery_failed` + findings left on disk |

Exit 2/3 aren't critic failures; a note delivered into a permission
menu would be read as a menu choice.

## Component 3 — `critic-role.md` (the rubric)

The prompt states the input contract explicitly, including what it does *not*
receive and why. Output is machine-parseable, one finding per line:

```
SEVERITY|file|one-line finding
```

`SEVERITY` ∈ `block` / `warn` / `note`; `file` is repo-relative or `-` for
whole-diff findings; a clean diff emits zero finding lines. Ties break
downward — "a critic that cries block loses its audience."

- **block** — would break a release: correctness bug, security regression,
  forbidden-path touch, migration without a rollback, deleted test.
- **warn** — changed behavior without a test, scope creep, a new dependency, a
  suppression, missing error handling on a new boundary.
- **note** — style drift, doc gaps, TODO debt.

Rubric v1 grades: Goodhart check · test coverage · security boundaries ·
reversibility · blast radius · observability · suppressions.

**Conventions layer.** If the project's `.agents/release.md` has a
`## Conventions` block, the critic grades against those *stated* conventions
only — never generic taste — capped at `warn`/`note`. A convention miss is
never a `block` on its own.

## Component 4 — `critic-stop-gate.sh` (opt-in teeth)

A `Stop` hook that is **disarmed unless the session sets `CRITIC_BLOCK=1`**.
Armed, it reads the session's findings file and exits 2 (Claude Code: "don't
stop yet") with the unaddressed `block` lines on stderr. Crew agents' own
headless runs never set it, so they are unaffected.

---

## Knobs

| Knob | Where | Default |
|---|---|---|
| `CRITIC_IDLE_SEC` | env | 300 (5 min) |
| `CRITIC_BATCH_FILES` | env | 8 distinct files |
| `CRITIC_POLL_SEC` | env | 30 |
| `CRITIC_MODEL` | env | unset ⇒ `claude` default |
| `CLAUDE_NOTE_CMD` | env | unset ⇒ log-and-skip delivery |
| `CRITIC_BLOCK` | env, per session | unset ⇒ stop gate disarmed |
| `budget_tokens_daily` | `.agents/config.toml` `[release]` | 1,000,000 tokens/day |
| `hunk_safe_gates` | `.agents/config.toml` `[release]` | `false` — CHANGED FILES block is byte-identical to the raw changed list; `true` marks entries with no diff hunk `(no hunks)` so a file-conditional check can key on real hunks (see critic-role.md "Input contract") |
| conventions + project rubric | `<project>/.agents/release.md` | — |
| events dir | `QUARTET_EVENTS_DIR`, else `<project>/data/events` | — |

For opt-in rules memory, reviewer identity is receipt-bound. The unset Claude
path therefore invokes and records `sonnet` explicitly; non-Claude memory
review requires an explicit `CRITIC_MODEL`. This does not change the generic
critic's legacy unset-model invocation.

## Events

```
release.critique                 source=shoulder files= block= warn= note= tokens=
release.critique.malformed_response
                                  source=shoulder files= tokens= reason= attempt= generation=
release.critique.malformed_response_exhausted
                                  source=shoulder files= tokens= reason= attempt= generation=
release.critique.skipped         reason=budget|empty_diff
release.critique.spawn_failed    rc= attempts= files=
release.critique.delivery_failed rc= attempts=
```

Malformed events are content-safe and mutually exclusive per invocation: the
terminal third call is not also recorded as a nonterminal attempt. Fleet
inspection retains their reason, attempt, and generation evidence, counts each
event's file/token fields once, and treats both as critic failures. Counts and
token spend land in the event stream, so a critique that can't be delivered or
parsed is still on record, and the daily cap is computed from the crew's own
telemetry rather than a separate meter.

## Harness support

Capture, delivery, and the stop gate work whether the authoring session runs
**claude, codex, or hermes**; the critique spawn was already harness-agnostic
(`spawn_model`). Only the *capture hook* differs per harness, because each
reads its own payload — but all three normalize to the **same** queue file
(`<project>/tmp/critic-queue-<session>`, `"<file> <epoch>"` per line), so
`critic-watch.sh` drains them identically.

| harness | hook event | capture script | file path in payload | native config |
|---|---|---|---|---|
| claude | `PostToolUse` | `critic-queue.sh` | `.tool_input.file_path` | `.claude/settings.json` |
| codex  | `PostToolUse` | `critic-queue-codex.sh` | V4A patch in `.tool_input.command` (multi-file) | `~/.codex/config.toml` `[[hooks.PostToolUse]]` |
| hermes | `post_tool_call` | `critic-queue-hermes.sh` | `.tool_input.path` (+ V4A `.tool_input.patch`) | `~/.hermes/config.yaml` `hooks:` |

Delivery is the generic, shipped `agents/release/critic-note.sh` (`--harness
<h>`): it tries a configured session-injector (`$CRITIC_NOTE_DELIVER_CMD`, exit
code passed through), then a harness-native channel (hermes: `hermes send -t
$CRITIC_NOTE_TARGET`), then `$QUARTET_NOTIFY_CMD` as an owner alert, then
log-and-skip. The stop gate ships per harness too (`critic-stop-gate{,-codex,-hermes}.sh`),
disarmed unless `CRITIC_BLOCK=1`.

## Wiring it up

**Opt-in via the installer (recommended).** `install.sh --wire-shoulder
--project <dir>` (or set `[shoulder] auto_wire = true`) additively registers
the capture hook in the authoring harness's native config — the harness is
`[shoulder] harness` else `[harness].default` else `claude` — and writes
`<project>/.agents/shoulder.env` from the `[notify]` block so the watch service
gets `CLAUDE_NOTE_CMD` / `CRITIC_NOTE_*` without hand-wiring. **With the opt-in
unset, `install.sh` touches no harness config** — the installer still refuses to
own those files by default. `install.sh --doctor` reports wiring drift once a
project has opted in. Re-running is idempotent; an existing unrelated hook is
never clobbered (an existing hermes `hooks:` block is surfaced for a manual
merge rather than corrupted).

**Manual (claude shown; codex/hermes use the native configs in the table
above).** Merge a hook additively — other hooks must survive:

```json
{ "PostToolUse": [
    { "matcher": "Edit|Write|MultiEdit",
      "hooks": [ { "type": "command",
                   "command": "<shipyard>/agents/release/critic-queue.sh" } ] } ] }
```

Hooks load at **session start** — sessions already running when you add this
are not watched until they restart. Then keep `critic-watch.sh --project <dir>`
running (a long-lived user service works); source `.agents/shoulder.env` (or
give it `CLAUDE_NOTE_CMD` and, if events live elsewhere, `QUARTET_EVENTS_DIR`).

3. Optionally add the `Stop` hook for `critic-stop-gate.sh` — inert until a
   session exports `CRITIC_BLOCK=1`.

## Tests

`tests/shoulder-mode.bats` covers the pipeline end to end with a stubbed
`claude`: hook robustness (garbage stdin, no `file_path`, gitignored paths,
out-of-project absolutes), debounce arithmetic (a 20-file burst at batch 8
yields at most 2 critiques; an idle sub-batch queue still fires; a fresh
sub-threshold queue does not), the empty-diff skip, budget deferral and the
once-a-day skip event, findings parsing and token accounting from canned
output, every delivery exit-code path including the 3-strike give-ups, the
snapshot race (entries queued mid-run survive), and all three stop-gate states.
`tests/gap-fixes.bats` covers the exit-3-keeps-the-queue regression.
