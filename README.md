# shipyard

Shipyard installs a small autonomous engineering crew on a repository. The
crew turns evidence and human decisions into scoped changes, checks those
changes cold, and watches the installed system between runs.

It supports Linux user `systemd` and macOS `launchd`, with Claude Code by
default and optional Codex or Hermes harnesses.

## What the crew does

| Role | Cadence | Responsibility |
|---|---:|---|
| Design | nightly | turns usage, feedback, and incidents into at most three evidence-backed proposals for human approval |
| Build | nightly | turns approved work and small feedback items into reviewable changes |
| Release | daily + on edit | runs the configured verification battery and offers a cold-context shoulder critique |
| Medic | every 10 min | detects incidents, performs bounded mitigation, and routes regressions back to design |
| Scribe | daily | refreshes configured content and keeps ticket lifecycle folders consistent |

The normal path is:

```text
evidence or human ask → ticket → hardened plan → verified change → review
```

Humans can start that path with `/feature` or `/bugfix`. Design proposals wait
for an explicit human stamp. See the full [architecture](docs/ARCHITECTURE.md)
for role boundaries, the approval loop, and optional overseer and specialist
components.

## Start safely

These agents can run unattended and may have commit or PR permissions. Begin
with a low-stakes repository, keep `project_owner` set, and inspect every
installer write before accepting it.

```bash
# Prerequisites: Claude Code, jq, Python 3.11+, authenticated gh, and git.
# macOS also needs: brew install coreutils jq

/bin/bash ./install.sh --project /path/to/project --dry-run
/bin/bash ./install.sh --project /path/to/project --theme spacetime
install.sh --doctor --project /path/to/project
```

The minimal project configuration is:

```toml
project_name  = "myproject"
project_owner = "your-github-user"

[release]
test_cmd  = "npx vitest run"
typecheck = "npx tsc --noEmit"

[build]
allow_no_ci = false

[medic]
can_merge = false
```

The installer is idempotent. It writes only the scheduler jobs and symlinks it
owns; your project configuration, prompts, data, and gates stay project-owned.
For the full six-layer model, configuration reference, repair, and uninstall
behavior, read [the installation guide](docs/INSTALL.md).

## Operate it

- Run `shipyard status` from an installed project to inspect jobs and drift.
- Run `shipyard dashboard` for the private, loopback-only operations view.
- Use `install.sh --doctor --project <dir>` for a read-only install audit.
- Keep the shoulder critic opt-in: `install.sh --wire-shoulder`.

The [operations guide](docs/OPERATIONS.md) covers safety controls, probes,
notifications, environment compatibility names, and release security. The
[dashboard guide](dashboard/README.md) owns the renderer and schema contract.

## Documentation

| Need | Read |
|---|---|
| Install, configure, repair, or remove a crew | [Installation guide](docs/INSTALL.md) |
| Understand roles, approval, extensions, and telemetry | [Architecture](docs/ARCHITECTURE.md) |
| Configure safety, alerts, liveness checks, or security | [Operations](docs/OPERATIONS.md) |
| Enable the edit-time cold critique | [Shoulder mode](docs/shoulder-mode.md) |
| Adapt the crew or use rules memory | [Adapting the crew](docs/ADAPTING.md) |
| Integrate the private operator dashboard | [Dashboard guide](dashboard/README.md) |
| See the fixed five-day fleet-trial result | [Trial findings](docs/tickets/pending/close-five-day-trial-findings.md) |
| Maintain Shipyard itself, its deck, or its pack | [Contributor notes](docs/CONTRIBUTING.md) |

## Repository map

```text
agents/     role prompts, runners, and shared shell library
skills/     project-installable workflow skills
dashboard/  private read-only operator dashboard
docs/       operator, architecture, and contributor documentation
scripts/    installation, validation, and maintenance tools
tests/      automated coverage
```

Shipyard can also be installed as a [BopBop](https://github.com/wabbazzar/bopbop)
context pack:

```bash
bopbop pack install https://github.com/wabbazzar/shipyard
```

Per-project crew installation remains explicit.

## License

MIT
