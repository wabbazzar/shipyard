# Harness-agnostic role runners

- **Created:** 2026-07-23
- **Owner:** wabbazzar
- **Status:** Polished — ready for `execute-ticket` (behind the human stamp)
- **Type:** feature
- **Estimated Points:** 26 (P1 5 · P2 5 · P3 5 · P4 3 · P5 3 · P6 5)
- **Refs:** `/feature` → `write-ticket` → `polish-ticket`; gate file `.agents/gates.md`.
  Harness contracts researched from vendor docs 2026-07-23 (sources in Ledger notes).

## Goal

Route every role-runner model spawn through one shared dispatcher
(`agents/lib/spawn.sh`) so a role can be backed by one of three installed
agentic CLIs — `claude` (Claude Code 2.1.218, default), `codex` (codex-cli
0.145.0), or `hermes` (Hermes Agent 0.18.0) — each driving a chosen
model/provider (Claude default · OpenRouter · Kimi). **With config unset, the
composed command line at every site is byte-identical to today.** Bridge the
skill-delivery gap with a generated per-project `AGENTS.md` that points the
foreign harnesses at the already-symlinked `.claude/skills/*/SKILL.md`, so all
six roles port — not just the stdout-shaped ones. Prove it with stubbed bats
(P1–P5, hermetic) and a live `caladan` mock simulation (P6, all six roles × 3
harnesses, OUTSIDE CI).

## Context & pointers (all verified 2026-07-23)

### The 7 spawn sites — NON-UNIFORM (byte-identity is per-site)

| Runner | Line | Flags today | timeout | skip-perms |
|---|---|---|---|---|
| `agents/build/runner.sh` (live) | 214 | `--model --dangerously-skip-permissions --output-format json` | `$WALL_CLOCK` | yes |
| `agents/build/runner.sh` (ticket) | 312 | same; `cd $PROJECT_DIR` first | `$WALL_CLOCK` | yes |
| `agents/design/runner.sh` | 332 | `--model --output-format json` | **none** | **no** |
| `agents/medic/runner.sh` | 879 | `--model --dangerously-skip-permissions --output-format json` | `timeout 900` | yes |
| `agents/release/runner.sh` | 206 | `--model --dangerously-skip-permissions --output-format json` | `$WALL_CLOCK` | yes |
| `agents/scribe/runner.sh` | 183 | `--model --dangerously-skip-permissions --output-format json` | `$WALL_CLOCK` | yes |
| `agents/release/critic-watch.sh` | 327 | `model_args=(--model $CRITIC_MODEL)` **only if set**; `--output-format json` | **none** | **no** |

The dispatcher is parameterized by the **caller's** flag intent (skip-perms
on/off, timeout value or none, model/model_args). It must not impose one
canonical line.

### Harness headless contracts (from `--help` + vendor docs, 2026-07-23)

**claude** — `claude -p --model M [--dangerously-skip-permissions] --output-format json PROMPT`
→ one JSON object `{result, usage:{input_tokens,output_tokens}}`. Token parse
today: `((.usage.input_tokens // 0) + (.usage.output_tokens // 0))`, `[[ =~ ^[0-9]+$ ]] || 0`.
Skills: symlinked into `<project>/.claude/skills`, auto-discovered.

**codex** — `codex exec [PROMPT|-] -m MODEL [flags]`:
- `--json` → **JSONL event stream**: `thread.started`, `turn.started`,
  `turn.completed`, `turn.failed`, `item.*`. **Token usage rides
  `turn.completed`:** `{"type":"turn.completed","usage":{"input_tokens":N,"cached_input_tokens":N,"output_tokens":N}}`
  (cumulative). **Parse:** last `turn.completed` event → `input_tokens + output_tokens`,
  0-fallback. `jq -c 'select(.type=="turn.completed") | .usage' | tail -1`.
- `-o/--output-last-message <FILE>` → final assistant message to a file (use for
  "result text" / the design JSON-array case).
- **Do NOT rely on `--output-schema`** for structured result: it is silently
  ignored / malformed when tools or MCP are active (openai/codex#15451). Roles
  write `result.json` with codex's own file-write tools instead (same as today's
  prompt contract), and tokens come from the event stream, not the schema.
- Sandbox/perms: `-s workspace-write` + `--dangerously-bypass-approvals-and-sandbox`
  (skip-perms equivalent for unattended runs; or config `approval_policy="never"`
  + `sandbox_mode="workspace-write"`).
