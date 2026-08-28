#!/usr/bin/env bats
#
# doctor.bats — `install.sh --doctor --project <p>` (ticket:
# shipyard-doctor-uninstall). Read-only conformance audit: exit 0 clean,
# exit 1 with a `DOCTOR <class>: ...` line per finding.
#
# Each drift class (a)-(h) is seeded in a real install fixture and asserted
# to produce a nonzero exit + a finding line naming the artifact — a doctor
# that cannot fail on the real drift is not a test. Plus: the clean install
# exits 0 AND is provably read-only (no file writes, no systemd mutation).
#
# systemctl is stubbed to answer is-enabled from the fixture unit files, so
# "enabled/disabled/missing" states are seedable. The retired vocabulary is
# built from split strings — the token-caps conformance grep scans tests/.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  DOCTOR_TEST_BASH="$(PATH="${SHIPYARD_TEST_COMMAND_PATH:-$PATH}" command -v bash)"
  quartet_setup
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  UNITS="$HOME/.config/systemd/user"

  # systemctl: is-enabled <x.timer> succeeds iff the timer file exists and no
  # sibling <x.timer>.disabled marker; every other verb is a harmless no-op.
  make_stub_script systemctl '
u=""; for a in "$@"; do case "$a" in *.timer) u="$a";; esac; done
case "$*" in
  *is-enabled*)
    if [ -n "$u" ] && [ -f "$HOME/.config/systemd/user/$u" ] \
       && [ ! -f "$HOME/.config/systemd/user/$u.disabled" ]; then exit 0; else exit 1; fi ;;
  *) exit 0 ;;
esac'
  make_stub crontab 0 ""
  make_stub gh 0
  make_stub claude 0
}

# doctor_install — install the clean fixture (default 4 agents) under the
# fixture $HOME; echoes the project dir into $P. Real install.sh so units +
# skill symlinks + gates.md land exactly as production writes them.
doctor_install() {
  P="$(make_fixture_project docp clean-install.toml)"
  QUARTET_DIR="$QUARTET_ROOT" \
  QUARTET_EVENTS_DIR="$EVENTS_DIR" \
  QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    bash "$QUARTET_ROOT/install.sh" --project "$P" >/dev/null 2>&1
}

run_doctor() {
  run env QUARTET_DIR="$QUARTET_ROOT" \
    "$DOCTOR_TEST_BASH" "$QUARTET_ROOT/install.sh" --doctor --project "$P"
}

enable_doctor_memory() {
  local mode="${1:-advisory}"
  printf '\n[memory]\nmode = "%s"\nledger = ".agents/rules-ledger.jsonl"\n' \
    "$mode" >>"$P/.agents/config.toml"
  : >"$P/.agents/rules-ledger.jsonl"
}

seed_doctor_rule() {
  python3 - "$P/.agents/rules-ledger.jsonl" <<'PY'
from pathlib import Path
import json, sys
r={"schema_version":1,"id":"DOCTOR-RACE","occurred_at":"2026-08-20T12:30:00Z",
"kind":"regression","severity":"block","status":"active",
"summary":"A conditional transition raced.",
"mechanism":"A stale writer passed a split read-check-write sequence.",
"rule":"Use an atomic version-bound transition.",
"required_evidence":"Run a deterministic interleaving regression test.",
"associations":{"paths":["src/state.py"],"tags":["race-condition"]},
"remediation":"Bind the write to the observed version.",
"sources":[{"kind":"ticket","ref":"docs/tickets/DOCTOR-RACE.md"}]}
Path(sys.argv[1]).write_text(json.dumps(r,sort_keys=True,separators=(",",":"))+"\n")
PY
}

# split-string retired words (never literal in tests/)
retired_word_a() { printf '%s' "au""gur"; }

# ---------------------------------------------------------------------------
# Clean install — exit 0, read-only
# ---------------------------------------------------------------------------

@test "doctor: clean install exits 0 with no findings" {
  doctor_install
  run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | grep '^DOCTOR ' || true)" ]
}

@test "doctor: is read-only — no file writes, no systemd mutation" {
  doctor_install
  # Snapshot every mtime under the units dir + the project's owned surface.
  snap() { find "$UNITS" "$P/.agents" "$P/.claude" -printf '%p %T@\n' 2>/dev/null | sort; }
  before="$(snap)"
  : > "$SHIM_LOG/systemctl.argv"          # forget install's systemctl calls
  run_doctor
  [ "$status" -eq 0 ]
  after="$(snap)"
  [ "$before" = "$after" ]                 # nothing written/touched
  # The only systemctl verb doctor may use is is-enabled.
  if [ -f "$SHIM_LOG/systemctl.argv" ]; then
    run grep -vE 'is-enabled' "$SHIM_LOG/systemctl.argv"
    [ -z "$output" ]                       # no daemon-reload/enable/disable/start
  fi
}

