# Operating Shipyard

This guide is the operational reference for an installed crew. Installation,
repair, and scheduler lifecycle are in [INSTALL.md](INSTALL.md); role design
is in [ARCHITECTURE.md](ARCHITECTURE.md).

## Safety defaults

Start with a human reviewer and a low-stakes project. The controls below are
the important defaults to preserve.

| Control | Configuration | Default |
|---|---|---|
| PR reviewer | `project_owner` | required |
| Self-merge | `[medic] can_merge` | `false` |
| Merge with no CI | `[build] allow_no_ci` | `false` |
| Protected paths | `[build] forbidden_paths` | `[]` |
| Rules-memory review | `[memory]` | off |
| Shoulder stop gate | `CRITIC_BLOCK=1` | disarmed |
| Per-consumer token caps | role budget settings | 1M tokens/day |

Use `install.sh --dry-run` before any install change and
`install.sh --doctor --project <dir>` to audit the installed surface without
writing. The doctor recognizes intentionally disabled roles and reports only
actual drift. See [INSTALL.md](INSTALL.md) for its finding classes and repair
options.

## Fleet inspection

`shipyard inspect [--json] [--days N]` is a strictly read-only, bounded view
of matching current-user manifests into the current Shipyard core. It does not
certify fleet health: missing or malformed sources, snapshot limits, and
recommendations remain bounded by evidence and reported limitations. Its JSON
is stable schema-v1 output; its normal console is for human review.

The inspection reports six independently enforced daily consumers—Design,
Build, Release runner, Release shoulder critic, Medic, and Scribe—without
collapsing their token gates. A multi-project Design or shoulder budget
recommendation needs exact manifests proving one resolved unscoped gate root;
it never infers an unknown shoulder root.

## Probes and release checks

Medic can watch HTTP endpoints and deterministic drift checks:

```toml
[[medic.probes]]
name = "api"
url = "https://api.example.com/api/auth/me"
expect_status = 401
timeout_sec = 10

[[medic.checks]]
name = "deployment-drift"
cmd = "scripts/medic-checks/deployment-drift.sh"
timeout_sec = 30
restart_unit = "myproject-deploy.timer" # optional and whitelisted
```

Failed drift checks become `infra` incidents, or `restart` incidents when the
unit is permitted; they are not silently treated as code regressions. Starter
checks live in `agents/medic/check-examples/`.

Release can opt into its daily dependency, header, and recent-secret sweep via
`[release.security]`. A blocking gate and `verify_gate` can require the real
test/typecheck commands after the model verdict. The exact role behavior and
config semantics are in [the Release role](../agents/release/role.md).

## Notifications and environment variables

Scheduler jobs receive a deliberately small environment. The installer bakes
the notification command, event directory, and optional ops snapshot into
each generated job; rerun it after changing one.

`QUARTET_*` is a legacy compatibility prefix, not the product name. These are
the currently supported variable names and must remain unchanged until a
separate compatibility migration is implemented.

| Variable | Purpose |
|---|---|
| `QUARTET_NOTIFY_CMD` | command accepting `(title, body)` for owner alerts; unset is silent |
| `QUARTET_EVENTS_DIR` | JSONL event directory |
| `QUARTET_OPS_JSON` | optional operations-state snapshot |
| `SHIPYARD_DASHBOARD_PORT` | loopback dashboard port; default `8765` |
| `QUARTET_SCRIBE_PRE_HOOK` | optional executable before a Scribe pass |
| `CODE_ROOT` | root scanned by the fleet overseer; default `~/code` |
| `OVERSEER_HARNESS`, `OVERSEER_MODEL`, `OVERSEER_WALL_CLOCK` | fleet-overseer judge selection and cap |
| `SPAWN_STALL_RETRIES`, `SPAWN_STALL_BACKOFF` | transient model-stall retry policy |

Shoulder-mode delivery uses `CLAUDE_NOTE_CMD`, `CRITIC_NOTE_HARNESS`,
`CRITIC_NOTE_DELIVER_CMD`, and, for Hermes, `CRITIC_NOTE_TARGET`. Wiring it is
additive and opt-in: `install.sh --wire-shoulder`. See
[shoulder mode](shoulder-mode.md#knobs) for delivery exits, retry behavior,
and the stop gate.

Set the notification threshold in the project config:

```toml
[notify]
signal_level = "actionable"
```

The order is `routine < actionable < urgent`. Valid policies are `all`,
`actionable`, `urgent`, and `off`; an unset or invalid value preserves alert
delivery rather than hiding an urgent notification. When sending through
Signal’s styled mode, escape a bare `~` in generated prose.

## Event history and dashboard

Events append to daily JSONL files. They record starts and finishes, Design
proposals, Medic incident lifecycle, and Release critiques. The optional
dashboard is a separate private, read-only loopback service over that history;
it has no cloud transport or database.

```bash
scripts/install-dashboard.sh --install --dry-run
scripts/install-dashboard.sh --install
shipyard dashboard
```

The dashboard API, schema compatibility, renderer ownership, lifecycle, and
adapter rules belong to [dashboard/README.md](../dashboard/README.md). Do not
rebuild its view from raw JSONL in another client.

## Stopping or removing a crew

Disable the relevant user timer or LaunchAgent when immediate shutdown is
needed. For a normal removal, use:

```bash
install.sh --uninstall --project <project_dir> [--dry-run]
```

Uninstall removes installer-owned jobs and shared-skill symlinks only. It
leaves the project’s `.agents/` configuration, gates, data, and temporary
artifacts intact.