- provider/model: `-m MODEL`; OpenRouter via a `[model_providers.openrouter]`
  config block (`base_url`/`env_key`/`wire_api`) selected with
  `-c model_provider="openrouter"`. Kimi = an OpenRouter model slug.
- AGENTS.md merge: `~/.codex/AGENTS.md` (global) → git-root down to cwd,
  concatenated root-down (closer overrides; `AGENTS.override.md` > `AGENTS.md`).

**hermes** — `hermes -z PROMPT -m MODEL --provider PROVIDER --yolo --accept-hooks`:
- `-z/--oneshot` prints **ONLY final response text** to stdout (no JSON, no
  session line; approvals auto-bypassed). `--yolo` bypasses dangerous-command
  approval; `--accept-hooks` auto-approves headless hooks.
- **No token count on `-z` stdout, but hermes DOES track usage per session** —
  interactively via `/usage` and `/status` slash commands, and programmatically
  via `hermes insights [--days N]` or `hermes sessions export <id>`. Since `-z`
  prints no session id, meter via `hermes chat -q <prompt> -Q --pass-session-id`
  (emits final text **plus** session info), capture the session id, then read
  its usage post-run. **v1 contract:** record real `tokens` with
  `token_source:"hermes-session"`; 0-fallback only if the lookup fails
  (Decision D-3 — metered, not unmetered).
