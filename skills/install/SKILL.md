---
name: install
description: >
  Install the crew (design/build/release/medic/scribe) on a project. Use
  when the user says "install the crew (or
  crew) on <project>", "set up the agents on <project>", "add the crew
  to <project>", or "wire <project> into the fleet". Drives the whole flow from
  the operator's hub: recon (via coverage-audit), the install-time interview
  (including --theme and a conventions interview), authors <project>/.agents/,
  ensures preconditions (git remote, clean tree, data handling), runs the
  harness install.sh with the hub env knobs, symlinks the shared skills into
  <project>/.claude/skills/, and verifies the timers. Installs the four
  standard roles by default (design is opt-in); pass --agents for a subset.
---

# install — install the crew on a project

The crew is **hub-and-spoke**, not per-project-self-contained. The brains
(generic runners + role.md prompts), the shared skills, and the installer live
in the harness repo (public; `agents/` + `skills/` + `install.sh`). The
scheduler is user-instance systemd (`~/.config/systemd/user/<project>-<display>.{service,timer}`).
The only per-project footprint is a thin `<project>/.agents/` (config.toml +
per-role prompt blocks + gates.md) and the symlinked `<project>/.claude/skills/`.
**Always drive the install from the operator's hub, pointing the installer at
`--project <dir>` — never from a standalone `claude` session inside the target,
which has neither the installer nor the generic agents.**

Hub installs set three env knobs so the units know where to route events,
notifications, and dashboard state (baked into the units at install time —
changing them means re-running the installer):

```
QUARTET_NOTIFY_CMD=<hub>/scripts/notify.sh          # the single owner-alert path
QUARTET_OPS_JSON=<hub>/dashboard/.../ops.json       # dashboard ops state (optional)
QUARTET_EVENTS_DIR=<hub>/data/events                # append-only JSONL event stream
```

Legacy env knobs of the same name are accepted; there is no rename. (See the
deprecation note at the end for legacy config *keys*.)

This skill is the playbook. Run it in order; do not skip the questions or the
safety sweep.

## When to invoke

"install the crew on <project>", "set up the agents on <project>",
"add the crew to <project>", "wire <project> into the fleet".

If the user only wants to know *what to configure* (not install yet), that's
the sibling skill **coverage-audit** — run that and stop.

---

## Step 0 — Recon (never skip)

1. Run **coverage-audit** against the project. It reads the project's Claude
   Code session transcripts for bugs the user reported that tests missed.
   Those failure classes are what you tune the release critic and build for.
   (No transcripts ⇒ note it, proceed with code-only recon.)
2. Map the surface with shell, not assumptions:
   - **Stack**: Python (`pytest.ini`, `.venv/`, `requirements*.txt`) vs Node
     (`package.json`, `vitest`, `svelte-check`). This decides
     `[release].test_cmd` / `typecheck` (see Step 3). **Do not** let a Node
     reference install bias a Python project toward `npx vitest`/`tsc`.
   - **Git remote**: `git -C <dir> remote -v`. Build REQUIRES `origin` + `gh`
     (it does `git push origin`, `gh pr create/merge`). No remote ⇒ Step 5.
   - **`gh auth status`** — build and the remote-create step need it.
   - **Tracked data/secrets**: `git -C <dir> ls-files | grep -iE
     '\.csv$|\.xlsx$|\.db$|\.env$|secret'`. Anything here ships to the remote
     on push — Step 5 data question.
   - **Service surface for medic**: is there a live URL? a health endpoint?
     are the services `systemctl --user` (medic can bounce) or **system**
     units needing sudo (needs `[medic].restart_cmd`, see Step 4)?
   - **Doc surface for scribe**: `CLAUDE.md`, `README.md`, `docs/`.
   - **Chat DB schema** (if any): medic's built-in scanner expects a
     `chat_messages` table with `user_id`. A differently-named/shaped table
     ⇒ leave `[paths].db` unset (the scan would be a no-op) and let build mine
     it via its prompt instead.
   - **Checked-in subagents**: `ls <dir>/.claude/agents/*.md`. If present,
     build a "delegate to specialists" table in `<project>/.agents/build.md`
     and bump `[build].budget_incident`.

## Step 1 — The install-time interview

Bring a **concrete proposal** (informed by Step 0), then confirm the knobs you
can't infer. The genuinely project-specific forks:

