# shipyard

**A crew of five autonomous agents that design, build, release, and repair a
repo while you sleep** — each a [Claude Code](https://claude.com/claude-code)
instance on a systemd timer:

| role id | display (`--theme spacetime`) | cadence | job |
|---|---|---|---|
| **design** | mentat | nightly | mine the project's telemetry into ≤3 evidence-backed proposals; a human stamps them |
| **build** | helldiver | nightly | triage user feedback into PRs; build stamped tickets |
| **release** | proctor | daily + on-edit | run the test/audit battery; critique diffs cold-context |
| **medic** | suk | every 10 min | detect incidents, mitigate (restart / revert), route repairs into the design loop |
| **scribe** | chronicler | daily | keep docs/content in sync with the code |

The **role id** is the stable identity: the agent dir (`agents/<role>/`), the
`[<role>]` config section, the event `role:` field. The **display name** —
systemd unit names, notification voice — is chosen at install time with
`--theme`: `plain` (role ids verbatim), `spacetime` (the column above), or
`custom:d,b,r,m,s` (five names in role order `design,build,release,medic,scribe`).
A config with no `[names]` block displays the role ids verbatim.

## The loops

**Design.** Nightly, mentat's collectors aggregate the telemetry the project
already produces — the JSONL event stream, access-log path counts, user
feedback in `data/fyi-requests.jsonl`, `data/usage/*.jsonl` beacons, open
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
audit, fixes what it safely can, and reports.

Shoulder mode is wired per project, not by the installer: merge a
`PostToolUse` hook (matcher `Edit|Write|MultiEdit`) into
`<project>/.claude/settings.json` running `agents/release/critic-queue.sh` —
it appends each edited file to a per-session queue and always exits 0 — and
keep `critic-watch.sh --project <dir>` running (a long-lived user service
works; it polls every 30s and fires at 5 min idle or 8 queued files).
Delivery is `$CLAUDE_NOTE_CMD <session> <message>`; exit 2/3 means
not-delivered and keeps the queue, and the critique is **cached across
retries** — a failed delivery never re-spends the model. Spend is capped by
`[release] budget_tokens_daily` (default 1M/day), counted from the project's
own `release.critique` events. Full mechanics — the hook, the queue, the
debounce arithmetic, diff assembly, delivery exit codes, the opt-in stop gate —
are in [docs/shoulder-mode.md](docs/shoulder-mode.md).

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
Definition of Done). Both hand `write-ticket` a scope and stop at the human
stamp unless the operator says "and build it."

## Skills-parity

The installer symlinks six skills — `write-ticket`, `bugfix`,
`feature`, `polish-ticket`, `execute-ticket`, `coverage-audit` — from this
repo's `skills/` into `<project>/.claude/skills/`. Headless agents and
in-session humans load the **identical files**: one implementation, two
callers, no agent-only fork. A core upgrade flows to every project at once.

## North star

Each project hands mentat a one-line compass: `[design] north_star` in
`.agents/config.toml` if set, else the repo's GitHub description
(`gh repo view --json description`). It is a **directional prior** — it ranks
proposals toward what the repo is *for*; it never gates. Evidence still
decides what gets drafted.

## ⚠️ Read this before installing

These agents run `claude --dangerously-skip-permissions` **unattended, on a
schedule, with commit/PR rights on your repos**. The safety model is
configuration, and it is YOUR job:

