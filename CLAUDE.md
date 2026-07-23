# shipyard — working notes for Claude

Public repo (`git@github.com:wabbazzar/shipyard.git`, trunk `main`). It ships a
crew of five autonomous agents — each a headless `claude` invocation on a
systemd user timer — that design, build, release, repair, and document *other*
repos. This repo is the **implementation**; it holds no project state.

Read `README.md` first for the product-level story. This file covers the things
that are only obvious after breaking something.

## Canonical model

Five **role ids** — `design build release medic scribe` — are the stable
identity: agent dir `agents/<role>/`, config section `[<role>]`, project prompt
`.agents/<role>.md`, event field `role:`. **Display names** (systemd unit names,
notification voice) come from the project config's `[names]` block, baked at
install time by `--theme plain|spacetime|custom:d,b,r,m,s`. No `[names]` block →
display == role id.

Never reintroduce the retired vocabulary (`quartet` as a role word, `augur`,
`guardian` as config sections/dirs). The `QUARTET_*` env vars and `QUARTET_DIR`
are the one intentional exception — they are the stable env contract baked into
every generated unit.

`agents/lib/naming.sh` owns role→display/dir resolution. Use it; do not
hand-roll name mapping.

## Layout

```
agents/<role>/runner.sh   the entry point each systemd unit calls
agents/<role>/role.md     generic prompt; project appends .agents/<role>.md
agents/lib/               load-config.sh naming.sh post-run.sh log_event.sh
                          revert-merge.sh detect-trunk.sh mentat-proposal.sh
agents/release/critic-*   shoulder mode (queue → watch → cold critique)
skills/                   six shared skills + install skill + gates template
install.sh                per-project installer / --doctor / --uninstall
scripts/                  leak-check, deck generator + freshness/render gates
tests/                    bats suite (138 tests, ~17s)
docs/                     INSTALL.md, ADAPTING.md, shoulder-mode.md, the deck
```

## Gates — run these before claiming anything works

```bash
bats tests/                      # full suite, ~17s, no network/LLM (PATH shims)
bash scripts/leak-check.sh       # no owner/machine-specific data (also a pre-commit hook)
bash scripts/check-deck-fresh.sh # docs/shipyard-data.json regenerates byte-identical
bash -n install.sh agents/lib/*.sh agents/*/runner.sh   # syntax
node scripts/check-deck-render.mjs   # optional; exit 3 = playwright absent, not a failure
```

CI (`.github/workflows/checks.yml`) runs leak-check, `bash -n` + `py_compile`,
deck-fresh, and bats on push to main and every PR. `core.hooksPath=.githooks`
is set locally, so leak-check blocks commits with a home path, private email,
or key-shaped string. If you need a literal example of a forbidden pattern, end
the line with the `leak-allow` marker rather than weakening the regex.

**Deck coupling:** `docs/shipyard-data.json` is *generated* from skill
frontmatter (`roles:`, `kind:`) + `install.sh`'s `GENERIC_SKILLS` line +
`docs/deck-editorial.json`. Touch a SKILL.md's frontmatter or the skill list and
you must `python3 scripts/gen-deck-data.py` and commit the regenerated JSON.
Prose edits go in `deck-editorial.json`, never in the generated file.

**Test convention:** new behavior lands with a bats case shown failing against
the pre-change code first. `tests/helpers.bash` gives you a PATH shim
(`make_stub`) so no test ever reaches GitHub, the network, or a model, plus
`make_fixture_project` / `make_git_topology` / `run_runner`.

## Runner conventions

- `set -uo pipefail`; resolve `QUARTET_DIR` from `BASH_SOURCE` with an env
  override; argv parsed with an explicit `while`/`case`; unknown arg → exit 2.
- Config: `source agents/lib/load-config.sh`, `load_config_json` → JSON, then
  `jq`. Parses TOML via python3 `tomllib` (3.11+).
- Every run emits `job.start`/`job.end` JSONL via `agents/lib/log_event.sh`;
  `post-run.sh` is the trailer (job.end + medic escalation on failure).
- Exit codes are load-bearing: `2` = bad invocation/config, `3` = deliberate
  no-op (e.g. `build --mode incident`, critic delivery not-delivered).
- Never call bare `claude -p` — a bats case (`tests/token-caps.bats`) asserts
  every invocation carries a wall-clock timeout and a token cap.
- Generated units inherit nothing from the shell, so any new env knob must be
  baked into the unit by `install.sh` *and* documented in the README table.

## Safety posture

These agents run `claude --dangerously-skip-permissions`, unattended, with
commit and PR rights. Defaults must stay conservative: `[medic] can_merge`,
`[build] allow_no_ci`, and `[build] ticket_mode` are all **false**; design is
opt-in in `--agents`; medic never auto-fixes a `regression` — it writes an
incident-repair proposal that waits for the same human stamp. When adding a
capability, ship it behind a config key whose unset value is exactly today's
behavior, and prove that with a test.

## How it's installed on this machine

Checkout lives at `~/code/shipyard`; units point directly at it, so **an edit
here is live for every project on the next timer fire**. There is no per-project
copy of the runners.

Installed projects (all `--theme spacetime`, so units are
`<project>-{mentat,helldiver,proctor,suk,chronicler}`): `aurora`, `bopthere`,
`shredly`, `starbird`, `2pizzaclub` (scribe only), `ice`
(`~/code/wabbazzar-ice`, scribe only). Config for each is
`<project>/.agents/config.toml`.

Every unit is generated with the same env block pointing back at the ice repo:
`QUARTET_NOTIFY_CMD=~/code/wabbazzar-ice/scripts/notify.sh`,
`QUARTET_EVENTS_DIR=~/code/wabbazzar-ice/data/events`,
`QUARTET_OPS_JSON=~/code/wabbazzar-ice/dashboard/src/content/ops.json`. So the
**live event stream is `~/code/wabbazzar-ice/data/events/YYYY-MM-DD.jsonl`**,
not `data/events/` in this repo (that dir only has stale local test output and
is gitignored). Shoulder-mode critics run as long-lived
`<project>-proctor-watch.service` units with
`CLAUDE_NOTE_CMD=~/code/wabbazzar-ice/scripts/critic-note.sh <project>`.

Useful:

```bash
systemctl --user list-timers '<project>-*'
./install.sh --doctor --project ~/code/<project>       # read-only drift audit, <1s
./install.sh --project ~/code/<project> --dry-run      # inspect before writing
systemctl --user start <project>-<display>.service     # run one crew now
tail -50 ~/code/wabbazzar-ice/data/events/$(date +%F).jsonl | jq .
```

`ice` also runs `--doctor` as a `[[medic.checks]]` entry, so install drift on
that project surfaces as a notify-only incident.

Day-to-day fleet operation is usually driven from the `~/code/wabbazzar-ice`
session (that repo is the owner's hub: notifications, dashboard, event store,
ticket queue). Work *on the agents themselves* happens here.

## CLAUDE.fragment.md

Not read by Claude Code. It is the **BopBop pack fragment** declared in
`pack.toml` (`fragment = "CLAUDE.fragment.md"`): when this repo is installed as
a context pack (`bopbop pack install …`), BopBop splices that file into the
consuming assistant's context. It is written for the *operator's* assistant —
"how do I check whether the agents ran, leave feedback, trigger a run" — not for
someone editing this repo. Keep it short, operator-voiced, and current with the
commands it names; note it still uses the older `packs/guardian-quartet/` path
and quartet vocabulary and is due a refresh.
