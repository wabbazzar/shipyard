# Harness-agnostic shoulder mode — codex + hermes capture, teeth, and installable delivery

- **Created:** 2026-07-24
- **Owner:** wabbazzar
- **Status:** Polished — ready for `execute-ticket`; queued for a human stamp (not built)
- **Type:** feature
- **Estimated Points:** 20 (P0 2 · P1 5 · P2 3 · P3 5 · P4 3 · P5 2)
- **Refs:** `.agents/gates.md` (gate classes + Traps), `docs/shoulder-mode.md`
  (the current design + its **install-ownership constraint**), `README.md`
  shoulder-mode + per-role harness sections.

> Build with `execute-ticket`. Orchestrate: delegate the per-harness parse work
> to subagents with tight briefs, re-verify every gate personally. **Anti-cheating
> brief (verbatim):** Converge honestly or report the precise blocker with the
> actual evidence — NEVER fake green, weaken a check, or hand-wave "should work".
> Run the real command, read the real file, fire the real hook, and report exact
> output (exit codes, JSONL lines, queue-file contents), not adjectives.

## Goal

Make shoulder mode's **authoring-session machinery** — edit **capture** → cold
**critique** → **delivery** back into the live session → optional blocking
**stop gate** — work identically whether the human's authoring session runs
`claude`, `codex`, or `hermes`, and make **delivery installable** so no operator
hand-wires a note command.

Today exactly one of the four parts is harness-agnostic: the critique **spawn**
(`agents/release/critic-watch.sh:362` → `spawn_model --harness
${CRITIC_HARNESS:-claude}`; dispatcher `agents/lib/spawn.sh:100-102`). The other
three are Claude-Code-only (capture: `critic-queue.sh:5`; teeth:
`critic-stop-gate.sh`; delivery: `critic-watch.sh:168`, unset ⇒ log-and-skip at
`critic-watch.sh:152-156`).

**Config-gated additivity (house rule):** with the new opt-in unset, nothing
changes — no harness config is touched, `$CLAUDE_NOTE_CMD` unset still
log-and-skips, the stop gate stays disarmed, and a claude-only install is
byte-identical to today. Every new behavior lands with a bats case shown
**failing against pre-change code first**.

## Context & pointers (read before building)

- **Current design + the constraint that shapes this ticket:**
  `docs/shoulder-mode.md`. Note §"Wiring it up" (line ~226): *"Shoulder mode is
  wired per project, not by `install.sh` (it touches `.claude/settings.json`,
  which the installer refuses to own)."* **This ticket adds an opt-in that lets
  install do the wiring; it must NOT change the default of not touching those
  files** (see Decisions D0).
- **Capture (claude, the pattern to mirror):** `agents/release/critic-queue.sh`
  — reads Claude Code PostToolUse hook JSON from stdin (`:5`), resolves session
  id (`:26`, fallback `default`), appends `"<file_path> <epoch>"` to
  `<project>/tmp/critic-queue-<session_id>` (`:57`). Matcher `Edit|Write|MultiEdit`.
- **Queue drain (must stay unchanged — boundary):** `critic-watch.sh:416-426`
  globs `critic-queue-*` and derives session from the suffix. Any new capture
  hook MUST write the **same filename + line format** so the watcher is untouched.
- **Delivery contract (must be honored exactly):** `critic-watch.sh:152-197` —
  exit `0` delivered/clear, `2|3` keep queue + retry (no cap), other retry ×3
  then `release.critique.delivery_failed`. Table also in `docs/shoulder-mode.md`.
- **Teeth (claude):** `critic-stop-gate.sh` — Stop hook, disarmed unless
  `CRITIC_BLOCK=1`; crew headless runs never arm it.
- **NOT capture — do not conflate:** `install.sh:720-752` drops a skill-bridge
  `AGENTS.md` so codex/hermes **headless crew runs** discover `.claude/skills`.
  Unrelated to authoring-session capture.