| Question | Wires to |
|---|---|
| **`--theme`** — display names for units/svc/notification voice: `plain` (role IDs verbatim), `spacetime` (five themed names), or `custom:d,b,r,m,s`. Role IDs underneath never change. | `[names]` block in config.toml (`--theme` flag) |
| **Conventions** — the operator's stated taste the release critic grades against: LOC economy, dependency policy (new deps need justification?), naming, comment density. Ask explicitly; taste is not inferable. | `## Conventions` block in `.agents/release.md` |
| What feeds **build's** "what to fix" queue? (a `/fyi` jsonl, the in-app chat DB, telemetry error events) | `[build].fyi_log` + build.md intake section |
| May build autonomously edit the **security/auth path**, or test-only + human-fix? | `[build].forbidden_paths` + build.md guardrails |
| On a failed liveness probe, may **medic** auto-restart prod, or alert-only? | `[medic].restart_systemd` + `[medic].restart_cmd` |
| Can this project's **live state drift from repo HEAD** (deploy pipeline / manual restarts)? If yes, define `[[medic.checks]]` — each a bash cmd that exits nonzero on drift, run every scan tick | `[[medic.checks]]` + per-check cues in medic.md |
| Does build **auto-merge** or do you merge by hand? (default **no** — opt-in) | `[medic].can_merge` |
| **Data handling** if datasets are tracked: untrack+push-code-only, or push data to a private repo? | Step 5 |
| Timer window — overnight for noisy agents; **medic 24/7** if client-facing | `[install.timers]` |

State defaults you're locking (test_cmd, scribe scope, `can_merge=false`,
`allow_no_ci=false`) so the user only adjudicates real forks. Don't ask things
you can read from the repo.

## Step 2 — Author `<project>/.agents/`

Write `config.toml` + the per-role prompt blocks (`release.md`, `build.md`,
`medic.md`, `scribe.md`, and `design.md` if design is installed). Give
`release.md` a **`## Conventions`** block from the Step-1 interview — the stated
taste the critic grades against (never generic taste). **Validate config parses
before going further:**

```bash
source <harness>/agents/lib/load-config.sh
load_config_json <dir>/.agents/config.toml | jq .
```

Config keys the runners actually read (canonical role IDs; don't invent
others): `project_name, project_dir, project_owner, branch, dev_port`;
`[names]`; `[install.timers]`; `[paths].{result_dir,worktree_dir,db}`;
`[release].{test_cmd,typecheck,budget_hook,budget_daily,is_pwa,...}`;
`[build].{in_scope_paths,forbidden_paths,fyi_log,budget,budget_incident,wall_clock_sec,allow_no_ci}`;
`[medic].{poll_interval_sec,sync_to_build,daily_escalation_cap,restart_systemd,restart_cmd,can_merge,probes[],checks[]}`;
`[scribe].{content_paths,budget,wall_clock_sec,commit_message_prefix,auto_commit,auto_push,...}`.

The installer also drops `skills/gates.md.template` → `<project>/.agents/gates.md`
if absent (never clobbering an existing one). **Fill it in**: the project's
test/build/lint commands, which gate classes apply, and leave the Traps
appendix empty. polish-ticket / execute-ticket read this file.

## Step 3 — Stack-correct release gates (the #1 portability trap)

