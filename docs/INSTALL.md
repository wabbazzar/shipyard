# Installing the crew — the six-layer model

A harness ships in layers: a generic core at the bottom, operator taste at the
top. **Installing is writing the top layers; upgrading is pulling the bottom
one.** Every layer is inspectable and revertable, and the repo keeps nothing it
didn't choose.

The `install` skill (`skills/install/SKILL.md`) drives the human-facing flow;
`install.sh` does the mechanical writes. This document is the model they both
implement.

## The layers

### L0 — core
**Where:** the harness repo, shared by every project.
**What:** runners, the shared lib, the skills, the installer — generic, with
zero personal facts (enforced by `scripts/leak-check.sh` in CI). **Scheduler
jobs execute runners from the clone, so a merge to trunk is fleet-live at the next timer
fire.** This is the only layer an upgrade touches; every project inherits it.

### L1 — hub knobs
**Where:** baked into systemd units (Linux) or LaunchAgent plists (macOS).
**What:** where events, notifications, and dashboard state flow:

```
QUARTET_NOTIFY_CMD   # the single owner-alert path (a notify wrapper)
QUARTET_OPS_JSON     # dashboard ops-state file (optional)
QUARTET_EVENTS_DIR   # append-only JSONL event stream directory
```

Jobs **bake** env; they don't read it live. Changing a knob means re-running
the installer. User scheduler jobs start with a near-empty environment, so an
unbaked knob silently mutes notifications and disables the ops scan — the
installer propagates each set knob into every job it writes.

For a local macOS fleet, use `<harness>/scripts/notify-macos.sh` as
`QUARTET_NOTIFY_CMD`; it delivers through Notification Center without an
additional service.

### L2 — theme
**Where:** `--theme` flag → `[names]` block in `.agents/config.toml`.
**What:** display names for units, svc strings, and notification voice:
`plain` (role IDs verbatim: design/build/release/medic/scribe), `spacetime`
(five themed names), or `custom:d,b,r,m,s` (five names in role order). **Role
IDs underneath never change** — they drive the agent dir, the config section,
and the event `role:` field. A legacy install with no `[names]` block keeps its
exact unit names until re-baked with a theme (the safety property: merging a
rename must not rename the running fleet).

### L3 — project config
**Where:** `.agents/config.toml`.
**What:** the gates and budgets: `can_merge` (default **no**), `allow_no_ci`
(default **no**), trunk branch, token caps (1M/day per agent — all caps are
token-based, never dollars), `test_cmd` / `typecheck`, paths. Plus the gate
file `.agents/gates.md` (test/build/lint commands, which gate classes apply,
the Traps appendix) that polish-ticket and execute-ticket read.

### L4 — roles + conventions
**Where:** `.agents/<role>.md`.
**What:** project-specific prompt extensions per crew role, and — on
`release.md` — the **`## Conventions`** block: the operator's stated taste (LOC
economy, dependency policy, naming, comment density) that the release critic
grades against. Asked for at install time; never inferred.

### L5 — skills
**Where:** `<project>/.agents/skills/` for Codex and
`<project>/.claude/skills/` for Claude/Hermes (both symlink into
`<harness>/skills/`), plus the root `AGENTS.md` bridge.
**What:** `write-ticket`, `bugfix`, `feature`, `polish-ticket`, `execute-ticket`,
`coverage-audit`, `shipyard`, `ui-design` — **the same files agents load
headless and humans invoke in-session.** The installer creates `AGENTS.md` when absent and never
changes a project-owned one; a core upgrade therefore reaches both discovery
roots without an agent-only fork. Shipyard guarantees repository-local
discovery, not registration or labeling in a host-managed/global skill-picker
UI.

The first three are the **front doors** into the design loop. `bugfix`
(reproduce-and-root-cause first) and `feature` (clarify and set a Definition of
Done first) do the intent-specific intake, then hand `write-ticket` a scope;
`write-ticket` is the requirements-gathering precursor that emits the ticket
`polish-ticket` hardens. The chain is one road — a **human** ask enters through
`bugfix`/`feature`, a **machine** ask enters as a stamped mentat proposal, and both
converge on `write-ticket → polish-ticket → execute-ticket`. Because the design
crew loads the identical symlinked `write-ticket` file a human does, a stamped
proposal drafts into a ticket the same way, no agent-only fork.

## The flow

```
recon  →  interview  →  write L2–L5  →  bake units  →  verify
```

1. **Recon first.** `coverage-audit` reads the project's session history
   (bugs the operator reported that tests missed) before anything is
   configured — those failure classes tune the release rubric and build.
   Plus a shell sweep: stack (Python vs Node), git remote + `gh auth`,
   tracked-secrets sweep, medic service surface, chat-DB shape, checked-in
   subagents.
2. **Interview.** Theme, gates, service surface, conventions, the merge/data
   forks — bring a concrete proposal, confirm only what can't be inferred.
3. **Write L2–L5.** Author `.agents/config.toml` + per-role blocks; drop
   `gates.md` (installer, from the template — never clobbering an existing
   one) and fill it in; the theme block; the conventions block.
