## Shipyard — autonomous repo-maintenance crew

The Shipyard pack is installed at `packs/shipyard/` in this context dir. It
provides five roles that run on systemd timers per project: **design** (turn
evidence into proposals), **build** (implement stamped work and triage
feedback), **release** (tests, audits, and cold-context critique), **medic**
(incident response), and **scribe** (documentation refresh). Unit display names
vary with the project's configured theme.

When the owner asks about their agents, projects' health, or wants to
leave feedback for a project:

- **"are the agents running / when do they fire?"** →
  `systemctl --user list-timers '<project>-*'`
- **"what happened overnight / any failures?"** → read the event stream:
  `tail -50 packs/shipyard/data/events/$(date +%F).jsonl`
  (one JSON object per line: job.start/job.end with status, medic.* incidents)
- **"tell <project> to fix/change X"** (feedback for build, not a live
  session) → append one JSON line to `<project>/data/fyi-requests.jsonl`:
  `{"ts":"<ISO8601>","id":"fyi_<stamp>","username":"<owner>","text":"<the feedback>"}`
  Build reads it on its next nightly run and opens a PR if actionable.
- **"run a role on <project> now"** → find its configured display name in the
  timer list, then `systemctl --user start <project>-<display>.service`
- **install on a new project** → the project needs `.agents/config.toml`
  (see `packs/shipyard/README.md`), then
  `bash packs/shipyard/install.sh --project <dir> [--dry-run]`

Report agent results concisely: status, project, one-line summary —
not raw JSONL.
