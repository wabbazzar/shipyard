# shipyard

**A crew of five autonomous agents that design, build, release, and repair a
repo while you sleep** — each a [Claude Code](https://claude.com/claude-code)
instance scheduled by systemd on Linux or launchd on macOS:

| role id | display (`--theme spacetime`) | cadence | job |
|---|---|---|---|
| **design** | mentat | nightly | mine the project's telemetry into ≤3 evidence-backed proposals; a human stamps them |
| **build** | helldiver | nightly | triage user feedback into PRs; build stamped tickets |
| **release** | proctor | daily + on-edit | run the test/audit battery; critique diffs cold-context |
| **medic** | suk | every 10 min | detect incidents, mitigate (restart / revert), route repairs into the design loop |
| **scribe** | chronicler | daily | keep docs/content in sync with the code |

The **role id** is the stable identity: the agent dir (`agents/<role>/`), the
`[<role>]` config section, the event `role:` field. The **display name** —
scheduler job names, notification voice — is chosen at install time with
`--theme`: `plain` (role ids verbatim), `spacetime` (the column above), or
`custom:d,b,r,m,s` (five names in role order `design,build,release,medic,scribe`).
A config with no `[names]` block displays the role ids verbatim.

## The loops

**Design.** Nightly, mentat's collectors aggregate the telemetry the project
already produces — the JSONL event stream, access-log path counts, user
feedback in `data/fyi-requests.jsonl`, real-usage beacons from
`[design].usage_path` (default `data/usage`), open
medic incidents — and mentat drafts **at most 3** proposals. Every proposal's
`evidence` field must quote a real datum from that summary (an exact event
count, a verbatim feedback line, a path + request count); a quiet night
returns `[]`. Mentat drafts only — it never writes code or touches the repo.
Proposals wait for a **human stamp** in a dispatch queue; decisions land in
`<project>/data/decisions.jsonl`, and denied proposals are never re-drafted.

**Build.** A stamped proposal flows down one road:
`write-ticket → polish-ticket → execute-ticket → PR`, with `project_owner` as
the reviewer. The same crew triages asynchronous user feedback
(`data/fyi-requests.jsonl`) nightly into small PRs; substantial asks become
design proposals instead of drive-by patches. A hardened ticket can also be
driven headless — `runner.sh --mode ticket --ticket-file <path>` — gated
behind `[build] ticket_mode` (default **false**; unset is exactly today's
behavior).

**Release.** Two surfaces. A **shoulder-mode critic**
(`agents/release/critic-watch.sh`) batches a dev session's edits and, when the
session goes quiet, runs one cold-context critique over the whole diff — it
never sees the author's transcript (goal contamination), never writes code,
and delivers findings into the live session as notes, never hard stops. The
**daily battery** runs the project's tests, typecheck, and every configured
audit, fixes what it safely can, and reports. Unchanged worktree dirt captured
before the run is an actionable hygiene notice, not a failed verdict; new or
changed dirt still fails.

Capture, critique, delivery, and the opt-in stop gate all work whether the
authoring session runs **claude, codex, or hermes**: each harness fires a
post-edit hook (`agents/release/critic-queue{,-codex,-hermes}.sh`) that appends
the edited file to the *same* per-session queue, and `critic-watch.sh --project
<dir>` (a long-lived user service; polls every 30s, fires at 5 min idle or 8
queued files) drains it unchanged. Wiring is **opt-in** — the installer never
touches a harness config unless you ask: `install.sh --wire-shoulder` (or
`[shoulder] auto_wire = true`) additively registers the capture hook in the
authoring harness's native config and writes `.agents/shoulder.env` from the
`[notify]` block so `$CLAUDE_NOTE_CMD` points at the shipped, generic
`agents/release/critic-note.sh` (no hand-wiring). `install.sh --doctor` reports
wiring drift once a project has opted in. Delivery is `$CLAUDE_NOTE_CMD
<session> <message>`; exit 2/3 means not-delivered and keeps the queue, and the
critique is **cached across retries** — a failed delivery never re-spends the
model. Spend is capped by `[release] budget_tokens_daily` (default 1M/day).
Full mechanics — the per-harness hooks, the queue, debounce arithmetic, diff
assembly, delivery exit codes, the opt-in stop gate — are in
[docs/shoulder-mode.md](docs/shoulder-mode.md).

Two crews sit outside the loop:

**On-call (medic).** Every 10 minutes: walk the service surface + the other
agents' results, build candidate incidents, classify, act. Mitigation is
ungated — restart a whitelisted unit, revert a merge that fails post-merge
validation (`agents/lib/revert-merge.sh`; the revert path is proven by
`runner.sh --self-test`). A `regression`-class incident does **not** get
auto-fixed: medic writes an **incident-repair proposal** into the design
loop's result file (`medic.incident.repair_proposed` + `design.proposal.opened`
events, deduped, capped daily) and the repair waits for the same human stamp
as any other work. The old medic→build auto-merge side-door is retired:
`build --mode incident` emits nothing and exits 3.