`[release].typecheck` defaults to `npx tsc --noEmit` and `test_cmd` to
`npx vitest run` IF UNSET — these run verbatim in **post-merge** mode
(`eval`'d, deterministic, no Claude). On a Python project an unset typecheck
silently runs `npx tsc` and fails every post-merge check. So **always set
both explicitly**:

- Python: `test_cmd = ".venv/bin/python -m pytest -q"`,
  `typecheck = ".venv/bin/python -m py_compile <core modules>"` (no mypy ⇒ a
  byte-compile smoke; never leave it unset).
- Node: the vitest/svelte-check pair.

Confirm both are **green right now** before declaring done (Step 7) so the
first nightly release run doesn't false-alarm into a medic→build escalation.

## Step 4 — Medic restart authority

- Services are `systemctl --user` ⇒ medic's built-in `restart` path bounces
  the failed unit; just set `restart_systemd = true`.
- Services are **system** units (sudo) or live behind a URL with no local
  user-unit ⇒ set `[medic].restart_cmd` to a project command. Keep the
  privileged step in a **gitignored** helper (e.g. `deploy/restart-prod.sh`)
  so the secret-handling never lands in the committed/pushed config; point
  restart_cmd at it. medic runs it from PROJECT_DIR on a restart-class probe
  incident, notifies, then applies a one-per-UTC-day cooldown.

## Step 4.5 — Medic drift checks (`[[medic.checks]]`)

If the Step 1 drift question was a yes — the project's live state can lag
repo HEAD because deploys are gated/manual — wire `[[medic.checks]]`. Each
entry is a bash cmd the runner executes from `project_dir` every scan tick;
nonzero exit synthesizes a `source == "check"` incident whose evidence quotes
the cmd's stdout verbatim (write the drift message there):

```toml
[[medic.checks]]
name        = "server-restart-drift"
cmd         = "scripts/medic-checks/server-restart-drift.sh"
timeout_sec = 30
```

Keep checks as small standalone scripts, not TOML one-liners — they're testable
by hand. Pair each check with a classification cue in `medic.md` (`notify` vs
`restart` against a whitelisted unit); default is notify. See
`agents/medic/check-examples/` for two worked examples (restart-drift and
frontend-deploy-drift).

## Step 5 — Ensure a remote + clean tree (build preconditions)

Build aborts unless the trunk checkout is **clean** and `origin/<branch>`
exists.

- **Untracked files** (`.claude/`, stray dirs) ⇒ gitignore or commit them.
- **Tracked datasets/secrets** ⇒ per the Step 1 data answer. Default safe
  path: `git rm --cached data/*.csv data/*.xlsx` + gitignore (files stay on
  disk), then **wire the build/release worktrees to symlink the local data**
  (worktrees are checked out from origin and won't have gitignored files;
  tests that read `data/` fail there without the symlink — put
  `ln -sfn <abs>/data data` in build.md's "do this first").
- **No remote** ⇒ after the tree is clean and datasets handled:
  `gh repo create <owner>/<project> --private --source <dir> --remote origin --push`.
  Before this: `git ls-files | grep -iE '\.csv|\.xlsx|\.db|\.env'` must be
  EMPTY. Pushing data to a third party is hard to reverse — confirm with the
  user first (Step 1 data question).

## Step 6 — Install + verify

```bash
QUARTET_NOTIFY_CMD=<hub>/scripts/notify.sh \
QUARTET_OPS_JSON=<hub>/.../ops.json \
QUARTET_EVENTS_DIR=<hub>/data/events \
  bash <harness>/install.sh --project <dir> --theme <theme> --dry-run   # preview
# …then drop --dry-run for the real run.
```

The installer is idempotent. It: writes the systemd units (schedules from
`[install.timers]`), bakes the `--theme` `[names]` block, enables the timers,
removes legacy `<project>-<agent>.sh` cron/launchers, **symlinks
`skills/{polish-ticket,execute-ticket,coverage-audit}` → `<project>/.claude/skills/`**
so agents (headless) and humans (in-session) load the identical files, **drops
`gates.md.template` → `<project>/.agents/gates.md` if absent**, and verifies.
Subset with `--agents build,release,medic` (role IDs only).

## Step 7 — Smoke-verify before declaring done

- `medic --mode scan --dry-run` ⇒ confirm probes fire and config loads
  (healthy ⇒ "no incidents; exiting clean").
- `restart_cmd` helper: `bash -n` it and confirm the privileged step is
  readable — do NOT actually restart prod to "test".
- Release gates green (Step 3).
- `systemctl --user list-timers '<project>-*'` shows sane next-fire times.
- `ls -l <project>/.claude/skills/` shows the three skill symlinks resolving.

Commit `<project>/.agents/` (config + role blocks + gates.md) in the project
repo and push. Any shared-runner changes get their own commit in the harness
repo (stage explicitly; never sweep up unrelated dirty files).

## Deprecation note — legacy names & keys

- **Env knobs** `QUARTET_NOTIFY_CMD` / `QUARTET_OPS_JSON` / `QUARTET_EVENTS_DIR`
  are current, not deprecated — keep setting them.
- **Role tokens** in `--agents` are the canonical role IDs only
  (`design,build,release,medic,scribe`) — the previous generation's
  display-name tokens are retired and no longer mapped.
- **Config keys** are canonical only (`[build]`/`[release]` sections,
  `[medic].can_merge`); the legacy section/key compat layer is retired —
  migrate any old config before re-installing.
- Installs with no `[names]` block get unit names from the role IDs.
  Renaming a running fleet's units (re-baking with `--theme`) is a
  deliberate, supervised step — merging a rename must never silently
  rename live units.

## Constraints / honesty

- **Never push data to a remote without an explicit yes.** Sweep
  `git ls-files` first.
- **Never leave `[release].typecheck` unset on a non-Node project.**
- **Never edit a security/auth path into build's in_scope without the user
  saying so.**
- **Surface gaps, don't paper over them.** If the generic runner can't do
  what the user approved (e.g. build needs a remote it doesn't have), say so
  and fix the precondition — don't install something that silently no-ops.
