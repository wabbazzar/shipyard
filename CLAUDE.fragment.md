## Guardian Quartet — autonomous repo-maintenance agents

The guardian-quartet pack is installed at `packs/guardian-quartet/` in this
context dir. It provides four agents that run on systemd timers per
project: **guardian** (daily tests + audits + fixes), **augur** (nightly
user-feedback triage → autonomous PRs), **medic** (failure-triggered
triage), **scribe** (daily doc refresh).

When the owner asks about their agents, projects' health, or wants to
leave feedback for a project:

- **"are the agents running / when do they fire?"** →
  `systemctl --user list-timers '<project>-*'`
- **"what happened overnight / any failures?"** → read the event stream:
  `tail -50 packs/guardian-quartet/data/events/$(date +%F).jsonl`
  (one JSON object per line: job.start/job.end with status, medic.* incidents)
- **"tell <project> to fix/change X"** (feedback for augur, not a live
  session) → append one JSON line to `<project>/data/fyi-requests.jsonl`:
  `{"ts":"<ISO8601>","id":"fyi_<stamp>","username":"<owner>","text":"<the feedback>"}`
  Augur reads it on its next nightly run and opens a PR if actionable.
- **"run guardian on <project> now"** →
  `systemctl --user start <project>-guardian.service` (same for augur/medic/scribe)
- **install on a new project** → the project needs `.agents/config.toml`
  (see `packs/guardian-quartet/README.md`), then
  `bash packs/guardian-quartet/install.sh --project <dir> [--dry-run]`

Report agent results concisely: status, project, one-line summary —
not raw JSONL.