**Docs (scribe).** Daily: refresh the configured content paths, optionally
auto-commit/push (`[scribe] auto_commit` / `auto_push`). Scribe failures
notify only — they never escalate to medic.

Humans enter the same loop through two front-door skills: **`/bugfix`**
(reproduce-and-root-cause first — a failing test, reliable steps, or a
captured signature; no ticket until the defect is pinned) and **`/feature`**
(clarify first — verify assumptions, lock an Objective and a checklist
Definition of Done). Both hand `write-ticket` a scope, then `polish-ticket`
**auto-gates**: no open decision → it drives straight through `execute-ticket`
(build, commit/push/deploy, bounded by the project's `can_merge`/`allow_no_ci`/
`forbidden_paths`); any open user-decision-class item (spend, outward-facing,
destructive, live-automation behavior, design fork) → stop and surface it via
`AskUserQuestion`. An `autonomous = true` project skips even that stop,
applying each decision's recorded default instead.

**Every phase says who builds it.** A ticket phase carries a `Delegation:` line
— `subagent — <brief>` or `inline (<reason>)` — that `write-ticket` drafts as
intent, `polish-ticket` hardens into a self-contained brief with a bounded
return (≤40 lines: files, exit codes, evidence, blockers), and `execute-ticket`
obeys, recording the matching `builder:` line in the ticket's Ledger.
Delegation is the **default**; `inline` is legitimate but must name its reason,
because an orchestrator that builds everything itself spends most of a run's
budget re-reading its own context rather than doing work. Delegation moves the
work, never the verification — the orchestrator still re-runs each phase's gate
before committing. `scripts/delegation-report.py` measures whether it's
actually happening.

## Skills-parity

The installer links all eight shared skills — `write-ticket`, `bugfix`,
`feature`, `polish-ticket`, `execute-ticket`, `coverage-audit`, `shipyard`, and
`ui-design` — into
`<project>/.agents/skills/` for Codex and `<project>/.claude/skills/` for
Claude/Hermes; both roots resolve to the same source files. It also creates a
root `AGENTS.md` bridge when absent, but never changes a project-owned one.
This guarantees repository-local discovery, not entries or labels in a
host-managed/global skill-picker UI.

**`/shipyard`** is the operator's in-project console for the install itself
(`skills/shipyard/shipyard.sh` is its deterministic core, with load-bearing exit
codes `0`/`2`/`3`):

- `shipyard status` — read-only report of the scheduler jobs installed here, where
  each `.agents/<role>.md` block lives, and an `install.sh --doctor` drift audit
  (exit `3` when nothing is installed). It also reports the machine-level
  dashboard's loaded/running state, private URL, event path, and latest event—or
  the exact install command when the dashboard is absent.
- `shipyard dashboard [--open]` — print the private dashboard URL and health.
  The default is non-interactive; only the explicit `--open` flag launches a
  browser.
- `shipyard inspect [--json] [--days N]` — strictly read-only fleet evidence
  from matching current-user manifests into the current Shipyard core. The
  default human console and stable schema-v1 JSON are rendered from one
  document. This is a bounded, best-effort observation, not a certification of
  fleet health: missing/malformed sources and snapshot limitations stay
  explicit, and recommendations for the next Shipyard PR remain
  evidence-bounded assessments.
- `shipyard add-specialist <subsystem>` — scaffold the **specialist** archetype
  (below) for one subsystem and wire it into the project's `write_ticket`
  context, a gates note, and a hunk-keyed release-critic block.
- `shipyard learn "<lesson>"` — route a lesson through the `docs/ADAPTING.md`
  taxonomy (`--to project|generic|install`, else a keyword heuristic) to a
  project note or a `docs/tickets/` stub for review.

For the current inspection, a multi-project design/shoulder budget
recommendation is eligible only when exact manifests prove one resolved
unscoped gate root for multiple projects; it never infers an unknown shoulder root.

