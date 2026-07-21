# guardian-quartet

**Four autonomous agents that keep a repo healthy while you sleep**, each a
[Claude Code](https://claude.com/claude-code) instance on a systemd timer:

| agent | cadence (default) | job |
|---|---|---|
| **guardian** | daily | run the test/audit battery, fix what it safely can, report |
| **augur** | nightly | triage user feedback (`data/fyi-requests.jsonl`) → autonomous PRs |
| **medic** | every 10 min | failure-triggered triage: classify incidents, drive augur, merge, re-trigger |
| **scribe** | daily | keep docs/content in sync with the code |

They cooperate: a failed guardian run escalates to medic; medic classifies
the incident and can task augur with a fix; augur opens a PR with the
project owner as reviewer; medic merges green PRs and re-runs guardian
post-merge. Every step is logged to an append-only JSONL event stream.

## ⚠️ Read this before installing

These agents run `claude --dangerously-skip-permissions` **unattended, on
a schedule, with commit/PR rights on your repos**. The safety model is
configuration, and it is YOUR job:

- **`project_owner` is the PR reviewer** — augur never merges its own
  work without a human-named reviewer on the PR. Set it.
- **Kill switches** — each agent honors a per-project kill switch in
  `.agents/config.toml`; flip it and the next run exits immediately.
- **Forbidden globs** — paths agents must never touch (secrets, auth,
  prod configs). Enforced in the agent prompts and checked in review.
- **Budgets** — per-run caps (turns, attempts, PRs) so a confused agent
  rate-limits itself instead of thrashing.
- **`--dry-run` first.** The installer prints every unit file and crontab
  change before you commit to it.
- Agents only get projects you explicitly install them on. Start with one
  low-stakes repo.

## Requirements

Linux with systemd (user instance), Claude Code installed and
authenticated, `jq`, `python3` (3.11+), `gh` (authenticated, for augur
PRs), `git`.

## Install on a project

1. Create `<project>/.agents/` with a `config.toml`:

```toml
project_name  = "myproject"
project_dir   = "/home/user/code/myproject"   # informational only — runners take --project  # leak-allow
project_owner = "your-github-user"            # PR reviewer — required
branch        = "main"   # optional — omitted: detected from origin/HEAD; runners FAIL (exit 2) if neither resolves, never assume a default

[install.timers]   # optional — override the default schedules
guardian = "*-*-* 04:30:00"
augur    = "*-*-* 03:30:00"
medic    = "*-*-* 00,05..23:00/10:00"
scribe   = "*-*-* 01:00:00"
```

   plus per-agent prompt blocks: `guardian.md`, `augur.md`, `medic.md`,
   `scribe.md` (project-specific instructions appended to each agent's
   generic role).

2. Run the installer:

```bash
./install.sh --project /path/to/myproject --dry-run   # inspect first
./install.sh --project /path/to/myproject             # then for real
./install.sh --project /path/to/myproject --agents guardian,medic  # subset
```

It writes `~/.config/systemd/user/<project>-<agent>.{service,timer}`,
enables the timers, removes legacy cron entries that would race them
(crontab is backed up first), and prints next-fire times.

## Liveness probes & drift checks (medic)

Beyond watching the other agents, medic's 10-minute scan can watch your
*deployment surface*. Two optional config mechanisms, both in
`.agents/config.toml`:

**HTTP probes** — the runner curls each URL every tick and synthesizes
an incident when the status differs from `expect_status`. Catches the
"server cleanly exited, unit `inactive` not `failed`, nobody noticed"
outage class:

```toml
[[medic.probes]]
name          = "myproject-api"
url           = "https://api.example.com/api/auth/me"
expect_status = 401          # up-but-unauthed is the healthy signal
timeout_sec   = 10
```

**Drift checks** — arbitrary project scripts the runner executes every
tick from the project dir; nonzero exit synthesizes an incident with
the script's stdout as evidence (write the stdout as the human-facing
drift message — medic quotes it verbatim in the notification):

```toml
[[medic.checks]]
name         = "frontend-deploy-drift"
cmd          = "scripts/medic-checks/frontend-deploy-drift.sh"
timeout_sec  = 30
restart_unit = "myproject-frontend-deploy.timer"  # optional — lets medic bounce it
```

Drift is usually operational (a missed restart, a wedged deployer), so
medic classifies it `infra` (notify + freeze) or `restart` (when
`restart_unit` is set and your `.agents/medic.md` says it's safe) —
never `regression`. Copy-and-edit starters live in
`agents/medic/check-examples/`: a server-restart drift check (service
must restart after server-path commits) and a frontend-deploy drift
check (deployed `version.json` commit stamp must match branch HEAD past
a grace window).

## Security sweep (guardian)

Opt-in daily security pass — dependency audit (critical CVEs fail the
run, highs are informational), security-header probe (HSTS, nosniff,
CORS wildcard), and a secrets-in-commits grep over the last 24h
(reported redacted: file + line + variable name, never the value).
Enable by adding the block to `.agents/config.toml`:

```toml
[guardian.security]
audit_dirs       = [".", "subpackage"]   # package dirs to dependency-audit
header_probe_url = "https://api.example.com/api/auth/me"  # optional
```

Omit the block and guardian skips the sweep entirely. Details in
`agents/guardian/role.md`.

## Notifications

Transport-agnostic. Set `QUARTET_NOTIFY_CMD` to any command that takes
`(title, body)` as two arguments — a Signal wrapper, `ntfy`, Pushover,
email. Unset = silent (events are still logged).

```bash
QUARTET_NOTIFY_CMD="/home/user/bin/notify" ./install.sh --project …  # leak-allow (placeholder)
```

## Environment knobs

| var | effect |
|---|---|
| `QUARTET_NOTIFY_CMD` | notification command `(title, body)`; unset = silent |
| `QUARTET_EVENTS_DIR` | where the JSONL event stream lands (default `data/events/` in this repo) |
| `QUARTET_OPS_JSON` | optional systemd/cron state snapshot for medic's runner scan |
| `QUARTET_SCRIBE_PRE_HOOK` | optional executable run before each scribe pass |

Set them when running `install.sh` — they're baked into the generated
systemd units (user services don't inherit your shell env).

## Event stream

Every run appends JSONL to `data/events/YYYY-MM-DD.jsonl` (override with
`QUARTET_EVENTS_DIR`): `job.start` / `job.end` with status + duration,
`medic.*` incident lifecycle, `augur.*` PR lifecycle. Build dashboards on
it, or just `jq` it.

## Using as a BopBop pack

If you run [BopBop](https://github.com/wabbazzar/bopbop), install this
repo as a context pack so your assistant can check agent health, relay
feedback to augur, and trigger runs from your phone:

```bash
bopbop pack install https://github.com/wabbazzar/guardian-quartet
```

The pack fragment teaches the assistant the read/feedback/trigger
commands; per-project installs remain explicit (`install.sh --project …`).

## Repo layout

```
agents/
├── guardian/   role.md + runner.sh
├── augur/      role.md + incident-role.md + runner.sh
├── medic/      role.md + runner.sh + check-examples/
├── scribe/     role.md + runner.sh
└── lib/        load-config.sh, post-run.sh, log_event.sh
install.sh      per-project installer (idempotent)
pack.toml       BopBop pack manifest
```

## License

MIT
