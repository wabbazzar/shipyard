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
project_dir   = "/home/user/code/myproject"   # leak-allow (placeholder)
project_owner = "your-github-user"            # PR reviewer — required
branch        = "main"

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

## Notifications

Transport-agnostic. Set `QUARTET_NOTIFY_CMD` to any command that takes
`(title, body)` as two arguments — a Signal wrapper, `ntfy`, Pushover,
email. Unset = silent (events are still logged).

```bash
QUARTET_NOTIFY_CMD="/home/user/bin/notify" ./install.sh --project …  # leak-allow (placeholder)
```

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
├── medic/      role.md + runner.sh
├── scribe/     role.md + runner.sh
└── lib/        load-config.sh, post-run.sh, log_event.sh
install.sh      per-project installer (idempotent)
pack.toml       BopBop pack manifest
```

## License

MIT