### The specialist archetype (an installable sixth role)

Beyond the five lifecycle roles, a project can install a **specialist**
(`agents/specialist/`): a standing, knowledge-bearing *reviewer* for one
subsystem that reads a living decision log before it answers, guards that
subsystem's settled decisions and invariants against fresh-context erosion, and
reproduces "why does X happen" against the real system rather than narrating a
plausible story. It reviews; it does not redesign. Scaffold it with
`/shipyard add-specialist`. See `docs/ADAPTING.md`.

## Dogfood overseer

Autonomous repos (`autonomous = true`) run the crew hands-off and never surface
in the approval wire — so nothing normally checks whether that crew is producing
*good* work. The **overseer** (`agents/overseer/runner.sh`) is a fleet-level
meta-QA timer (`shipyard-overseer.timer`, not a crew role): on an interval it
walks every autonomous repo under `CODE_ROOT`, hands each crew's recent outputs
(every role's result JSON, the feedback signals, the north star, recent git) to
an LLM judge, and asks *is this crew producing correct, coherent work?* It flags
a hallucinated proposal, a false-green proctor verdict, a claimed-but-absent
build/merge, an inappropriate medic action, or a role that stopped running.

It **notifies only when something is wrong** — a healthy sweep is silent (an
`overseer.assessed status=ok` event only), so it adds no noise. It reads and
judges; it never writes code or touches a repo. Verdict → `<repo>/tmp/overseer-result.json`.
Run one on demand: `agents/overseer/runner.sh --project <dir>` (exit 3 if the
repo isn't autonomous); `--check-config` lists the repos it would assess.

## North star

Each project hands mentat a one-line compass: `[design] north_star` in
`.agents/config.toml` if set, else the repo's GitHub description
(`gh repo view --json description`). It is a **directional prior** — it ranks
proposals toward what the repo is *for*; it never gates. Evidence still
decides what gets drafted.

## Five-day fleet trial

The fixed July 22–26, 2026 UTC trial met **2/4 floors** — **T1 PASS ·
T2 MISS (2/3 projects) · T3 MISS (0 valid ordered chains) · T4 PASS**. Work
after the window was not backfilled. Both misses and their remediation are
tracked in [the trial follow-up](docs/tickets/pending/close-five-day-trial-findings.md).

## ⚠️ Read this before installing

These agents run `claude --dangerously-skip-permissions` **unattended, on a
schedule, with commit/PR rights on your repos**. The safety model is
configuration, and it is YOUR job:

| control | key / mechanism | default |
|---|---|---|
| PR reviewer | `project_owner` in `.agents/config.toml` — build opens PRs, a human reviews | required |
| real usage source | `[design].usage_path` — readable project-relative directory containing JSONL beacons; invalid, missing, empty, and unreadable sources stay explicit coverage rather than becoming measured zero | `data/usage` |
| self-merge | `[medic] can_merge` | **false** |
| zero-CI merges | `[build] allow_no_ci` — a repo with no CI checks cannot pass the merge gate vacuously | **false** |
| forbidden paths | `[build] forbidden_paths` — any edit inside one is refused (`forbidden_path:<path>`); medic never escalates failures there | `[]` |
| spend / scope caps | six independently enforced daily consumers: `design_runner`, `build_runner`, `release_runner`, `release_shoulder_critic`, `medic_runner`, and `scribe_runner`. Inspect reports current-UTC-day attributed use and the gate operand each consumer actually enforces; release runner and shoulder critic remain separate consumers. Per-invocation `wall_clock_sec`, `[design] max_open_proposals`, and `[medic] daily_escalation_cap` are additional guards. | 1M tokens/consumer/day |
| stall self-heal | `[release] stall_retries` — a mid-stream model stall (no `result.json` written) is retried in-process before the job fails, so a one-off stall self-heals instead of forcing a medic retry. A written verdict (pass **or** fail) is never retried. Each retry is one extra model run. | **0** (off) |
| false-green guard | `[release] verify_gate` — in hook/daily mode the proctor *self-reports* its verdict; with this set the runner re-runs the real `typecheck` + `test_cmd` and overrides a claimed `pass` to **fail** if either really fails, so a hallucinated green can't reach medic or the dispatch. Costs one real gate run. post-merge already runs the gate deterministically. | **false** (trust the model) |
| outcome lineage | `[telemetry] outcome_lineage` — adds only opaque run/work/critique IDs, explicit domain references, available token classes, and critique delivery dispositions; malformed non-booleans fail config validation | **false/unset** (legacy event bytes) |
| off switch | Linux: `systemctl --user disable --now <project>-<display>.timer`; macOS: `launchctl bootout gui/$(id -u)/com.shipyard.<project>-<display>` | — |
| hands-off repo | `autonomous = true` (top-level) — a private, disposable dogfood repo with no human in the loop: it never appears in the hub's approval wire, and the ticket auto-gate proceeds without stopping even for a user-decision. Pair with `[medic] can_merge = true`. **Only ever set this on a throwaway private repo.** | **unset** (human-in-the-loop) |
| inspect first | `install.sh --dry-run` prints every unit and crontab change before writing | — |
| raw Git identity | tracked `.shipyard-git-identity.toml` opt-in checks exact authors and committers in hooks, doctor, and CI; an optional digest-only policy admits one system committer solely on canonical-author, two-parent merges | **absent/off** |

Agents only get projects you explicitly install them on. Start with one
low-stakes repo.

## Requirements

Linux with a systemd user instance, or macOS with launchd. Both require Claude
Code installed and authenticated, `jq`, Python 3.11+, authenticated `gh`, and
`git`. macOS also needs GNU `timeout` and `sha256sum`:

```bash
brew install coreutils jq
```

## Install on a project

The full model — six layers L0 (shared core) through L5 (symlinked skills) —
is in [docs/INSTALL.md](docs/INSTALL.md); the `install` skill
(`skills/install/SKILL.md`) drives the interview. The mechanics:

1. Create `<project>/.agents/config.toml`:

```toml
project_name  = "myproject"
project_owner = "your-github-user"   # PR reviewer — required
branch        = "main"   # optional — else detected from origin/HEAD; runners fail (exit 2) if neither resolves

[release]
test_cmd  = "npx vitest run"
typecheck = "npx tsc --noEmit"

[build]
allow_no_ci = false

[medic]
can_merge = false
```

   plus per-role prompt extensions (`.agents/<role>.md`) — project-specific
   instructions appended to each role's generic `role.md`. Config sections and
   prompt filenames use the role ids only (`[build]`/`[release]`,
   `build.md`/`release.md`) — the legacy `[augur]`/`[guardian]` compat layer
   is retired.

2. Run the installer:

```bash
/bin/bash ./install.sh --project /path/to/myproject --dry-run          # inspect first
/bin/bash ./install.sh --project /path/to/myproject --theme spacetime  # then for real
/bin/bash ./install.sh --project /path/to/myproject --agents design,build,release,medic,scribe
```

On a fresh project, the default role set is
`build,release,medic,scribe` — design is opt-in. On a re-run without
`--agents`, the installer instead preserves the intentional install: it selects
the canonical roles declared in `[install.timers]` plus any canonical role
whose existing job is enabled. An explicit `--agents` list remains
authoritative. Build, Release, Medic, and Scribe require their matching
`.agents/<role>.md`; a missing required prompt names every affected role and
exits 2 before any file write or scheduler mutation. Design has no project
prompt requirement.

The installer auto-detects the host OS, bakes the `[names]` theme block into
the config, and writes either systemd units under
`~/.config/systemd/user/` or LaunchAgent plists under
`~/Library/LaunchAgents/`. It then enables the selected jobs, symlinks the
eight shared skills into `<project>/.claude/skills/`,
writes a root `AGENTS.md` skill bridge for Codex and Hermes when absent, drops
`skills/gates.md.template` into `.agents/gates.md` (never clobbering an
existing gate file), removes legacy cron launchers that would race the timers
(crontab backed up first), and prints next-fire times.

Re-runs are safe: without `--theme`, an existing `[names]` block is honored
(only an explicit `--theme` renames a fleet), and the installer **sweeps any
stale job for the same project+role left under an old display name**, so
a theme change or rename can never leave two scheduler jobs firing the same
agent twice.

The portable `[install.timers]` schedule subset is `*-*-* HH:MM:00` for a
daily job and `*-*-* *:0/N:00` for every N minutes. The installer rejects a
schedule that launchd cannot translate instead of silently changing cadence.

To opt in, track `.shipyard-git-identity.toml` at the repository root:

```toml
[git_identity]
enforce = true
name = "your-github-user"
```

By default every author and committer must match the canonical name and locally
configured email exactly. Repositories that support GitHub web merges may also
track `allow_github_merge_committer = true` together with a 64-hex
`github_merge_committer_sha256` digest of the NUL-delimited system committer
name/email tuple. The exemption applies only to two-parent commits with an
exact canonical author; canonical committers remain valid on every topology.
Omitting the pair preserves the exact policy. Like the canonical tuple check,
this is metadata conformance rather than cryptographic provenance: tuple
spoofing is outside its threat model. Never track or print the raw system tuple.

Then set the intended name and email in effective Git configuration and
configure the repository-local guard:

```bash
install.sh --configure-git-identity --project <project_dir>
```

The command requires the effective name to match `project_owner`, writes
`user.name`, `user.email`, `shipyard.identityEmail`, and
`core.hooksPath=.githooks` locally, verifies the pending identity, and never
prints the email. CI reads the same email only from the
`SHIPYARD_IDENTITY_EMAIL` repository secret and checks full raw history.

**Doctor** — a read-only audit of what a crew install owns, so drift is
visible instead of surfacing weeks later:

```bash
install.sh --doctor --project <project_dir>
```

Exit 0 clean; exit 1 with one `DOCTOR <class>: <detail>` line per finding.
It checks the manifest install writes — configured or enabled jobs present,
enabled, pointed at `$QUARTET_DIR`, and backed by the required project prompt;
no stale duplicate role jobs; no foreign `.service.d` drop-ins on systemd; no
retired config keys; skill symlinks resolving into `$QUARTET_DIR/skills`; no
dead `.claude/settings.json` hooks; no legacy launchers/cron; and exact local
Git identity/hook keys for opted-in projects. Disabled roles absent from
`[install.timers]` are intentional, not Doctor drift. The audit finishes in
well under a second, so a `[[medic.checks]]` entry can run it every scan. It
never writes or touches the scheduler.

**Uninstall** — remove exactly the installer-owned surface; the config you
wrote and your data are left untouched:

```bash
install.sh --uninstall --project <project_dir> [--dry-run]
```

It disables + removes this project's systemd units or LaunchAgent plists,
removes the shared
skill symlinks that resolve into `$QUARTET_DIR/skills`, and prints what it
deliberately leaves (`.agents/` incl. config + prompts + gates.md, `data/`,
`tmp/`). `--dry-run` prints the plan without writing. Reinstall is just
`install.sh --project <dir>` again — uninstall+install converges to a fresh
install.

## Liveness probes & drift checks (medic)

Medic's 10-minute scan can also watch your deployment surface, via
`.agents/config.toml`:

```toml
[[medic.probes]]                 # HTTP probe: wrong status ⇒ incident
name          = "myproject-api"
url           = "https://api.example.com/api/auth/me"
expect_status = 401              # up-but-unauthed is the healthy signal
timeout_sec   = 10

[[medic.checks]]                 # drift check: nonzero exit ⇒ incident
name         = "frontend-deploy-drift"
cmd          = "scripts/medic-checks/frontend-deploy-drift.sh"
timeout_sec  = 30
restart_unit = "myproject-frontend-deploy.timer"  # optional — lets medic bounce it
```

Drift is usually operational, so medic classifies it `infra` (notify + 24h
freeze) or `restart` (when `restart_unit` is whitelisted) — never
`regression`. Copy-and-edit starters live in `agents/medic/check-examples/`.

## Security sweep (release)

Opt-in daily pass — dependency audit (critical CVEs fail the run), security
headers, secrets-in-commits grep over the last 24h (reported redacted).
Enable with a `[release.security]` block (`audit_dirs`, optional
`header_probe_url`); omit it and the sweep is skipped. Details in
`agents/release/role.md`.

The shoulder-mode critic's `CHANGED FILES` list is a *superset* of the files
that actually have diff hunks (it unions in hook-queued paths), so a
file-conditional critic check keyed on list membership can misfire on a file
with no delta. Set `[release] hunk_safe_gates = true` to mark no-hunk entries
`(no hunks)` in the prompt so a check can key on real hunks; unset (the default)
leaves the prompt byte-identical. See `agents/release/critic-role.md`.

## Notifications & environment knobs

Transport-agnostic. `QUARTET_NOTIFY_CMD`, `QUARTET_EVENTS_DIR`, and
`QUARTET_OPS_JSON` are **baked into generated scheduler jobs at install time**
(user jobs don't inherit your shell env), so set them when running
`install.sh`. The rest below are plain runtime env vars the runner/spawn code
reads directly (`${VAR:-default}`) — install.sh does not bake them into any
job, so an unmanaged job needing one (e.g. the overseer's fleet timer, which
install.sh does not manage at all) must set it by hand:

| var | effect |
|---|---|
| `QUARTET_NOTIFY_CMD` | notification command taking `(title, body)` — Signal wrapper, `ntfy`, email, or `scripts/notify-macos.sh` for Notification Center; unset = silent (events still log) |
| `QUARTET_EVENTS_DIR` | where the JSONL event stream lands (default `data/events/` in this repo) |
| `QUARTET_OPS_JSON` | optional systemd/cron state snapshot for medic's scan |
| `SHIPYARD_DASHBOARD_PORT` | private loopback dashboard port used by its separate installer/service (default `8765`) |
| `QUARTET_SCRIBE_PRE_HOOK` | optional executable run before each scribe pass |
| `CODE_ROOT` | root the dogfood overseer scans for `autonomous = true` repos (default `~/code`) |
| `OVERSEER_HARNESS` | authoring harness the overseer's QA judge runs under (default `claude`) |
| `OVERSEER_MODEL` | model the overseer's QA judge uses (default `sonnet`) |
| `OVERSEER_WALL_CLOCK` | per-repo wall-clock cap for the overseer's judge call, seconds (default `600`) |
| `SPAWN_STALL_RETRIES` | how many times `spawn_model` retries a transient upstream stream stall (claude CLI `Response stalled mid-stream`, overloaded/429/5xx) before giving up — **default `2`**, all roles/harnesses. A wrapper timeout (RC 124) and non-transient failures are never retried. Set `0` for the pre-2026-07 single-shot behavior. |
| `SPAWN_STALL_BACKOFF` | space-separated seconds between those retries — **default `5 15`** (attempts beyond the list reuse the last value). |
| `CLAUDE_NOTE_CMD` | shoulder-mode delivery command `(session, message)`; unset ⇒ log-and-skip. `--wire-shoulder` bakes it to `agents/release/critic-note.sh --harness <h>`. |
| `CRITIC_NOTE_HARNESS` | which authoring harness `critic-note.sh` delivers for (`claude`·`codex`·`hermes`); default `claude`. |
| `CRITIC_NOTE_DELIVER_CMD` | optional session-injector `critic-note.sh` calls first; its exit code passes through (0 delivered · 2/3 keep queue · other=broken). |
| `CRITIC_NOTE_TARGET` | hermes delivery target for `hermes send -t <target>` (e.g. a Signal/Slack channel). |
| `CRITIC_BLOCK` | per authoring session: `1` arms the opt-in stop gate; unset ⇒ disarmed (crew headless runs never set it). |

Shoulder-mode wiring is **opt-in** and additive — `install.sh --wire-shoulder`
(or `[shoulder] auto_wire = true`, `[shoulder] harness = <h>`) registers the
capture hook in the authoring harness's native config and writes
`.agents/shoulder.env` from the `[notify]` block (`target`, `cmd`); with the
opt-in unset the installer touches no harness config, exactly as before.

### Notification policy

Shipyard system notifications are an exception channel, separate from direct
BopBop conversation replies. Routine scheduled-agent news remains available in
the JSONL event stream and Ice/Daily Dispatch. Set the minimum class delivered
by the configured notification transport in the project config:

```toml
[notify]
signal_level = "actionable"
```

The ordered classes are `routine < actionable < urgent`; accepted policy
values are `all`, `actionable`, `urgent`, and `off`. `all` sends every class,
`actionable` sends actionable and urgent messages, `urgent` sends only urgent
messages, and `off` suppresses all classified messages. An unset policy means
`all`, preserving delivery for existing installations. An invalid value fails
open to `all` and records `reason=invalid_policy`, so a typo cannot hide an
urgent alert.

Call the shared API as:

```bash
quartet_notify --class routine|actionable|urgent \
  [--episode <stable-key>] [--window <seconds>] <title> <body>
```

The default deduplication window is 86,400 seconds. An explicit episode is
deduped per project inside that window; a successful delivery consumes the
episode key, while policy suppression or transport failure does not. The
legacy `quartet_notify <title> <body>` form remains valid and retains its
pre-policy behavior, including emitting no classification decision.

Every classified call appends a `notification.decision` event with `class`,
`episode`, effective `policy`, and an `outcome` of `delivered`, `suppressed`,
or `deduped`. This decision record supplements rather than replaces the
underlying job, incident, proposal, or approval event.

The two `SPAWN_*` rows carry **built-in defaults inside `agents/lib/spawn.sh`**, so unlike
the rows above they need no `install.sh` bake to take effect; set them in a
unit's env only to tune or disable per project.

### Per-role harness / model / provider

Each role runs on `claude` (Claude Code) by default. Point a role at a different
agentic harness — `codex` (OpenAI Codex CLI) or `hermes` (Hermes Agent) — and a
model/provider **via config**; `install.sh` bakes the resolved values into that
role's unit. Precedence: `[<role>].<knob>` → `[harness].<default|model|provider>`
→ unset (⇒ today's `claude`/`sonnet`, byte-identical). Provider API keys
(`OPENROUTER_API_KEY`, …) are **never** baked — source them at runtime.

| config key | baked unit env | effect |
|---|---|---|
| `[harness].default` / `[<role>].harness` | `<ROLE>_HARNESS` | `claude` (default) · `codex` · `hermes` |
| `[harness].model` / `[<role>].model` | `<ROLE>_MODEL` | model id (e.g. `sonnet`, `gpt-5.4`, `openrouter:moonshotai/kimi-k3`) |
| `[harness].provider` / `[<role>].provider` | `<ROLE>_PROVIDER` | provider for the harness (e.g. `openrouter`) |

Token accounting is normalized per harness for the daily gate: claude reads the
JSON usage envelope, codex the `turn.completed` usage event, and hermes (which
emits no per-invocation count) reads usage back from its session store
(`hermes sessions export`).

## Event stream

Every run appends JSONL to `data/events/YYYY-MM-DD.jsonl`: `job.start` /
`job.end` with status + duration, `design.proposal.opened` /
`design.proposal.skipped`, `medic.incident.*` lifecycle (detected, classified,
frozen, `repair_proposed`, resolved), `release.critique` +
`release.critique.skipped`. Every event carries the canonical `role:` field
(`design`/`build`/`release`/`medic`/`scribe`) alongside the display-named
`svc`.

Set `[telemetry] outcome_lineage = true` to add the tabled content-free lineage
fields. It never emits prompts, messages, diffs, filenames, critique prose,
result bodies, or private filesystem paths; unset/false is byte-compatible with
the legacy stream.

The optional **private operations dashboard** is the built-in read-only view
of that stream. It runs as one native user service, binds only
`127.0.0.1:${SHIPYARD_DASHBOARD_PORT:-8765}`, and uses no database, cloud
transport, or build step. Its in-memory index reads only canonical daily files
needed by the largest supported 30-day window; it never edits or deletes older
history:

```bash
scripts/install-dashboard.sh --install
skills/shipyard/shipyard.sh dashboard       # prints URL + health
skills/shipyard/shipyard.sh dashboard --open
```

There is one authored dashboard presentation:
[`renderer.js`](dashboard/static/renderer.js) and its scoped
[`renderer.css`](dashboard/static/renderer.css). Standalone Shipyard supplies a
small same-origin loopback adapter. Ice retains its own global and Health
navigation around `/shipyard`, but supplies only transport, route, asset,
provenance, mount/teardown, and theme isolation to that exact renderer—no
second component tree, state grammar, graph implementation, or dashboard CSS.
macOS launchd and Linux systemd install the same renderer assets and digest;
their differences stop at native service manifests, environment discovery,
activation, logs, and restart commands. The full adapter and teardown contract
is documented in [dashboard/README.md](dashboard/README.md).

Adapters consume `GET /api/operator?window=24h|7d|30d`. A successful response
has `schema_version: 1`, `kind: "shipyard.operator"`, and the public sections
`metadata`, `brief`, `narrative`, `promises`, `outcomes`, `topology`, `changes`,
`attention`, `coverage`, and `evidence`. Shipyard core owns every promise/KPI
meaning, state, threshold, priority, label, limitation, topology relationship,
and array order. A dashboard may format timestamps and map supplied semantic
tokens to presentation, but it must not recalculate, reprioritize, or sort the
document.

`brief` is the core-owned, bounded operator reading order: one state,
takeaway, and action; at most four qualified signals; at most eight grouped
attention rows; and explicit limitations. Each signal carries its label, unit,
state, observed coverage, and total. Each attention group carries item,
evidence-record, and project counts without replacing the full `attention` and
`evidence` arrays. Adapters render these strings and arrays in supplied order.
They show evidence as a counted action such as `Review 18 records` outside the
Evidence view; opaque evidence IDs are visible only in Evidence/detail.

`metadata.inspection_state` is `fresh`, `stale`, or `unavailable`; stale means
the last good snapshot is being served. Unknown, partial, unverified, and not
applicable remain distinct from zero and from success. Responses are bounded
to 200 attention items, 500 evidence objects, and eight story beats, with any
truncation stated in coverage. The deterministic adapter example is
[`dashboard/tests/fixtures/operator-v1.json`](dashboard/tests/fixtures/operator-v1.json).

Schema v1 is additive: readers ignore unknown members while preserving the
supplied order, and render an unknown enum as unknown/unavailable rather than
healthy. Removing, retyping, or changing the meaning of an existing member or
stable ID requires a new schema version. Adapters must not receive filesystem
paths, prompts, messages, diffs, filenames, result bodies, or critique prose,
and must never reconstruct this view from raw JSONL.

Existing installs keep the event path already baked into their crew jobs; a
clean install falls back to `~/Library/Application Support/Shipyard/events/`
on macOS or `${XDG_STATE_HOME:-~/.local/state}/shipyard/events/` on Linux.
Changing the path rebakes configuration only—it never moves, rewrites, or
deletes history. See [the install guide](docs/INSTALL.md#private-local-operations-dashboard)
for service lifecycle, log locations, and doctor behavior.

This private machine view is deliberately separate from the public narrative
deck below. Notification Center remains the current actionable/urgent
attention path; a future Slack or BopBop adapter may consume classified
notifications, but chat is not the event-history store.

## Deck publishing

The deck (`docs/index.html` + `styles.css` + generated `shipyard-data.json`) is
served two ways under `wabbazzar.com`:

- **`/shipyard/`** — GitHub Pages `main:/docs` of this repo; a push to `main`
  redeploys it automatically.
- **`/writing/the-shipyard/`** — a copy in the `wabbazzar.github.io` repo, kept a
  deterministic mirror by a **`pre-push` hook** (`.githooks/pre-push`): when
  `main` is pushed it materializes the deck from the pushed commit, applies the
  two destination transforms, and commits + pushes only that repo's
  `writing/the-shipyard/` paths — so both URLs publish the same bytes together.

The cascade is **off until you point it at the mirror checkout**, so a fresh
clone never touches anything external:

| knob | effect |
|---|---|
| `[deck] mirror_dir` (in `.agents/config.toml`) | path to the `wabbazzar.github.io` checkout; unset ⇒ the hook is a silent no-op |
| `$DECK_MIRROR_DIR` | env override for the same (e.g. a one-off re-sync) |

Run it by hand with `scripts/sync-deck-mirror.sh [<sha>]` (defaults to `HEAD`);
exit `0` = pushed, `2` = bad config/guard, `3` = no-op (unset or unchanged).
The deck is the canonical public presentation: behavior or public-claim changes
update its existing editorial and the relevant existing reference above, not a
parallel explainer. Completion requires both published deck JSON files to match
the committed local bytes.

## Docs

- [docs/INSTALL.md](docs/INSTALL.md) — the six-layer install model (L0 core → L5 skills), the flow, uninstall
- [docs/ADAPTING.md](docs/ADAPTING.md) — how the crew adapts: five feedback channels, the routing rule
- [docs/shoulder-mode.md](docs/shoulder-mode.md) — the shoulder-mode critic end to end: hook → queue → debounce → cold critique → delivery
- [The deck](https://wabbazzar.com/shipyard/) — the system, narrated, with live status

## Using as a BopBop pack

If you run [BopBop](https://github.com/wabbazzar/bopbop), install this repo
as a context pack so your assistant can check crew health, relay feedback,
and trigger runs from your phone:

```bash
bopbop pack install https://github.com/wabbazzar/shipyard
```

Per-project installs remain explicit (`install.sh --project …`).

## Repo layout

```
agents/
├── design/     role.md + runner.sh + collectors.sh        [spacetime: mentat]
├── build/      role.md + runner.sh                        [spacetime: helldiver]
├── release/    role.md + runner.sh + critic-* (shoulder)  [spacetime: proctor]
├── medic/      role.md + runner.sh + check-examples/      [spacetime: suk]
├── scribe/     role.md + runner.sh                        [spacetime: chronicler]
└── lib/        load-config.sh, naming.sh, post-run.sh, log_event.sh, revert-merge.sh
skills/         the eight shared skills + install + gates.md.template
install.sh      per-project installer (idempotent; --theme names)
docs/           INSTALL.md, ADAPTING.md, shoulder-mode.md, deck data
pack.toml       BopBop pack manifest
```

## License

MIT