| control | key / mechanism | default |
|---|---|---|
| PR reviewer | `project_owner` in `.agents/config.toml` — build opens PRs, a human reviews | required |
| self-merge | `[medic] can_merge` | **false** |
| zero-CI merges | `[build] allow_no_ci` — a repo with no CI checks cannot pass the merge gate vacuously | **false** |
| forbidden paths | `[build] forbidden_paths` — any edit inside one is refused (`forbidden_path:<path>`); medic never escalates failures there | `[]` |
| spend / scope caps | every role: `budget_tokens_daily` (summed per project per role from the day's `job.end` events) + per-invocation `wall_clock_sec` timeouts as the hard guard; `[design] max_open_proposals`; `[medic] daily_escalation_cap` | 1M tokens/day |
| off switch | `systemctl --user disable --now <project>-<display>.timer` — per crew, instant | — |
| inspect first | `install.sh --dry-run` prints every unit and crontab change before writing | — |

Agents only get projects you explicitly install them on. Start with one
low-stakes repo.

## Requirements

Linux with systemd (user instance), Claude Code installed and authenticated,
`jq`, `python3` (3.11+), `gh` (authenticated, for PRs), `git`.

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
./install.sh --project /path/to/myproject --dry-run          # inspect first
./install.sh --project /path/to/myproject --theme spacetime  # then for real
./install.sh --project /path/to/myproject --agents design,build,release,medic,scribe
```

Default `--agents` is `build,release,medic,scribe` — design is opt-in. The
installer bakes the `[names]` theme block into the config, writes
`~/.config/systemd/user/<project>-<display>.{service,timer}` and enables the
timers, symlinks the six shared skills into `<project>/.claude/skills/`,
drops `skills/gates.md.template` into `.agents/gates.md` (never clobbering an
existing gate file), removes legacy cron launchers that would race the timers
(crontab backed up first), and prints next-fire times.

Re-runs are safe: without `--theme`, an existing `[names]` block is honored
(only an explicit `--theme` renames a fleet), and the installer **sweeps any
stale unit set for the same project+role left under an old display name**, so
a theme change or rename can never leave two sets of timers firing the same
agent twice.

**Doctor** — a read-only audit of what a crew install owns, so drift is
visible instead of surfacing weeks later:

```bash
install.sh --doctor --project <project_dir>
```

Exit 0 clean; exit 1 with one `DOCTOR <class>: <detail>` line per finding.
It checks the manifest install writes — expected units enabled and pointed at
`$QUARTET_DIR`, no stale duplicate role units, no foreign `.service.d`
drop-ins, no retired config keys, skill symlinks resolving into
`$QUARTET_DIR/skills`, no dead `.claude/settings.json` hooks, no legacy
launchers/cron — and finishes in well under a second, so a `[[medic.checks]]`
entry can run it every scan. It never writes or touches systemd.

**Uninstall** — remove exactly the installer-owned surface; the config you
wrote and your data are left untouched:

```bash
install.sh --uninstall --project <project_dir> [--dry-run]
```

It disables + removes this project's crew units/timers, removes the shared
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

## Notifications & environment knobs

Transport-agnostic. Knobs are **baked into the generated units at install
time** (user services don't inherit your shell env), so set them when running
`install.sh`:

| var | effect |
|---|---|
| `QUARTET_NOTIFY_CMD` | notification command taking `(title, body)` — Signal wrapper, `ntfy`, email; unset = silent (events still log) |
| `QUARTET_EVENTS_DIR` | where the JSONL event stream lands (default `data/events/` in this repo) |
| `QUARTET_OPS_JSON` | optional systemd/cron state snapshot for medic's scan |
| `QUARTET_SCRIBE_PRE_HOOK` | optional executable run before each scribe pass |

## Event stream

Every run appends JSONL to `data/events/YYYY-MM-DD.jsonl`: `job.start` /
`job.end` with status + duration, `design.proposal.opened` /
`design.proposal.skipped`, `medic.incident.*` lifecycle (detected, classified,
frozen, `repair_proposed`, resolved), `release.critique` +
`release.critique.skipped`. Every event carries the canonical `role:` field
(`design`/`build`/`release`/`medic`/`scribe`) alongside the display-named
`svc`. Build dashboards on it, or just `jq` it.

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
skills/         the six shared skills + install + gates.md.template
install.sh      per-project installer (idempotent; --theme names)
docs/           INSTALL.md, ADAPTING.md, shoulder-mode.md, deck data
pack.toml       BopBop pack manifest
```

## License

MIT