- **Existing tests to extend:** `tests/shoulder-mode.bats` (full pipeline with a
  stubbed `claude`: hook robustness, debounce, empty-diff skip, budget, every
  delivery exit path, all three stop-gate states), `tests/gap-fixes.bats`
  (exit-3-keeps-queue). Helpers: `make_stub` / `make_fixture_project` /
  `run_runner` in `tests/helpers.bash`.

## Discovery baseline (captured 2026-07-24 — re-verify if stale)

Toolchain verified on this box during polish:
- `bats 1.10.0` (`/usr/bin/bats`); `codex-cli 0.145.0`; `Hermes Agent v0.18.0`.
- **hermes** event name `post_tool_call` is valid: `hermes hooks test
  post_tool_call --for-tool Edit` → *"No shell hooks configured for event:
  post_tool_call"* (mechanism present; nothing wired yet). Hooks are declared in
  `~/.hermes/config.yaml`; consent allowlist `~/.hermes/shell-hooks-allowlist.json`;
  managed by `hermes hooks {list,test,revoke,doctor}` (note: **no `add`** — hooks
  are added by editing the config, or via `hermes config`). `hermes send -t
  <target>` is the delivery channel. hermes accepts `--ignore-user-config`.
- **codex** has a hook system gated by hook-trust (`--dangerously-bypass-hook-trust`
  for vetted automation). Config lives in `~/.codex/config.toml`; `$CODEX_HOME`
  relocates the config dir (seen in `--profile` help: `$CODEX_HOME/<name>.config.toml`).
  `codex exec --json` streams JSONL events. Current `~/.codex/config.toml` has no
  hooks block.

**NOT captured during polish (the builder MUST pin these in P0 before coding a
parse — do not guess field names):** the exact JSON field for the edited path
and the session id in (a) the hermes `post_tool_call` payload and (b) the codex
post-tool hook payload. **Non-invasive capture method (does not touch the user's
real config):**
- hermes: point at a throwaway config, register a `jq`/`cat`-to-file hook for
  `post_tool_call`, and run `hermes hooks test post_tool_call --for-tool Edit`
  (optionally `--payload-file`) — read the dumped synthetic payload.
- codex: `export CODEX_HOME=$(mktemp -d)`, write a minimal `config.toml` with a
  post-tool hook that dumps stdin, run a trivial `codex exec --json` edit with
  `--dangerously-bypass-hook-trust`, read the dumped payload and the `--json`
  event stream. Delete the temp dir after.

Record the pinned field names in the Ledger so the parse is written against
real payloads, not assumptions.

## Decisions

### Locked
| # | Decision |
|---|---|
| **D0** | **Auto-wire is opt-in; the default does NOT touch harness config.** `install.sh` gains an opt-in (flag `--wire-shoulder` and/or a `[shoulder]` config key); **unset ⇒ install touches no `.claude/settings.json` / `~/.codex/config.toml` / `~/.hermes/config.yaml`**, exactly as today (`docs/shoulder-mode.md:226`). This preserves the deliberate "installer refuses to own settings.json" principle while satisfying the ask. Baking the per-harness `*_NOTE_CMD` **env into units** is separate from editing harness config and is also opt-in via `[notify]`. |
| **D1** | One dispatching delivery script (`agents/release/critic-note.sh`) that branches by harness, keeping the exit-code contract in one place. Distinct name from any private-hub `critic-note.sh`; reads channel/target from **env/config, never a baked path** (leak-check enforces). |
| **D2** | Separate capture scripts per harness (`critic-queue-codex.sh`, `critic-queue-hermes.sh`) — each harness's payload parse differs; each normalizes to the shared queue format. |
| **D3** | Prefer each **harness's own config CLI/format** to register hooks over a hand-rolled parser: codex via its `config.toml` hook block, hermes via `hermes config` / `~/.hermes/config.yaml`. Avoids needing a TOML/YAML *writer* dependency (see Risks). |
| **D4** | Phase 5 live e2e on **both** codex and hermes is a **hard gate**, not advisory (locked in /feature). |
| **D5** | Stop-gate teeth ship for codex + hermes, disarmed unless `CRITIC_BLOCK=1`; crew headless runs never arm them. |