@test "doctor: completes well under 5s" {
  doctor_install
  s="$(python3 -c 'import time; print(time.monotonic_ns())')"
  run_doctor
  e="$(python3 -c 'import time; print(time.monotonic_ns())')"
  elapsed_ms="$(( (e - s) / 1000000 ))"
  [ "$status" -eq 0 ]
  [ "$elapsed_ms" -lt 5000 ]
}

@test "doctor: configured empty memory is clean and read-only" {
  doctor_install; enable_doctor_memory
  snapshot="$(python3 - "$P" "$XDG_CACHE_HOME" <<'PY'
from pathlib import Path
import sys
for root in map(Path,sys.argv[1:]):
    if root.exists():
        for p in [root,*sorted(root.rglob("*"))]: print(p,p.lstat().st_mtime_ns)
PY
)"
  run_doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"DOCTOR memory:"* ]]
  current="$(python3 - "$P" "$XDG_CACHE_HOME" <<'PY'
from pathlib import Path
import sys
for root in map(Path,sys.argv[1:]):
    if root.exists():
        for p in [root,*sorted(root.rglob("*"))]: print(p,p.lstat().st_mtime_ns)
PY
)"
  [ "$snapshot" = "$current" ]
}

@test "doctor: unconfigured projects never invoke the memory helper" {
  doctor_install
  real_python="$(python3 -c 'import sys; print(sys.executable)')"
  make_stub_script python3 "exec \"$real_python\" \"\$@\""
  : >"$SHIM_LOG/python3.argv"

  run_doctor
  [ "$status" -eq 0 ]
  ! grep -Fq 'agents/lib/rules-memory.py status' "$SHIM_LOG/python3.argv"

  enable_doctor_memory
  run_doctor
  [ "$status" -eq 0 ]
  grep -Fq 'agents/lib/rules-memory.py status' "$SHIM_LOG/python3.argv"
}

@test "doctor: invalid ledger and absent active index are actionable memory findings" {
  doctor_install; enable_doctor_memory required
  printf '{"summary":"PRIVATE-DOCTOR-PROSE"}\n' >"$P/.agents/rules-ledger.jsonl"
  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR memory: state=invalid errors="* ]]
  [[ "$output" == *"missing_key"* ]]
  [[ "$output" != *"PRIVATE-DOCTOR-PROSE"* ]]

  seed_doctor_rule
  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR memory: index=absent"* ]]
  [[ "$output" == *"run a bounded shipyard memory query"* ]]
}

@test "doctor: fresh index is clean and unsafe latest receipt is a finding" {
  doctor_install; enable_doctor_memory; seed_doctor_rule
  scope="$BATS_TEST_TMPDIR/doctor-memory-scope"
  printf 'atomic version-bound transition stale writer\n' >"$scope"
  run env XDG_CACHE_HOME="$XDG_CACHE_HOME" python3 -B \
    "$QUARTET_ROOT/agents/lib/rules-memory.py" query --project "$P" --scope-file "$scope"
  [ "$status" -eq 0 ]
  run_doctor
  [ "$status" -eq 0 ]

  printf '{}\n' >"$P/tmp/critic-memory-receipt-bad.json"
  chmod 644 "$P/tmp/critic-memory-receipt-bad.json"
  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR memory: receipt=invalid code=receipt_invalid"* ]]
}

@test "doctor (f): missing AGENTS.md skill bridge -> finding" {
  doctor_install
  rm -f "$P/AGENTS.md"
  run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR skill bridge: AGENTS.md missing"* ]]
}

# ---------------------------------------------------------------------------
# (a) expected unit missing / disabled / wrong QUARTET_DIR
# ---------------------------------------------------------------------------

@test "doctor (a): expected role unit missing -> finding + exit 1" {
  doctor_install
  rm -f "$UNITS/docp-release.service" "$UNITS/docp-release.timer"
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR unit: expected 'release' crew unit missing"* ]]
}

@test "doctor (a): expected unit present but timer disabled -> finding" {
  doctor_install
  touch "$UNITS/docp-medic.timer.disabled"
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR unit: 'medic' present but its timer is not enabled"* ]]
}