- AGENTS.md + SOUL.md auto-injected (CWD / `$HERMES_HOME`; SOUL.md is system-prompt
  slot #1). `--skills`/`-s` preloads skills from `~/.hermes/skills/`.
- provider/model: `--provider openrouter`, `-m openrouter:kimi-coding` (or a
  provider-prefixed slug). Also settable via `HERMES_INFERENCE_MODEL`.

### The skill-delivery bridge (Decision D-2 — RESOLVED: adapter in scope)

Claude-Code skills live at `<project>/.claude/skills/*/SKILL.md` (install.sh
already symlinks them). codex and hermes don't auto-discover that dir, BUT both
(a) auto-inject a CWD/repo-root `AGENTS.md` and (b) have file-read + bash tools.
**So a thin generated `AGENTS.md` at the target-project root that names the
skill file paths and says "read and follow `.claude/skills/<skill>/SKILL.md`
before acting" bridges skill discovery for both harnesses** — no new module, no
per-harness skill port. Two consequences the runners must honor:

1. **`result.json` already ports.** Roles that produce `result.json`
   (build/release/medic/scribe) have the model *write the file with its tools*
   per the existing prompt ("write your result to `$RESULT_FILE`") — this never
   depended on `--output-format json` (that envelope is only read for tokens +
   the debug `.result` echo). codex/hermes have file-write tools, so the file
   gets written. `design` is the exception: it parses the model's **final text**
   as a JSON array → `spawn_model` must return a normalized `final_text`
   (claude `.result` / codex `-o` file / hermes stdout).
2. **CWD must be the project root** for AGENTS.md auto-injection. build
   ticket-mode already `cd`s (`:305`); the dispatcher (or each call site) must
   ensure CWD=`$PROJECT_DIR` for codex/hermes so the generated AGENTS.md loads.

This makes "all six roles" achievable within the structural boundary: the
"adapter" is (P1–P3) `spawn_model`'s normalized final-text/token return + (P5) a
generated `AGENTS.md`/`SOUL.md` written by `install.sh`, alongside the existing
skill symlinks. **No new top-level dependency, no new module/service.**

### Config→env→unit baking

`install.sh` bakes only `QUARTET_NOTIFY_CMD/OPS_JSON/EVENTS_DIR` today
(`install.sh:540-548` `for var in …` loop → `$quartet_env` → spliced at ~:560).
`${<ROLE>_MODEL:-sonnet}` is never set, so every role runs `sonnet`. Extend the
loop to bake resolved harness/model/provider env per unit. **Foreign-harness auth
(`OPENROUTER_API_KEY`, `CODEX_HOME` creds, etc.) is NEVER baked into a
tracked/generated file** — leak-check is law; source at runtime (D-7).

### Toolchain verified on this box (2026-07-23, §C2)
- `bats` 1.10.0 at `/usr/bin/bats`; `bats tests/token-caps.bats` → **13/13 green** (baseline).
- `bash scripts/leak-check.sh` → **clean** (baseline).
- `codex` 0.145.0, `hermes` 0.18.0, `claude` 2.1.218 on PATH — all **stubbed**
  via `make_stub`/`make_stub_script` for bats (no live harness in CI).
- `run_runner` (`tests/helpers.bash:258`) supports design/build/medic/release/scribe;
  **critic-watch is a long-lived loop — not `run_runner`-able** → byte-identity
  via source inspection + a targeted dispatch-path unit.

## Decisions

### Locked
| # | Decision |
|---|---|
| D-1 | One shared `agents/lib/spawn.sh` dispatcher behind all 7 sites. No new module/service/top-level dependency. |
| D-2 | **Adapter IN scope — all six roles.** The bridge is `spawn_model`'s normalized final-text/token return + a generated `AGENTS.md`/`SOUL.md` (install.sh) pointing foreign harnesses at the symlinked `.claude/skills/*/SKILL.md`. `result.json` is tool-written and already ports. |
| D-4 | Unset `harness`/`model`/`provider` ⇒ `claude`+`sonnet`+no-provider ⇒ today's exact per-site line. Config-gated additivity; exit codes stay load-bearing (2 = bad config, 3 = no-op). |
| D-5 | Default harness stays `claude` for every role on every installed project. codex/hermes strictly opt-in per role. No live automation default changes. |
| D-6 | P1–P5 bats stub the harness binaries (no network/model). Live harness runs only in P6, outside CI. |
| D-7 | Foreign-harness secrets runtime-sourced, never baked into tracked/generated files. |
| D-12 | codex tokens from the **last `turn.completed.usage`** (`input_tokens+output_tokens`), 0-fallback. Never use `--output-schema` for `result.json` (openai/codex#15451). |
| D-3 | **hermes IS metered.** No usage on `-z` stdout, but usage is tracked per session (`/usage`,`/status` interactively; `hermes insights`/`hermes sessions export <id>` programmatically). Meter via `hermes chat -q … -Q --pass-session-id` → capture session id → post-run usage lookup; real `tokens`, `token_source:"hermes-session"`, 0-fallback only on lookup failure. No `unmetered` hole; no `allow_unmetered` gate needed. |
| D-11 | **Live spend AUTHORIZED** (owner: "use money is fine", 2026-07-23). Non-claude harnesses route via OpenRouter: hermes `--provider openrouter -m openrouter:<kimi-slug>`; codex `-c model_provider=openrouter -m <slug>`. Confirm the exact current Kimi/OpenRouter slug with a cheap probe at P6 — slugs drift; do not hardcode a stale paid one. |

### Open — default applied, builder records & proceeds
| # | Question | Default |
|---|---|---|
| D-8 | Config key shape. | Global `[harness].default` + per-role `[<role>].harness/model/provider`, read via `load-config.sh`→JSON→jq. Record final shape in README. |
| D-9 | codex provider routing. | A `[model_providers.openrouter]` config block + `-c model_provider="openrouter"`; revisit if a P2 capture shows it ignored. |
| D-10 | `spawn_model` return contract. | Return `(final_text, token_count)`; unchanged downstream for `harness=claude`. |
| D-13 | AGENTS.md generation scope. | install.sh writes a minimal root `AGENTS.md` (+ hermes `SOUL.md`) into the target project listing each installed role's skill path with "read+follow before acting"; regenerated on install like the skill symlinks. |

### User-decision class
_All resolved 2026-07-23: D-3 (hermes metered via session lookup) and D-11 (live
spend authorized) are now Locked above. No open user-decision items block the
build. Remaining safety wall is unchanged: fleet default stays `claude` (D-5),
human stamp + green CI + `can_merge=false`._

## Phases

> **Orchestration (every phase):** builder is an orchestrator — delegate wide
> work to subagents, keep the orchestrator lean, re-verify personally.
> **Anti-cheating brief (verbatim):** *Converge honestly or report the precise
> blocker with the actual evidence — NEVER fake green, weaken a check, or
> hand-wave "should work". Run the real command, read the real file, and report
> exact output (exit codes, JSONL lines, argv logs), not adjectives.* One clean
> commit per phase; unset=today so each phase lands safely on the live fleet.

### Phase 1 — Extract `agents/lib/spawn.sh`, byte-identical (5 pts)
Add `spawn_model` accepting the caller's flag intent; route all 7 sites through
it with `harness=claude` hardcoded (no config read yet). Preserve each site's
exact flags (table) — design & critic-watch pass no timeout/skip-perms; the rest
pass their timeout + skip-perms. `spawn_model` returns normalized
`(final_text, token_count)` (claude: `.result` + usage parse).

**Migrate `tests/token-caps.bats` test 10** (the failing-first case): it greps
`medic build release scribe` runner.sh for `timeout … claude -p`; after
extraction the literal moves into `spawn.sh`, so it FAILS. Rewrite to assert (a)
no bare `claude -p` in `spawn.sh` outside a `timeout` guard when the caller
requested one, and (b) the four timeout-wrapping sites pass a non-empty timeout
to `spawn_model`. Red against pre-change `spawn.sh`, then green. Tests 6–9 stay
green unchanged.

**Byte-identity pin:** `make_stub_script claude` logging `"$@"` to an argv file;
run each role via `run_runner` with config unset; assert recorded argv == the
documented per-site line. critic-watch via source inspection + direct dispatch call.

**Verify (bats · shell scripts · model-invocation caps):**
```
bash -n agents/lib/spawn.sh agents/*/runner.sh agents/release/critic-watch.sh
bats tests/token-caps.bats && bats tests/
```
**DoD:** full `bats tests/` green; per-site argv-log == pre-change line char-for-char; `bash -n` clean.

### Phase 2 — `harness=codex` dispatch + `turn.completed.usage` parse (5 pts)
codex branch: `codex exec <prompt> -m <model> -s workspace-write --dangerously-bypass-approvals-and-sandbox -o <tmp> --json [-c model_provider=<p>]`.
final_text ← `-o` file; tokens ← last `turn.completed.usage` (`input+output`, 0-fallback, D-12).

**Verify (bats · config-gated additivity · model-invocation caps):**
`make_stub_script codex` emitting a representative JSONL stream incl. a
`turn.completed` usage event + writing the `-o` file. New cases: harness=codex
composes expected argv; `job.end` carries parsed tokens; **unset still composes
the claude line** (D-4). Optionally capture ONE real `codex exec --json` locally
(owner-run, D-11) to confirm the field; record sample in Ledger.
```
bats tests/<codex case> && bats tests/
```
**DoD:** stubbed codex case green; argv matches; `tokens` from the stub's
`turn.completed`; unset path unchanged.

### Phase 3 — `harness=hermes` dispatch + provider + metering (5 pts)
hermes branch (metered path, D-3): `hermes chat -q <prompt> -Q --pass-session-id
-m <model> --provider <provider> --yolo --accept-hooks`. final_text ← stdout
(final response); capture the session id from the emitted session info; post-run
`hermes sessions export <id>` (or `hermes insights`) → `tokens`,
`token_source:"hermes-session"`, 0-fallback only on lookup failure. (The purer
`-z` is the fallback if a run can't surface a session id — then tokens=0.)

**Verify (bats · config-gated additivity):** `make_stub_script hermes` that
echoes final text + a session-info line for `chat -q -Q`, and answers the
`sessions export` sub-call with a fixture usage payload. Cases: harness=hermes +
provider=openrouter composes the expected argv; `job.end` carries the looked-up
`tokens` + `token_source:"hermes-session"`; a stubbed lookup-failure yields the
0-fallback; unset path still claude.
```
bats tests/<hermes case> && bats tests/
```
**DoD:** stubbed hermes case green; argv matches; `job.end` reflects the
looked-up session tokens (and the 0-fallback branch is exercised).

### Phase 4 — Config→env→unit baking + README rows (3 pts)
Extend the `install.sh:540-548` `Environment=` loop to bake resolved
`<ROLE>_MODEL`/harness/provider per unit; add README env-knob rows. No secret baked (D-7).

**Verify (systemd units · shell scripts · public-repo hygiene):**
```
./install.sh --dry-run --project <fixture>   # new Environment= lines per unit
./install.sh --doctor  --project <fixture>   # exits 0
bash scripts/leak-check.sh                    # clean — no API keys in generated text
bats tests/                                    # + generated-unit-env case
```
**DoD:** `--dry-run` shows harness/model/provider `Environment=` lines; `--doctor`
exits 0; leak-check clean; README rows present.

### Phase 5 — Skill-bridge `AGENTS.md`/`SOUL.md` generation (3 pts)
install.sh writes a minimal root `AGENTS.md` (+ hermes `SOUL.md`) into the target
project (regenerated like the skill symlinks) listing each installed role's
`.claude/skills/<skill>/SKILL.md` with "read and follow before acting." Ensure
the dispatcher runs codex/hermes with **CWD=`$PROJECT_DIR`** so AGENTS.md
auto-injects (build ticket-mode already `cd`s; audit the others).

**Verify (shell scripts · bats · public-repo hygiene):**
```
./install.sh --dry-run --project <fixture>    # shows the generated AGENTS.md/SOUL.md content
bash scripts/leak-check.sh                      # generated files carry no owner/machine data
bats tests/                                      # case: generated AGENTS.md references each installed skill path; CWD=project asserted for the codex/hermes dispatch
```
**DoD:** `--dry-run` prints an AGENTS.md that names every installed role's skill
path; a bats case proves the dispatch sets CWD=project for foreign harnesses;
leak-check clean.

### Phase 6 — caladan mock + all-six × 3-harness simulation (5 pts) — live spend authorized (D-11)
Scaffold `caladan`, a minimal mock travel-planning app (throwaway fixture, NOT a
shipped product), as a target project. Install the crew (`--theme spacetime`).
Run **all six roles** once under each harness (claude/codex/hermes) and capture
each to a log showing a valid role output (proposal / result.json / commit).

**Verify (live — OUTSIDE CI; no bats):**
```
./install.sh --project ~/code/caladan --theme spacetime --agents design,build,release,medic,scribe
# per role × harness: set the role's harness/model/provider, then:
systemctl --user start caladan-<display>.service
tail -100 "$QUARTET_EVENTS_DIR/$(date +%F).jsonl" | jq 'select(.role=="<role>")'
```
Capture each `job.end` + emitted artifact into the Ledger. Live spend is
authorized (D-11); **confirm the current OpenRouter Kimi slug with one cheap
probe before the paid runs** (slugs drift). Set `OPENROUTER_API_KEY` at runtime
(never baked, D-7).

**DoD:** caladan installs clean (`--doctor` exits 0); the event stream shows a
valid `job.end` per role per authorized harness; each captured artifact is
well-formed; any role that fails on a foreign harness is documented with the
exact blocker (not hand-waved).

## Ledger
_(builder appends per phase: plan, commit hash, honest notes; P2 the real codex
`turn.completed` sample; P6 the per-role×harness captures. Harness-doc sources:
codex exec --json cheatsheet / openai/codex#19022,#19308,#15451; Hermes CLI
reference + OpenRouter integration cookbook; blakecrosley codex guide for AGENTS.md
merge order + model_providers.)_

- P1 — PLAN: add `agents/lib/spawn.sh` with `spawn_model` (claude branch only),
  canonical argv order `claude -p [--model M] [--skip-perms] [--output-format json] PROMPT`;
  source it in all 6 runners; replace each of the 7 inline spawn blocks with a
  `spawn_model …` call mapping `SPAWN_RAW/RC/TEXT/TOKENS` into each site's existing
  var names (downstream untouched). Add `<ROLE>_HARNESS`/`<ROLE>_PROVIDER` env reads
  (unset⇒claude, byte-identical). Migrate `token-caps.bats` test 10 to assert the
  dispatcher; add argv-log byte-identity cases. NOTE: critic-watch with `CRITIC_MODEL`
  set is the ONE order deviation (`--model` moves ahead of `--output-format json`) —
  same binary/flags/behavior; documented, not hidden.
  DONE (commit 658bc65): `agents/lib/spawn.sh` added (claude branch; canonical argv; errexit-safe
  capture; SPAWN_RAW/RC/TEXT/TOKENS/TOKEN_SOURCE globals; unknown harness → rc 2).
  All 7 sites route through it; `<ROLE>_HARNESS`/`_PROVIDER` env reads added
  (unset⇒claude). token-caps test 10 migrated (grep → dispatcher assertions),
  shown red first then green. New `tests/harness-spawn.bats` (5 cases) pins the
  composed argv per site shape. GATES: `bats tests/` 143 green (was 138 + 5),
  token-accounting tests 6–9 green THROUGH the dispatcher (behavior preserved),
  leak-check clean, deck-fresh, `bash -n` clean. The one order deviation
  (critic-watch + CRITIC_MODEL) is unreachable today (CRITIC_MODEL unset on the
  fleet) and behavior-identical. Commit: <pending>.
- P2 — DONE: `_spawn_codex` added — `codex exec [-m][-c model_provider][-s
  workspace-write --dangerously-bypass-approvals-and-sandbox] -o <tmp> --json PROMPT`;
  final text ← `-o` file; tokens ← last `turn.completed.usage` (input+output), 0-fallback;
  `SPAWN_TOKEN_SOURCE=codex`. NOT using `--output-schema` (codex#15451). 3 stubbed
  bats cases (composition+usage, 0-fallback, no-provider⇒no-`-c`). GATES: `bats tests/`
  146 green, leak clean, `bash -n` ok. Commit: 87d3daf.
- P3 — DONE: `_spawn_hermes` — `hermes chat -q <prompt> -Q --pass-session-id [-m][--provider][--yolo --accept-hooks]`.
  METERING FORMAT VERIFIED LIVE (one Kimi-K3/OpenRouter probe, D-11): reply on
  stdout (⇒ SPAWN_TEXT), `session_id: <id>` on stderr; `hermes sessions export -
  --session-id <id>` returns a JSON object with top-level `input_tokens`/`output_tokens`
  (probe read 15050+53=15103). Dispatcher pulls the id off stderr, reads usage,
  records real tokens (`SPAWN_TOKEN_SOURCE=hermes-session`), 0-fallback on any
  failure. NOT unmetered — D-3 hole closed. The 0-fallback test caught a real
  errexit-safety bug (no-match sid grep returned 1); fixed with `|| true`. 3
  stubbed bats cases (compose+meter, 0-fallback, no-provider). GATES: `bats tests/`
  149 green, leak clean, `bash -n` ok. Commit: a4abee2.
- P4 — DONE: `install.sh` env-baking loop (~549) now resolves per-role
  harness/model/provider from config (precedence `[<role>].<knob>` →
  `[harness].<default|model|provider>` → unbaked) and bakes `<ROLE>_HARNESS/_MODEL/_PROVIDER`
  into each unit; secrets never baked. README gained a "Per-role harness/model/provider"
  subsection + table. New `tests/fixtures/harness-config.toml` + `tests/harness-install.bats`
  (2 cases: override+global-fallback baked; unset⇒nothing baked). TICKET CORRECTION:
  the installer's `--dry-run` prints only `would write: <path>`, never unit bodies,
  so baking is verified by real-install unit inspection (stronger) — the DoD's
  "dry-run shows Environment lines" was infeasible and dropped. GATES: `bats tests/`
  151 green, leak clean, deck fresh, `bash -n` ok. Commit: <pending>.
- P5 —
- P6 —

## Roll-up Definition of Done
- [ ] All 7 sites route through `agents/lib/spawn.sh`; unset ⇒ per-site
      byte-identical argv (argv-log pins); full `bats tests/` green.
- [ ] `harness=codex` composes `codex exec … -m … -o … --json` and records tokens
      from `turn.completed.usage`; stubbed bats green.
- [ ] `harness=hermes` composes `hermes chat -q … -Q --pass-session-id --provider …
      -m … --yolo` and records real tokens via the post-run session lookup
      (`token_source:"hermes-session"`, 0-fallback exercised); stubbed bats green.
- [ ] `token-caps.bats` migrated and green.
- [ ] `install.sh` bakes harness/model/provider env into units; README rows added;
      generates skill-bridge `AGENTS.md`/`SOUL.md`; `--doctor` exits 0; leak-check clean.
- [ ] Dispatcher runs codex/hermes with CWD=project (AGENTS.md auto-injects).
- [ ] caladan scaffolded; crew installed; ≥1 valid output captured per role per
      authorized harness, or the exact blocker documented.
- [ ] Worktree clean per phase; fleet default stays `claude` (D-5); no secret baked (D-7).

---
Run it with: `execute-ticket docs/tickets/harness-agnostic-runners.md` — build
phase-by-phase, verify each on the real system per `.agents/gates.md`. No open user-decision
stop-points remain (D-3 metered, D-11 spend authorized); P6 confirms the live
OpenRouter/Kimi slug with a cheap probe before the paid runs.