### Open (default applied; record + proceed)
| # | Question | Default |
|---|---|---|
| O1 | `[notify]` shape | A `[notify]` table with per-harness `cmd`/`target`, baked into `*_NOTE_CMD`. Fallback to reusing the `QUARTET_NOTIFY_CMD` env contract if that proves cleaner during build. |
| O2 | Env var name for per-harness delivery | Keep the single `CLAUDE_NOTE_CMD` name (already the drain's contract) and let `critic-note.sh` dispatch by harness, rather than minting `CODEX_NOTE_CMD`/`HERMES_NOTE_CMD`. Revisit if a harness needs a distinct command. |

### User-decision class (flag at review — no default invented)
- **D0 reverses a documented design principle** (`install.sh` refusing to own
  `.claude/settings.json`). The opt-in default keeps today's behavior, so **no
  phase is blocked** — but the reviewer should confirm they want install to be
  *able* to edit `~/.codex/config.toml` / `~/.hermes/config.yaml` at all, even
  behind a flag. Writing to a home-level harness config is an **ask-first**
  action at build time (Boundaries).

## Orchestration protocol

The builder is an orchestrator: delegate each harness's payload-capture + parse
to a subagent with a tight brief (pin fields → write script → bats fail-first),
keep the orchestrator lean, and **re-verify every gate personally** — never
trust a subagent's "green." Re-run the real command and read the real output.

## Implementation Plan

Phases are independently committable and leave the system unbroken between them
(each new file is inert until its opt-in is set). Verification surfaces below use
the exact commands from `.agents/gates.md`.

### Phase 0 — pin the real payloads (2 pts)
- Capture the hermes `post_tool_call` and codex post-tool payloads via the
  non-invasive method above; **pin the path + session-id field names in the
  Ledger.** No production code yet.
- **Verification surface:** paste the two captured payloads (redacted) into the
  Ledger; state the exact jq/field path for `file_path` and `session_id` per
  harness. DoD: both field paths recorded, reproduced by a second run.

### Phase 1 — codex capture + reference delivery (5 pts)
- Write `agents/release/critic-queue-codex.sh` parsing the P0-pinned codex
  payload → append to `<project>/tmp/critic-queue-<session>` in the **exact**
  format `critic-queue.sh:57` uses.
- Write `agents/release/critic-note.sh` (env/config-driven, codex branch), honoring
  exit codes `0/2/3/other`.
- **Verification surface:**
  - `bash -n agents/release/critic-queue-codex.sh agents/release/critic-note.sh`
  - New bats in `tests/shoulder-mode.bats` (or a new file) **shown failing first**:
    feed a canned codex payload on stdin → assert the queue file gets the right
    `"<file> <epoch>"` line; assert garbage stdin / missing path is a safe no-op
    (mirror the claude hook-robustness cases). Delivery: assert each exit code
    drives the documented queue action (reuse the existing delivery-exit-path cases).
  - `bats tests/` green; `bash scripts/leak-check.sh` clean.
- **DoD:** the new bats cases fail on `main` and pass on the branch; leak-check clean.

### Phase 2 — hermes capture (3 pts)
- `agents/release/critic-queue-hermes.sh` for the P0-pinned `post_tool_call`
  payload; add the `hermes send` branch to `critic-note.sh`.
- **Verification surface:** `bash -n` the new script; bats fail-first with a
  canned hermes payload → correct queue line; `bats tests/` green; leak-check clean.
- **DoD:** new cases fail on `main`, pass on branch; leak-check clean.

### Phase 3 — installable delivery + `[notify]` + opt-in wiring + `--doctor` (5 pts)
- Parse `[notify]`; `install.sh` bakes `*_NOTE_CMD` into generated units (env is
  baked at install — **re-bake units when env changes**, Traps).
- Add the **opt-in** (`--wire-shoulder` / `[shoulder]`, D0): when set, register the
  capture (+ optional stop) hooks into the target harness's native config
  **additively** (never clobber an existing hook); when unset, touch nothing.
- Extend `install.sh --doctor` to report per-harness shoulder-mode wiring drift
  (capture hook present? delivery wired?), read-only.
- **Verification surface:**
  - `bash -n install.sh`; `install.sh --dry-run --project <fixture>` prints the
    intended wiring (and, with the opt-in **unset**, prints **no** harness-config
    change — the invariance check).
  - **Unset-invariance bats (the critical regression):** with the opt-in unset,
    assert the generated unit env and any `.claude/settings.json` are
    **byte-identical to pre-change** (a `make_fixture_project` install, diff the
    output). This case must fail if any default path starts touching harness config.
  - Additive-merge bats: a fixture `~/.codex/config.toml` / `~/.hermes/config.yaml`
    with a pre-existing unrelated hook survives the wiring (assert the prior hook
    is still present).
  - `install.sh --doctor --project <fixture>` exits 0 when wired, flags when not.
  - `bats tests/` green; `bash scripts/leak-check.sh` clean.
- **DoD:** unset-invariance + additive-merge cases pass; doctor drift observable;
  no machine path in any tracked file.

### Phase 4 — stop-gate teeth parity (3 pts)
- `agents/release/critic-stop-gate-codex.sh` / `-hermes.sh` (subagent_stop /
  session-stop), disarmed unless `CRITIC_BLOCK=1`.
- **Verification surface:** `bash -n`; bats fail-first for all three states
  (disarmed exits 0; armed with a `block` finding refuses; armed with none exits
  0) per harness, mirroring the existing claude stop-gate cases; assert crew
  headless env never arms it. `bats tests/` green.
- **DoD:** per-harness stop-gate states covered; `token-caps.bats` still green.

### Phase 5 — live e2e + docs + full gate sweep (2 pts)
- **Live e2e on THIS machine (hard gate, D4):** a real codex authoring session
  and a real hermes authoring session, each with `--wire-shoulder` enabled and a
  `critic-watch.sh --project <dir>` running: make an edit → confirm the queue
  captured it → the watcher spawned a critique → delivery observed. **Record both
  runs (commands + observed queue file + the `release.critique` event line) in
  `.agents/gates.md` Traps.**
- Update `README.md` env table (new knobs) + shoulder-mode/harness section.
- **Full sweep:** `bats tests/`, `bash scripts/leak-check.sh`,
  `bash scripts/check-deck-fresh.sh`, and the syntax sweep from `.agents/gates.md`
  (`bash -n install.sh agents/lib/*.sh agents/*/runner.sh agents/release/critic-*.sh scripts/*.sh .githooks/pre-commit && python3 -m py_compile scripts/gen-deck-data.py`).
- **DoD:** both live runs recorded with real evidence; every gate green.

## Testing Strategy

- **bats** (`tests/`, PATH-shimmed, no network/model), each **shown failing
  first**: codex + hermes capture-to-queue (incl. robustness), per-harness
  delivery exit-code handling, per-harness stop-gate states, install additive
  merge, **unset-invariance**, `--doctor` drift.
- **Leak firewall:** `scripts/leak-check.sh` on the shipped `critic-note.sh` and
  install code — no home path / private email / key-shaped literal.
- **Config-gated additivity:** the unset-invariance case is the proof that the
  unset value equals today's behavior (gate class in `.agents/gates.md`).
- **Model-invocation caps:** keep `tests/token-caps.bats` green (delivery/spawn
  changes must not introduce a bare uncapped model call).
- **Live e2e** (Phase 5): manual, recorded in Traps per the house rule for
  model-touching verification.

## Acceptance Criteria / Definition of Done

- [ ] P0 payload field names for codex + hermes are pinned in the Ledger from
      real captures (not guessed).
- [ ] A codex authoring session's edits land in `critic-queue-<session>` in the
      existing format; `critic-watch.sh` drains them **unchanged**.
- [ ] A hermes authoring session's edits are captured the same way via
      `post_tool_call`.
- [ ] The repo ships `critic-note.sh` — generic, leak-safe, dispatches per
      harness, honors exit codes `0/2/3/other` exactly; **leak-check green**.
- [ ] `install.sh` auto-wire is **opt-in**; **unset ⇒ byte-identical to
      pre-change** (proven by the unset-invariance bats case); when set it merges
      **additively** (a pre-existing harness hook survives).
- [ ] `install.sh` bakes per-harness `*_NOTE_CMD` from `[notify]`; unset ⇒
      log-and-skip.
- [ ] Stop-gate teeth exist for codex + hermes, disarmed unless `CRITIC_BLOCK=1`;
      crew headless runs never arm them.
- [ ] `install.sh --doctor` reports per-harness wiring drift, read-only.
- [ ] Every new behavior has a bats case shown failing against pre-change code
      first, via the PATH shim.
- [ ] **Live e2e recorded in `.agents/gates.md` Traps:** real codex + real hermes
      sessions each captured → critiqued → delivered on this machine, with the
      actual queue-file and event-line evidence.
- [ ] Every new env knob baked into generated units by `install.sh` **and** in
      the `README.md` env table.
- [ ] Gates green: `bats tests/`, `scripts/leak-check.sh`,
      `scripts/check-deck-fresh.sh`, the `.agents/gates.md` syntax sweep.

## Dependencies

- **Blocks:** `deck-shoulder-mode-clarity.md` (Ticket B) — its harness-support
  claim reflects this ticket's outcome (or states "in progress" if it lands first).
- **External:** codex + hermes CLIs (present). Live e2e (P5 only) needs
  model/network; P0–P4 are fully offline.

## Risks & Mitigations

- **No stdlib TOML/YAML *writer*** (`python3 tomllib` is read-only; no stdlib
  YAML) → **D3:** register hooks via each harness's own config mechanism
  (`hermes config`, codex `config.toml` block) rather than a hand-rolled editor;
  if a textual additive-append is used, the additive-merge bats case is the guard.
  **No new top-level dependency** (Boundaries).
- **Harness payload shapes undocumented** → P0 pins them from real captures
  before any parse is written.
- **Writing a home-level harness config is invasive** → opt-in only (D0);
  **ask-first** at build time; `--dry-run` previews; never clobber (additive-merge
  test).
- **hermes consent allowlist blocks the hook on first run** → surface the one-time
  `hermes hooks` approval step in docs; do not silently `--dangerously-bypass`.
- **Fleet-live edits** (`install.sh`, `agents/lib/**`, `agents/release/critic-*`)
  execute on every project's next timer fire (Traps) → reason about every config
  shape; the unset-invariance case proves claude-only installs are unaffected.
- **Delivery-name collision with the private hub `critic-note.sh`** → distinct
  shipped name + config-driven channel (leak-check enforces no baked path).

## Out of scope

- Rewriting `critic-watch.sh`'s drain/spawn/budget core (boundary).
- Deck/docs clarity rewrite — Ticket B.
- Any new daemon/module boundary beyond the existing watcher.
- New top-level runtime dependencies (stays bash / jq / python3 `tomllib`).
- Harnesses other than claude/codex/hermes.

## Ledger

_(builder appends per phase: plan → commit hash → honest notes, incl. the P0
pinned payload field names and the two Phase-5 live-run evidence blocks.)_

---
Run it: `execute-ticket docs/tickets/harness-agnostic-shoulder-mode.md`