@test "doctor: expected role missing its required prompt is a finding" {
  doctor_install
  rm -f "$P/.agents/build.md"
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR prompt: expected 'build' project prompt missing"* ]]
  [[ "$output" == *"$P/.agents/build.md"* ]]
}

@test "doctor: disabled undeclared latent roles do not require prompts" {
  P="$(make_fixture_project docpartial clean-install.toml)"
  fixture_replace_in_place "$P/.agents/config.toml" \
    '^\[install\.timers\]\n(?:[^\n]*\n)*' \
    $'[install.timers]\nscribe = "*-*-* 01:00:00"\n'
  rm -f "$P/.agents/build.md" "$P/.agents/release.md" "$P/.agents/medic.md"
  QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/install.sh" --project "$P" >/dev/null 2>&1

  for role in build release medic; do
    sed "s#agents/scribe/#agents/$role/#" \
      "$UNITS/docpartial-scribe.service" >"$UNITS/docpartial-$role.service"
    cp "$UNITS/docpartial-scribe.timer" "$UNITS/docpartial-$role.timer"
    touch "$UNITS/docpartial-$role.timer.disabled"
  done

  run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | grep '^DOCTOR ' || true)" ]
}

@test "doctor (a): ExecStart runner not under \$QUARTET_DIR -> finding" {
  doctor_install
  fixture_replace_in_place "$UNITS/docp-build.service" \
    "$QUARTET_ROOT/agents/build/runner.sh" \
    '/opt/stale-quartet/agents/build/runner.sh'
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR unit: docp-build runner not under \$QUARTET_DIR"* ]]
}

# ---------------------------------------------------------------------------
# (b) stale duplicate unit for the same role
# ---------------------------------------------------------------------------

@test "doctor (b): a second unit running the same role runner -> finding" {
  doctor_install
  # An old display-name scribe unit left beside the current one.
  sed 's/Scribe/Chronicler/' "$UNITS/docp-scribe.service" >"$UNITS/docp-chronicler.service"
  cp "$UNITS/docp-scribe.timer" "$UNITS/docp-chronicler.timer"
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR stale:"* ]]
  [[ "$output" == *"'scribe' runner"* ]]
}

# ---------------------------------------------------------------------------
# (c) foreign drop-in on a crew unit
# ---------------------------------------------------------------------------

@test "doctor (c): a .service.d drop-in on a crew unit -> finding" {
  doctor_install
  mkdir -p "$UNITS/docp-medic.service.d"
  printf '[Service]\nEnvironment=FOO=bar\n' >"$UNITS/docp-medic.service.d/override.conf"
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR dropin: docp-medic.service.d present"* ]]
}

@test "doctor (c): a drop-in on a NON-crew unit is NOT flagged" {
  doctor_install
  # A sibling app service for the same project, not a crew runner.
  cat >"$UNITS/docp-frontend-deploy.service" <<EOF
[Service]
ExecStart=/bin/bash /somewhere/deploy.sh --project $P
EOF
  mkdir -p "$UNITS/docp-frontend-deploy.service.d"
  printf '[Service]\nMemoryMax=2G\n' >"$UNITS/docp-frontend-deploy.service.d/mem.conf"
  run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | grep 'frontend-deploy' || true)" ]
}

# ---------------------------------------------------------------------------
# (d) retired config keys / sections
# ---------------------------------------------------------------------------

@test "doctor (d): a USD-era decimal budget key -> finding" {
  doctor_install
  # Append a bare retired key (no duplicate section header — that would be a
  # TOML parse error, not a doctor finding). Lands under the last table.
  printf '\nbudget_hook = 0.10\n' >>"$P/.agents/config.toml"
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR config: retired key/section"* ]]
  [[ "$output" == *"budget_hook"* ]]
}

@test "doctor (d): a retired-vocabulary section header -> finding" {
  doctor_install
  printf '\n[%s]\nfoo = 1\n' "$(retired_word_a)" >>"$P/.agents/config.toml"
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR config: retired key/section"* ]]
}

@test "doctor (d): the current budget_tokens_daily key is NOT flagged" {
  doctor_install   # clean fixture already carries budget_tokens_daily
  run_doctor
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | grep 'budget_tokens_daily' || true)" ]
}

# ---------------------------------------------------------------------------
# (e) skill symlink missing / not resolving into $QUARTET_DIR/skills
# ---------------------------------------------------------------------------

@test "doctor (e): a missing skill symlink -> finding" {
  doctor_install
  rm -f "$P/.claude/skills/bugfix"
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR skill: bugfix symlink missing"* ]]
}