4. **Bake jobs.** `install.sh --project <dir> --theme <t>` writes systemd units
   on Linux or LaunchAgent plists on macOS with L1 env baked in, symlinks the
   L5 skills, enables the timers, and removes legacy cron launchers.
5. **Verify.** `medic --mode scan --dry-run` loads clean, the release gates
   are green now, the scheduler reports each job loaded, and the eight skill
   symlinks resolve.

## Private local operations dashboard

The public deck in `docs/` explains Shipyard. The operations dashboard shows
private runtime events from this machine. They are separate surfaces: the
dashboard never publishes event content into the deck and never binds beyond
loopback.

Install the single native user service after the crew jobs exist:

```bash
# Preview performs no writes or scheduler calls.
scripts/install-dashboard.sh --install --dry-run

# Default: 127.0.0.1:8765. Override the port when that socket is occupied.
SHIPYARD_DASHBOARD_PORT=8766 scripts/install-dashboard.sh --install
scripts/install-dashboard.sh --doctor

# Non-interactive by default; --open is the only browser-launching path.
skills/shipyard/shipyard.sh dashboard
skills/shipyard/shipyard.sh dashboard --open
```

### Operator adapter contract

The versioned adapter surface is:

```text
GET /api/operator?window=24h
GET /api/operator?window=7d
GET /api/operator?window=30d
```

Schema v1 returns `kind: "shipyard.operator"` plus `metadata`, `brief`, `narrative`,
`promises`, `outcomes`, `graphs`, `topology`, `changes`, `attention`, `coverage`, and
`evidence`. The committed, deterministic example is
[`dashboard/tests/fixtures/operator-v1.json`](../dashboard/tests/fixtures/operator-v1.json).
It is a contract fixture, not evidence that a dashboard is installed or
running on the current machine. A downstream Ice server adapter can parse that
JSON directly; it does not import Shipyard Python and does not read event
JSONL.

Shipyard core owns semantic states, promise and KPI rules, thresholds,
priority, narrative wording, topology, limitations, and array order. Adapters
preserve those values and order exactly. `metadata.inspection_state` is
`fresh`, `stale`, or `unavailable`: stale serves the last good snapshot, and
unavailable remains unknown rather than becoming an empty healthy fleet.
Likewise, `unknown`, `partial`, `unverified`, and `not_applicable` are never
collapsed into zero or success. The maximums are 200 attention items, 500
evidence objects, and eight narrative beats; coverage reports truncation.

The additive `brief` supplies one takeaway and action, no more than four
qualified signals, and no more than eight core-grouped attention rows. Counts
always retain their unit, state, and observed/total coverage. Summary modes use
counted controls such as `Review 18 records`; only Evidence/detail renders the
opaque IDs carried by `evidence_ids`. Clients must not regroup attention,
rewrite the takeaway, or infer success from missing data.

`graphs` is the bounded, additive visualization surface. It separates fleet
architecture, each named project's runtime, unattributed evidence, and each
project's delivery lineage. Its nodes are grouped into producer-supplied Kahn
`ranks`; its exact edges are repeated in the browser's semantic connection
table. Named graphs can use only installed inspection project IDs and their
controlled installed labels. Unknown, ambiguous, or invalid event project
claims remain unattributed; event data cannot invent a project graph. A
projectless event can join an installed project only through an unambiguous
explicit run ID. Delivery edges require explicit event identifiers. The build
outcome emitter accepts an optional, bounded opaque `upstream_work_id` and
emits no result prose or file data with it. Missing correlated
ask, ticket, pull-request, deploy, or usage evidence is shown as a controlled
gap, never filled from timestamp adjacency, titles, paths, or prose. The legacy
`topology` member remains available for schema-v1 readers.

An open branch or pull request is not automatically live in the installed
dashboard. Check `metadata.source_revision`, `source_state`, and
`source_digest` against the intended checkout. Producer changes take effect
only when that checkout is installed and the dashboard service is restarted;
the running server reports later on-disk drift as modified rather than silently
claiming the new revision.

Compatibility within schema v1 is additive. Readers ignore unknown object
members, retain supplied array order, and display an unrecognized enum as
unknown/unavailable. Removing or retyping a member, changing its meaning, or
reassigning a stable promise ID requires a new schema version. No adapter
payload may contain filesystem paths, prompts, messages, diffs, filenames,
result bodies, or critique prose.

The dashboard is loopback-only, read-only, and emits no CORS allowance. Its
browser uses same-origin requests. Another local product must fetch the
loopback endpoint from its server side and project the returned contract; it
must not embed the dashboard, expose the endpoint remotely, or parse raw
history as a competing source of operator meaning. To keep the service bounded,
the in-memory index skips canonical daily files older than the largest
supported 30-day window; the files remain untouched on disk.

The installer writes exactly one service:

| Platform | Definition | Event fallback | Logs |
|---|---|---|---|
| macOS | `~/Library/LaunchAgents/com.shipyard.dashboard.plist` | `~/Library/Application Support/Shipyard/events/` | `~/Library/Logs/Shipyard/dashboard.log` and `dashboard.err.log` |
| Linux | `${XDG_CONFIG_HOME:-~/.config}/systemd/user/shipyard-dashboard.service` | `${XDG_STATE_HOME:-~/.local/state}/shipyard/events/` | `${XDG_STATE_HOME:-~/.local/state}/shipyard/logs/dashboard.log` and `dashboard.err.log` |