@test "doctor (e): a missing Codex discovery skill symlink -> finding" {
  doctor_install
  rm -f "$P/.agents/skills/execute-ticket"
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR codex skill: execute-ticket symlink missing"* ]]
}

@test "doctor (e): missing ui-design links in both discovery roots are findings" {
  doctor_install
  rm -f "$P/.claude/skills/ui-design" "$P/.agents/skills/ui-design"
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR skill: ui-design symlink missing"* ]]
  [[ "$output" == *"DOCTOR codex skill: ui-design symlink missing"* ]]
}

@test "doctor (e): missing eda links in both discovery roots are findings" {
  doctor_install
  rm -f "$P/.claude/skills/eda" "$P/.agents/skills/eda"
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR skill: eda symlink missing"* ]]
  [[ "$output" == *"DOCTOR codex skill: eda symlink missing"* ]]
}

@test "doctor (e): a symlink resolving OUTSIDE shipyard skills -> finding" {
  doctor_install
  ln -sfn /etc/hostname "$P/.claude/skills/feature"
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR skill: feature does not resolve"* ]]
}

# ---------------------------------------------------------------------------
# (g) dead hook wiring in .claude/settings.json
# ---------------------------------------------------------------------------

@test "doctor (g): a hook command naming a missing script -> finding" {
  doctor_install
  cat >"$P/.claude/settings.json" <<EOF
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"bash \$CLAUDE_PROJECT_DIR/scripts/post-push-ghost.sh"}]}]}}
EOF
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR hook:"* ]]
  [[ "$output" == *"post-push-ghost.sh"* ]]
}

@test "doctor (g): live hooks (existing file, \$CLAUDE_PROJECT_DIR, inline jq) are NOT flagged" {
  doctor_install
  mkdir -p "$P/.claude/hooks"
  printf '#!/bin/bash\n' >"$P/.claude/hooks/ok.sh"
  cat >"$P/.claude/settings.json" <<EOF
{"hooks":{
  "PreToolUse":[{"hooks":[{"type":"command","command":"\$CLAUDE_PROJECT_DIR/.claude/hooks/ok.sh"}]}],
  "SessionStart":[{"hooks":[{"type":"command","command":"jq -r '.session_id // empty' > /tmp/x-\$UID.txt || true"}]}]
}}
EOF
  run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | grep '^DOCTOR ' || true)" ]
}

# ---------------------------------------------------------------------------
# (h) legacy launcher script / crontab line
# ---------------------------------------------------------------------------

@test "doctor (h): a legacy (non-shim) launcher script -> finding" {
  doctor_install
  mkdir -p "$P/scripts"
  printf '#!/bin/bash\necho old launcher\n' >"$P/scripts/docp-medic.sh"
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR launcher:"* ]]
  [[ "$output" == *"docp-medic.sh"* ]]
}

@test "doctor (h): a legacy crontab launcher line -> finding" {
  doctor_install
  make_stub_script crontab "
case \"\$*\" in
  *-l*) echo '30 3 * * * /bin/bash $P/scripts/docp-release.sh --mode daily' ;;
  *) : ;;
esac"
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR cron:"* ]]
}

# ---------------------------------------------------------------------------
# (i) hub-only decisions-ledger mirror
# ---------------------------------------------------------------------------

@test "doctor (i): a hub mentat decision not mirrored to the project ledger -> finding" {
  doctor_install
  mkdir -p "$P/data/news"
  printf '%s\n' '{"id":"mentat:sib:deadbeef","project":"sib","decision":"approve"}' \
    >"$P/data/news/decisions.jsonl"
  # sibling project exists but its ledger lacks the id
  local sib; sib="$(dirname "$P")/sib"
  mkdir -p "$sib/data"
  printf '%s\n' '{"proposal_id":"mentat:sib:00000000","decision":"deny"}' \
    >"$sib/data/decisions.jsonl"
  run_doctor
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"DOCTOR ledger:"* ]]
  [[ "$output" == *"mentat:sib:deadbeef"* ]]
}

@test "doctor (i): a mirrored decision is NOT flagged" {
  doctor_install
  mkdir -p "$P/data/news"
  printf '%s\n' '{"id":"mentat:sib:deadbeef","project":"sib","decision":"approve"}' \
    >"$P/data/news/decisions.jsonl"
  local sib; sib="$(dirname "$P")/sib"
  mkdir -p "$sib/data"
  printf '%s\n' '{"proposal_id":"mentat:sib:deadbeef","decision":"approve"}' \
    >"$sib/data/decisions.jsonl"
  run_doctor
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$(printf '%s' "$output" | grep '^DOCTOR ledger' || true)" ]
}