Event-path precedence is deliberate: explicit `--events-dir`, then
`QUARTET_EVENTS_DIR`, then one unambiguous path already baked into crew
manifests, then the existing dashboard manifest, then the clean-install
fallback above. This preserves current history. The installer never copies,
moves, rewrites, or deletes JSONL files. If crew jobs need a different path,
re-run the project installer with the new `QUARTET_EVENTS_DIR` so those jobs
are rebaked, then run the dashboard installer with the same explicit path.
Moving old history remains a separate manual owner decision.

`--doctor` is read-only and detects an absent/stopped service, a wrong host,
port, or event directory, and source/asset version drift. Reinstall is
byte-stable. Uninstall removes only the dashboard service and deliberately
leaves events and logs:

```bash
scripts/install-dashboard.sh --uninstall --dry-run
scripts/install-dashboard.sh --uninstall
```

The server accepts only loopback/localhost `Host`, emits no CORS allowance,
and exposes read-only health, summary, event, and live-stream endpoints. It is
not an authenticated LAN, tailnet, or public service. Notification Center
remains the actionable/urgent attention path. A future Slack or BopBop adapter
may sit downstream of classified notifications; it must not replace the local
append-only event history.

## Opt-in Git identity

A project may track only its non-sensitive identity policy at
`.shipyard-git-identity.toml`:

```toml
[git_identity]
enforce = true
name = "your-github-user"
```

Keep the email outside tracked files. After setting the intended effective
`user.name` and `user.email`, configure and verify the repository-local keys:

```bash
install.sh --configure-git-identity --project <project_dir>
```

This enables `.githooks`, stores the canonical email in local Git config, and
prints only a redacted marker. CI obtains the same value only from the
`SHIPYARD_IDENTITY_EMAIL` repository secret.

## Doctor — audit what an install owns

`install.sh` can report drift in a crew install without changing anything:

```bash
install.sh --doctor --project <project_dir>
```

It rebuilds the expected manifest from the project's own config (the same
inputs install uses) and checks it against reality, one `DOCTOR <class>:
<detail>` line per finding (exit 0 clean, 1 on any drift):

| class | catches |
|-------|---------|
| a | an expected role's scheduler job missing, disabled, or pointing outside `$QUARTET_DIR` |
| b | a stale duplicate — more than one job running the same role runner |
| c | Linux only: a foreign `<crew-unit>.service.d/` drop-in — flagged, never removed |
| d | retired config keys/sections (USD-era budget decimals, retired vocabulary) |
| e | a shared-skill symlink missing or not resolving into `$QUARTET_DIR/skills` |
| f | a `.claude/settings.json` hook command naming a script that does not exist (dead wiring) |
| g | legacy per-project launcher scripts / crontab lines |
| h | (hub only) a dispatch decision in `data/news/decisions.jsonl` not mirrored into the target project's `data/decisions.jsonl` |
| i | (opt-in only — flagged only once a project has enabled shoulder mode) the capture hook not wired into the authoring harness's native config, or `.agents/shoulder.env` missing; fix with `install.sh --wire-shoulder` |
| identity | (opt-in only) tracked name, repository-local name/email policy, or `core.hooksPath=.githooks` missing or mismatched |

It is strictly read-only (no writes or scheduler mutation) and finishes in
well under a second, so it runs as a `[[medic.checks]]` entry every scan —
the next self-written drop-in or dead hook pages within one tick instead of
surfacing weeks later.

## Repair (relink)

Doctor is read-only, so a missing skill symlink (class `e`) otherwise waits for
a manual reinstall. Recreating a symlink is a deterministic, reversible
filesystem op — not a code change — so `--relink` repairs exactly that drift
class and nothing else:

```bash
install.sh --relink --project <project_dir> [--dry-run]
```

It recreates only the installer-owned skill symlinks that resolve wrong
(missing, broken, or pointing outside `$QUARTET_DIR/skills`), leaves correct
ones untouched, and **never** clobbers a real file/dir an operator placed
there. It touches nothing else — no scheduler, config, or gate file — and
exits 0 even when nothing needed fixing. `--dry-run` prints the plan without
writing.

## Uninstall

Remove exactly the installer-owned surface (scheduler jobs + shared-skill
symlinks); the config you wrote and your data are left in place:

```bash
install.sh --uninstall --project <project_dir> [--dry-run]
```

It disables + removes this project's systemd units or LaunchAgent plists,
removes the shared skill symlinks that resolve into `$QUARTET_DIR/skills`
(a real dir or a symlink pointing elsewhere is left untouched), and prints
the deliberate leave-behind: `.agents/` (config, prompts, gates.md), `data/`,
`tmp/`. `--dry-run` prints the identical plan without writing.

Reinstall is `install.sh --project <dir>` again — **uninstall + install
converges to a fresh install's job set.** The repo keeps nothing it didn't
choose — the crew leaves no code behind, only the config the operator wrote
and can read.
