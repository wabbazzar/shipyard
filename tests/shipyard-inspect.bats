#!/usr/bin/env bats
# shipyard-inspect.bats — hermetic contract for the read-only fleet inspector.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  export CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/no-real-claude"
  export CODEX_SESSIONS_DIR="$BATS_TEST_TMPDIR/no-real-codex"
  make_strict_show_stub
}

run_inspect() {
  SHIPYARD_INSPECT_NOW=2026-07-29T12:00:00Z \
    QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/skills/shipyard/shipyard.sh" inspect --json "$@"
}

run_shipyard() {
  QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/skills/shipyard/shipyard.sh" "$@"
}

write_service() {
  local stem="$1" role="$2" project="$3" core="${4:-$QUARTET_ROOT}"
  cat >"$UNIT_DIR/$stem.service" <<EOF
[Unit]
Description=synthetic fixture
[Service]
Type=oneshot
WorkingDirectory=$project
ExecStart=/bin/bash $core/agents/$role/runner.sh --project $project --mode fixture
EOF
}

write_timer() {
  local stem="$1" calendar="${2:-daily}"
  cat >"$UNIT_DIR/$stem.timer" <<EOF
[Unit]
Description=synthetic fixture timer
[Timer]
OnCalendar=$calendar
EOF
}

make_strict_show_stub() {
  make_stub_script systemctl '
printf "%s|%s\n" "${LC_ALL:-}" "${TZ:-}" >>"$SHIM_LOG/systemctl.env"
if [ "${1:-}" != "--user" ] || [ "${2:-}" != "show" ]; then
  printf "%s\n" "$*" >>"$SHIM_LOG/systemctl.rejected"
  exit 97
fi
unit="${3:-}"
[ -f "$SHIM_LOG/$unit.stdout" ] && cat "$SHIM_LOG/$unit.stdout"
[ -f "$SHIM_LOG/$unit.stderr" ] && cat "$SHIM_LOG/$unit.stderr" >&2
rc=0
[ -f "$SHIM_LOG/$unit.rc" ] && rc="$(cat "$SHIM_LOG/$unit.rc")"
exit "$rc"
'
}

seed_show_output() {
  local stem="$1"
  cat >"$SHIM_LOG/$stem.timer.stdout" <<EOF
LoadState=loaded
ActiveState=active
SubState=waiting
UnitFileState=enabled
LastTriggerUSec=Wed 2026-07-29 06:00:00 UTC
NextElapseUSecRealtime=Thu 2026-07-30 06:00:00 UTC
EOF
  cat >"$SHIM_LOG/$stem.service.stdout" <<EOF
LoadState=loaded
ActiveState=inactive
SubState=dead
Result=success
ExecMainStatus=0
EOF
}

make_doctor_readonly_stub() {
  make_stub_script systemctl '
case "$*" in
  "--user show "*)
    unit="${3:-}"
    case "$unit" in
      *.timer)
        printf "%s\n" "LoadState=loaded" "ActiveState=active" "SubState=waiting" \
          "UnitFileState=enabled" \
          "LastTriggerUSec=Wed 2026-07-29 06:00:00 UTC" \
          "NextElapseUSecRealtime=Thu 2026-07-30 06:00:00 UTC" ;;
      *.service)
        printf "%s\n" "LoadState=loaded" "ActiveState=inactive" "SubState=dead" \
          "Result=success" "ExecMainStatus=0" ;;
    esac
    exit 0 ;;
  *" is-enabled "*)
    unit=""; for arg in "$@"; do case "$arg" in *.timer) unit="$arg";; esac; done
    [ -n "$unit" ] && [ -f "$HOME/.config/systemd/user/$unit" ] \
      && [ ! -f "$HOME/.config/systemd/user/$unit.disabled" ] ;;
  *)
    printf "%s\n" "$*" >>"$SHIM_LOG/systemctl.rejected"
    exit 97 ;;
esac
'
}

install_doctor_fixture() {
  local name="${1:-docinspect}"
  P="$(make_fixture_project "$name" clean-install.toml)"
  make_stub systemctl 0
  make_stub crontab 0 ""
  make_stub gh 0 ""
  make_stub claude 0 ""
  QUARTET_DIR="$QUARTET_ROOT" \
  QUARTET_EVENTS_DIR="$EVENTS_DIR" \
  QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    bash "$QUARTET_ROOT/install.sh" --project "$P" >/dev/null 2>&1
  make_doctor_readonly_stub
  : >"$SHIM_LOG/systemctl.argv"
}

make_phase3_core() {
  P3_CORE="$BATS_TEST_TMPDIR/phase3-core"
  mkdir -p "$P3_CORE/agents" "$P3_CORE/data/events"
  local role
  for role in design build release medic scribe; do
    mkdir -p "$P3_CORE/agents/$role"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>%q\nexit 97\n' \
      "$SHIM_LOG/runner.rejected" >"$P3_CORE/agents/$role/runner.sh"
    chmod +x "$P3_CORE/agents/$role/runner.sh"
  done
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>%q\nexit 97\n' \
    "$SHIM_LOG/runner.rejected" >"$P3_CORE/agents/release/critic-watch.sh"
  chmod +x "$P3_CORE/agents/release/critic-watch.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$P3_CORE/install.sh"
  chmod +x "$P3_CORE/install.sh"

  make_stub_script journalctl '
expected="--user -u caddy -o json --no-pager --output-fields=__REALTIME_TIMESTAMP,MESSAGE --since 2026-07-22T12:00:00Z --until 2026-07-29T12:00:00Z"
if [ "$*" != "$expected" ]; then
  printf "%s\n" "$*" >>"$SHIM_LOG/journalctl.rejected"
  exit 97
fi
[ -f "$SHIM_LOG/journalctl.stdout" ] && cat "$SHIM_LOG/journalctl.stdout"
rc=0
[ -f "$SHIM_LOG/journalctl.rc" ] && rc="$(cat "$SHIM_LOG/journalctl.rc")"
exit "$rc"
'
  local command
  for command in curl wget nc gh claude codex hermes; do
    make_stub_script "$command" '
printf "%s\n" "$*" >>"$SHIM_LOG/'"$command"'.rejected"
exit 97
'
  done
}

write_phase3_service() {
  local stem="$1" role="$2" project="$3" event_root="${4:-}"
  {
    printf '%s\n' '[Unit]' 'Description=synthetic phase3 fixture' '[Service]' \
      'Type=oneshot' "WorkingDirectory=$project"
    [ -z "$event_root" ] || printf 'Environment=QUARTET_EVENTS_DIR=%s\n' "$event_root"
    printf 'ExecStart=/bin/bash %s/agents/%s/runner.sh --project %s --mode fixture\n' \
      "$P3_CORE" "$role" "$project"
  } >"$UNIT_DIR/$stem.service"
  write_timer "$stem"
  seed_show_output "$stem"
}

make_phase3_project() {
  local name="$1" roles="$2" event_root="${3:-}"
  P3_PROJECT="$BATS_TEST_TMPDIR/projects/$name"
  mkdir -p "$P3_PROJECT/.agents" "$P3_PROJECT/data/usage" "$P3_PROJECT/tmp"
  cat >"$P3_PROJECT/.agents/config.toml" <<EOF
project_name = "$name"
branch = "main"
[paths]
result_dir = "tmp"
[design]
budget_tokens_daily = 100
max_open_proposals = 1
[build]
budget_tokens_daily = 100
[release]
budget_tokens_daily = 100
test_cmd = "true"
typecheck = "true"
[medic]
budget_tokens_daily = 100
[scribe]
budget_tokens_daily = 100
EOF
  local role
  for role in $roles; do
    write_phase3_service "$name-$role" "$role" "$P3_PROJECT" "$event_root"
  done
}

add_phase3_probe() {
  cat >>"$P3_PROJECT/.agents/config.toml" <<'EOF'
[[medic.checks]]
name = "web"
url = "https://Example.TEST/health?fixture=ignored"
EOF
}

write_phase3_watcher() {
  local project="$1" event_root="${2:-}" name
  name="$(basename "$project")-release-watch"
  {
    printf '%s\n' '[Service]' "WorkingDirectory=$project"
    [ -z "$event_root" ] || printf 'Environment=QUARTET_EVENTS_DIR=%s\n' "$event_root"
    printf 'ExecStart=/bin/bash %s/agents/release/critic-watch.sh --project %s\n' \
      "$P3_CORE" "$project"
  } >"$UNIT_DIR/$name.service"
}

run_phase3() {
  SHIPYARD_INSPECT_NOW=2026-07-29T12:00:00Z \
    python3 "$QUARTET_ROOT/skills/shipyard/inspect.py" \
      --core-root "$P3_CORE" --unit-dir "$UNIT_DIR" --days "${1:-7}" --json
}

phase3_hashes() {
  find "$P3_CORE" "$BATS_TEST_TMPDIR/projects" "$UNIT_DIR" -type f -print0 \
    | sort -z \
    | xargs -0 sha256sum
}

write_phase4_result() {
  local relative_dir="$1" display="$2" proposals_json="$3"
  mkdir -p "$P3_PROJECT/$relative_dir"
  cat >"$P3_PROJECT/$relative_dir/$(basename "$P3_PROJECT")-$display-result.json" <<EOF
{"ts":"2026-07-28T09:30:00Z","project":"$(basename "$P3_PROJECT")","proposals":$proposals_json}
EOF
}

phase4_proposal() {
  local id="$1" signal_ids="${2:-[]}" title="${3:-Proposal $1}"
  printf '{"id":"%s","type":"feature","title":"%s","severity":"med","status":"open","signal_ids":%s}' \
    "$id" "$title" "$signal_ids"
}

enable_phase5_reporters() {
  mkdir -p "$P3_CORE/scripts" "$P3_CORE/docs/tickets/pending"
  cp "$QUARTET_ROOT/scripts/delegation-report.py" \
    "$P3_CORE/scripts/delegation-report.py"
  cat >"$P3_CORE/docs/tickets/pending/synthetic.md" <<'EOF'
# Synthetic ticket

## Ledger

builder: subagent (1 agent)
EOF
  CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/transcripts/claude"
  CODEX_SESSIONS_DIR="$BATS_TEST_TMPDIR/transcripts/codex"
  export CLAUDE_PROJECTS_DIR CODEX_SESSIONS_DIR
  mkdir -p "$CLAUDE_PROJECTS_DIR/fixture" \
    "$CODEX_SESSIONS_DIR/2026/07/29"
}

write_phase5_claude() {
  cat >"$CLAUDE_PROJECTS_DIR/fixture/session.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-07-28T08:00:00Z","message":{"content":[{"type":"tool_use","id":"skill-1","name":"Skill","input":{"skill":"execute-ticket"}}],"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","timestamp":"2026-07-28T08:00:01Z","message":{"content":[{"type":"tool_use","id":"agent-1","name":"Agent","input":{"description":"CLAUDE_TRANSCRIPT_SECRET"}}],"usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}}
{"type":"assistant","timestamp":"malformed-claude-time","message":{"content":"CLAUDE_MALFORMED_SECRET","usage":{"input_tokens":999,"output_tokens":999,"cache_read_input_tokens":999,"cache_creation_input_tokens":999}}}
{"type":"assistant","timestamp":"2026-07-29T12:00:00Z","message":{"content":"CLAUDE_AT_BOUNDARY_SECRET","usage":{"input_tokens":5,"output_tokens":6,"cache_read_input_tokens":7,"cache_creation_input_tokens":8}}}
EOF
}

write_phase5_codex() {
  cat >"$CODEX_SESSIONS_DIR/2026/07/29/rollout-fixture.jsonl" <<'EOF'
{"timestamp":"2026-07-28T09:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
{"timestamp":"2026-07-28T09:00:01Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"<!-- shipyard-skill:execute-ticket:v1 --> CODEX_TRANSCRIPT_SECRET"}]}}
{"timestamp":"2026-07-28T09:00:02Z","type":"response_item","payload":{"type":"function_call","name":"spawn_agent","arguments":"{\"secret\":\"CODEX_CALL_SECRET\"}","call_id":"spawn-1"}}
{"timestamp":"2026-07-28T09:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":1,"total_tokens":14}}}}
{"timestamp":"2026-07-28T09:00:04Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}
not-json-CODEX_MALFORMED_RECORD_SECRET
{"timestamp":"malformed-codex-time","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CODEX_MALFORMED_TIME_SECRET"}]}}
{"timestamp":"2026-07-28T09:05:00Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"wrong"}}
{"timestamp":"2026-07-29T12:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-at-boundary"}}
{"timestamp":"2026-07-29T12:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"CODEX_AT_BOUNDARY_SECRET"}]}}
{"timestamp":"2026-07-29T12:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"cached_input_tokens":4,"output_tokens":6,"reasoning_output_tokens":2,"total_tokens":28}}}}
{"timestamp":"2026-07-29T12:00:02Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-at-boundary"}}
EOF
}

make_phase5_reporter_fixture() {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-effectiveness"
  mkdir -p "$root"
  make_phase3_project effectiveness "build" "$root"
  enable_phase5_reporters
  write_phase5_claude
  write_phase5_codex
}

make_phase5_benchmark_fixture() {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-benchmarks"
  mkdir -p "$root"
  make_phase3_project outcomes "design build release" "$root"
  write_phase4_result tmp design \
    "[$(phase4_proposal bug-open '[]' 'Disconnected bug'),$(phase4_proposal feature-open '[]' 'Disconnected feature')]"
  fixture_replace_in_place "$P3_PROJECT/tmp/outcomes-design-result.json" \
    '"type":"feature","title":"Disconnected bug"' \
    '"type":"bug","title":"Disconnected bug"'
  cat >"$P3_PROJECT/data/decisions.jsonl" <<'EOF'
{"proposal_id":"unrelated-decision","decision":"approve","ts":"2026-07-28T10:00:00Z"}
EOF
  cat >"$P3_PROJECT/data/usage/outcomes.jsonl" <<'EOF'
{"ts":"2026-07-28T10:00:00Z","action":"view","path":"/synthetic"}
EOF
  cat >"$root/2026-07-28.jsonl" <<'EOF'
{"ts":"2026-07-28T10:00:00Z","svc":"outcomes-design","event":"medic.incident","incident_id":"incident-disconnected","summary":"BENCHMARK_SECRET"}
{"ts":"2026-07-28T10:01:00Z","svc":"outcomes-build","event":"job.end","status":"ok","tokens":1}
{"ts":"2026-07-28T10:02:00Z","svc":"outcomes-release","event":"job.end","status":"ok","tokens":1}
{"ts":"2026-07-28T10:03:00Z","svc":"outcomes-release","event":"release.critique","block":1,"warn":1,"note":0,"files":1,"tokens":1}
EOF
}

@test "inspect: discovers only matching current-root manifests and emits schema v1" {
  alpha="$BATS_TEST_TMPDIR/projects/alpha"
  beta="$BATS_TEST_TMPDIR/projects/beta"
  mkdir -p "$alpha" "$beta"
  write_service alpha-helldiver build "$alpha"
  write_service alpha-proctor release "$alpha"
  write_service beta-chronicler scribe "$beta"

  run run_inspect --days 7

  [ "$status" -eq 0 ]
  jq -e '
    .schema_version == 1
    and .meta.inspection_started_at == "2026-07-29T12:00:00Z"
    and .meta.window_start_at == "2026-07-22T12:00:00Z"
    and .meta.window_end_at == .meta.inspection_started_at
    and .meta.window_days == 7
    and .meta.project_count == 2
    and .meta.role_count == 3
    and (.fleet | length) == 2
    and ([.fleet[].roles[]] | sort) == ["build", "release", "scribe"]
  ' <<<"$output"

  calculated_id="$(jq -c '[.evidence[] | select(.kind=="manifest_identity")][0]' \
    <<<"$output" | python3 -c '
import hashlib, json, sys
e = json.load(sys.stdin)
operand = json.dumps(e["fields"], sort_keys=True, separators=(",", ":"),
                     ensure_ascii=False, allow_nan=False)
print(hashlib.sha256(("manifest\0" + e["source_ref"] + "\0" + operand)
      .encode("utf-8")).hexdigest()[:20])
')"
  [ "$calculated_id" = "$(jq -r \
    '[.evidence[] | select(.kind=="manifest_identity")][0].id' <<<"$output")" ]

  run env SHIPYARD_INSPECT_NOW=2026-07-29T12:00:00Z \
    QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/skills/shipyard/shipyard.sh" inspect --days 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"fleet: 2 project(s), 3 role(s)"* ]]
}

@test "inspect: inactive successful oneshot is no fault" {
  project="$BATS_TEST_TMPDIR/projects/normal"
  mkdir -p "$project"
  write_service normal-release release "$project"
  write_timer normal-release
  make_strict_show_stub
  seed_show_output normal-release

  run run_inspect

  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].units[0]
      | .timer_active_state == "active"
      and .unit_file_state == "enabled"
      and .service_active_state == "inactive"
      and .service_sub_state == "dead"
      and .service_result == "success"
      and .exec_main_status == 0
  ' <<<"$output"
  [ "$(jq -r '.fleet[0].state' <<<"$output")" != "fault_observed" ]

  fixture_replace_in_place "$SHIM_LOG/normal-release.timer.stdout" \
    'ActiveState=active' 'ActiveState=activating'
  fixture_replace_in_place "$SHIM_LOG/normal-release.timer.stdout" \
    'UnitFileState=enabled' 'UnitFileState=enabled-runtime'
  run run_inspect
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fleet[0].state' <<<"$output")" != "fault_observed" ]

  fixture_replace_in_place "$SHIM_LOG/normal-release.timer.stdout" \
    'ActiveState=activating' 'ActiveState=failed'
  run run_inspect
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fleet[0].state' <<<"$output")" = "fault_observed" ]
}

@test "inspect: configured safety and five-key budget map use exact runner defaults" {
  install_doctor_fixture safety
  cat >"$P/.agents/config.toml" <<'EOF'
project_name = "safety"
autonomous = true
branch = "stable"
[release]
verify_gate = true
test_cmd = "bats tests/"
typecheck = "bash -n scripts/*.sh"
budget_tokens_daily = "00123"
[build]
allow_no_ci = true
forbidden_paths = ["secrets", "agents", "secrets"]
budget_tokens_daily = -1
[medic]
can_merge = true
daily_escalation_cap = 9
budget_tokens_daily = 0
[design]
budget_tokens_daily = 42
[shoulder]
auto_wire = true
EOF

  run run_inspect

  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].autonomous == true
    and .fleet[0].safety == {
      "config_state":"available",
      "can_merge":true,
      "allow_no_ci":true,
      "forbidden_paths":["agents","secrets"],
      "release_verify_gate":true,
      "configured_branch":"stable",
      "trunk_state":"configured",
      "trunk":"stable",
      "trunk_reason":"explicit_config",
      "test_cmd_configured":true,
      "typecheck_configured":true,
      "daily_escalation_cap":9,
      "evidence_ids":.fleet[0].safety.evidence_ids
    }
    and ([.evidence[] | select(.kind=="config_posture")][0].fields
      .budget_tokens_daily_by_role
      == {"design":42,"build":1000000,"release":123,
          "medic":0,"scribe":1000000})
    and ([.evidence[] | select(.kind=="config_posture")][0].fields
      .max_open_proposals == 1)
    and .fleet[0].pressure.configured_max_open_proposals == 1
  ' <<<"$output"

  printf 'project_name = "safety"\n' >"$P/.agents/config.toml"
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].autonomous == false
    and .fleet[0].safety.can_merge == false
    and .fleet[0].safety.allow_no_ci == false
    and .fleet[0].safety.forbidden_paths == []
    and .fleet[0].safety.release_verify_gate == false
    and .fleet[0].safety.configured_branch == null
    and .fleet[0].safety.trunk_state == "unavailable"
    and .fleet[0].safety.trunk_reason == "remote_resolution_not_attempted"
    and .fleet[0].safety.daily_escalation_cap == 5
    and ([.evidence[] | select(.kind=="config_posture")][0].fields
      .budget_tokens_daily_by_role
      == {"design":1000000,"build":1000000,"release":1000000,
          "medic":1000000,"scribe":1000000})
    and ([.evidence[] | select(.kind=="config_posture")][0].fields
      .max_open_proposals == 1)
  ' <<<"$output"

  cat >"$P/.agents/config.toml" <<'EOF'
project_name = "safety"
[design]
max_open_proposals = "007"
EOF
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    ([.evidence[] | select(.kind=="config_posture")][0].fields
      .max_open_proposals == 7)
    and .fleet[0].pressure.configured_max_open_proposals == 7
  ' <<<"$output"

  fixture_replace_in_place "$P/.agents/config.toml" '"007"' '1.5'
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    ([.evidence[] | select(.kind=="config_posture")][0].fields
      .max_open_proposals == 1)
    and .fleet[0].pressure.configured_max_open_proposals == 1
  ' <<<"$output"
}

@test "inspect: malformed config is unavailable posture with unknown autonomy" {
  project="$BATS_TEST_TMPDIR/projects/bad-config"
  mkdir -p "$project/.agents"
  printf '[build\nallow_no_ci = true\n' >"$project/.agents/config.toml"
  write_service bad-config-release release "$project"
  write_timer bad-config-release
  make_strict_show_stub
  seed_show_output bad-config-release

  run run_inspect

  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].autonomous == null
    and .fleet[0].safety.config_state == "error"
    and .fleet[0].safety.can_merge == null
    and .fleet[0].safety.trunk_reason == "config_unavailable"
    and ([.coverage[] | select(.source=="config")][0]
      | .state=="error" and .reason=="malformed")
  ' <<<"$output"
}

@test "inspect: timer timestamp normalization is UTC and host independent" {
  project="$BATS_TEST_TMPDIR/projects/timestamps"
  mkdir -p "$project"
  write_service timestamps-release release "$project"
  write_timer timestamps-release
  make_strict_show_stub
  seed_show_output timestamps-release

  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].units[0].last_trigger_at == "2026-07-29T06:00:00Z"
    and .fleet[0].units[0].next_trigger_at == "2026-07-30T06:00:00Z"
    and .fleet[0].units[0].timer_stale_state == "fresh"
  ' <<<"$output"

  fixture_replace_in_place "$SHIM_LOG/timestamps-release.timer.stdout" \
    'Thu 2026-07-30 06:00:00 UTC' 'Thu 2026-07-30 01:00:00 CDT'
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].units[0].next_trigger_at == null
    and .fleet[0].units[0].timer_stale_state == "unknown"
    and ([.coverage[] | select(.source=="systemd")][0]
      | .state=="partial" and .reason=="malformed"
        and .records_invalid > 0)
  ' <<<"$output"

  seed_show_output timestamps-release
  fixture_replace_in_place "$SHIM_LOG/timestamps-release.service.stdout" \
    '^ExecMainStatus=.*\n?' ''
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].units[0].exec_main_status == null
    and ([.coverage[] | select(.source=="systemd")][0]
      | .state=="partial" and .reason=="malformed")
  ' <<<"$output"

  seed_show_output timestamps-release
  fixture_replace_in_place "$SHIM_LOG/timestamps-release.timer.stdout" \
    'Thu 2026-07-30 06:00:00 UTC' 'Wed 2026-07-29 11:55:00 UTC'
  run run_inspect
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fleet[0].units[0].timer_stale_state' <<<"$output")" = "fresh" ]
  fixture_replace_in_place "$SHIM_LOG/timestamps-release.timer.stdout" \
    'Wed 2026-07-29 11:55:00 UTC' 'Wed 2026-07-29 11:54:59 UTC'
  run run_inspect
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fleet[0].units[0].timer_stale_state' <<<"$output")" = "stale" ]

  seed_show_output timestamps-release
  cat >>"$SHIM_LOG/timestamps-release.timer.stdout" <<'EOF'
UnexpectedProperty=value
LoadState=duplicate
malformed-line
EOF
  fixture_replace_in_place "$SHIM_LOG/timestamps-release.service.stdout" \
    '^ExecMainStatus=.*\n?' ''
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    ([.coverage[] | select(.source=="systemd")][0]
      | .state=="partial" and .reason=="malformed"
        and .records_invalid==4
        and .records_total==14
        and .records_total==(.records_valid+.records_invalid))
  ' <<<"$output"
}

@test "inspect: disabled timer and failed service are direct faults" {
  project="$BATS_TEST_TMPDIR/projects/faults"
  mkdir -p "$project"
  write_service faults-release release "$project"
  write_timer faults-release
  make_strict_show_stub
  seed_show_output faults-release
  fixture_replace_in_place "$SHIM_LOG/faults-release.timer.stdout" \
    'ActiveState=active' 'ActiveState=inactive'
  fixture_replace_in_place "$SHIM_LOG/faults-release.timer.stdout" \
    'SubState=waiting' 'SubState=dead'
  fixture_replace_in_place "$SHIM_LOG/faults-release.timer.stdout" \
    'UnitFileState=enabled' 'UnitFileState=disabled'

  run run_inspect

  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].state == "fault_observed"
    and .fleet[0].units[0].unit_file_state == "disabled"
    and .fleet[0].units[0].timer_active_state == "inactive"
    and .fleet[0].units[0].service_result == "success"
    and (.fleet[0].state_reason_ids | length) > 0
  ' <<<"$output"

  seed_show_output faults-release
  fixture_replace_in_place "$SHIM_LOG/faults-release.service.stdout" \
    'ActiveState=inactive' 'ActiveState=failed'
  fixture_replace_in_place "$SHIM_LOG/faults-release.service.stdout" \
    'Result=success' 'Result=failed'
  fixture_replace_in_place "$SHIM_LOG/faults-release.service.stdout" \
    'ExecMainStatus=0' 'ExecMainStatus=1'
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].state=="fault_observed"
    and .fleet[0].units[0].timer_active_state=="active"
    and .fleet[0].units[0].unit_file_state=="enabled"
    and .fleet[0].units[0].service_active_state=="failed"
    and .fleet[0].units[0].service_result=="failed"
  ' <<<"$output"

  seed_show_output faults-release
  cat >"$SHIM_LOG/faults-release.timer.stdout" <<'EOF'
LoadState=not-found
ActiveState=inactive
SubState=dead
UnitFileState=disabled
LastTriggerUSec=n/a
NextElapseUSecRealtime=n/a
EOF
  printf '4\n' >"$SHIM_LOG/faults-release.timer.rc"
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].state=="fault_observed"
    and .fleet[0].units[0].timer_load_state=="not-found"
    and .fleet[0].units[0].service_result=="success"
  ' <<<"$output"
}

@test "inspect: intentional partial install ignores disabled latent role faults" {
  project="$BATS_TEST_TMPDIR/projects/partial"
  mkdir -p "$project/.agents"
  cat >"$project/.agents/config.toml" <<'EOF'
project_name = "partial"
[install.timers]
scribe = "daily"
EOF

  local role stem
  for role in build release medic scribe; do
    case "$role" in
      build) stem="partial-helldiver" ;;
      release) stem="partial-proctor" ;;
      medic) stem="partial-suk" ;;
      scribe) stem="partial-chronicler" ;;
    esac
    write_service "$stem" "$role" "$project"
    write_timer "$stem"
    seed_show_output "$stem"
    if [ "$role" != "scribe" ]; then
      fixture_replace_in_place "$SHIM_LOG/$stem.timer.stdout" \
        'ActiveState=active' 'ActiveState=inactive'
      fixture_replace_in_place "$SHIM_LOG/$stem.timer.stdout" \
        'SubState=waiting' 'SubState=dead'
      fixture_replace_in_place "$SHIM_LOG/$stem.timer.stdout" \
        'UnitFileState=enabled' 'UnitFileState=disabled'
    fi
  done
  fixture_replace_in_place "$SHIM_LOG/partial-helldiver.service.stdout" \
    'ActiveState=inactive' 'ActiveState=failed'
  fixture_replace_in_place "$SHIM_LOG/partial-helldiver.service.stdout" \
    'Result=success' 'Result=failed'
  fixture_replace_in_place "$SHIM_LOG/partial-helldiver.service.stdout" \
    'ExecMainStatus=0' 'ExecMainStatus=2'

  run run_inspect

  [ "$status" -eq 0 ]
  jq -e '
    . as $doc
    | ([.fleet[0].units[].role] | sort)
        == ["build","medic","release","scribe"]
      and ([.fleet[0].units[]
        | select(.role=="build")
        | .timer_active_state=="inactive"
          and .unit_file_state=="disabled"
          and .service_active_state=="failed"
          and .service_result=="failed"
          and .exec_main_status==2] | all)
      and ([.fleet[0].units[]
        | select(.role=="release" or .role=="medic")
        | .timer_active_state=="inactive"
          and .unit_file_state=="disabled"
          and .service_active_state=="inactive"
          and .service_result=="success"] | all)
      and ([.fleet[0].units[]
        | select(.role=="scribe")
        | .timer_active_state=="active"
          and .unit_file_state=="enabled"
          and .service_result=="success"] | all)
      and ([.evidence[]
        | select(.source=="systemd"
          and (.fields.role=="build"
            or .fields.role=="release"
            or .fields.role=="medic"))
        | select(
            ((.fields.unit | endswith(".timer"))
              and .fields.property=="ActiveState"
              and .fields.value=="inactive")
            or ((.fields.unit | endswith(".timer"))
              and .fields.property=="UnitFileState"
              and .fields.value=="disabled")
            or ((.fields.unit | endswith(".service"))
              and .fields.property=="ActiveState"
              and .fields.value=="failed")
            or ((.fields.unit | endswith(".service"))
              and .fields.property=="Result"
              and .fields.value=="failed"))
        | .id] | length)==8
      and ([.evidence[]
        | select(.source=="systemd"
          and (.fields.role=="build"
            or .fields.role=="release"
            or .fields.role=="medic"))
        | select(
            ((.fields.unit | endswith(".timer"))
              and .fields.property=="ActiveState"
              and .fields.value=="inactive")
            or ((.fields.unit | endswith(".timer"))
              and .fields.property=="UnitFileState"
              and .fields.value=="disabled")
            or ((.fields.unit | endswith(".service"))
              and .fields.property=="ActiveState"
              and .fields.value=="failed")
            or ((.fields.unit | endswith(".service"))
              and .fields.property=="Result"
              and .fields.value=="failed"))
        | .id] - .fleet[0].state_reason_ids | length)==8
      and ([.attention[]
        | select(.kind=="observed_fault")
        | .evidence_ids[]
        | select(. as $id
          | any($doc.evidence[];
              .id==$id and .source=="systemd"
              and (.fields.role=="build"
                or .fields.role=="release"
                or .fields.role=="medic")))]
        | length)==0
  ' <<<"$output"
}

@test "inspect: missing user bus is unavailable not a fabricated fault" {
  project="$BATS_TEST_TMPDIR/projects/no-bus"
  mkdir -p "$project"
  write_service no-bus-release release "$project"
  write_timer no-bus-release
  make_strict_show_stub
  printf 'Failed to connect to bus: No medium found\n' \
    >"$SHIM_LOG/no-bus-release.timer.stderr"
  printf '1\n' >"$SHIM_LOG/no-bus-release.timer.rc"
  printf 'Failed to connect to bus: No medium found\n' \
    >"$SHIM_LOG/no-bus-release.service.stderr"
  printf '1\n' >"$SHIM_LOG/no-bus-release.service.rc"

  run run_inspect

  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].state != "fault_observed"
    and ([.coverage[] | select(.source=="systemd")][0]
      | .state=="unavailable" and .reason=="systemd_unavailable")
  ' <<<"$output"

  : >"$SHIM_LOG/no-bus-release.timer.stderr"
  : >"$SHIM_LOG/no-bus-release.service.stderr"
  printf 'permission denied\n' >"$SHIM_LOG/no-bus-release.timer.stderr"
  printf 'permission denied\n' >"$SHIM_LOG/no-bus-release.service.stderr"
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    ([.coverage[] | select(.source=="systemd")][0]
      | .state=="error" and .reason=="command_failed"
        and .records_total==(.records_valid+.records_invalid))
  ' <<<"$output"
}

@test "inspect: preserves doctor rc and finding classes" {
  install_doctor_fixture doctor-state
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].doctor.state=="clean"
    and .fleet[0].doctor.exit_code==0
    and .fleet[0].doctor.findings==[]
  ' <<<"$output"
  run grep -vE '^--user (show|is-enabled) ' "$SHIM_LOG/systemctl.argv"
  [ "$status" -eq 1 ]

  rm -f "$P/AGENTS.md"
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].doctor.state=="drift"
    and .fleet[0].doctor.exit_code==1
    and ([.fleet[0].doctor.findings[].class] | index("skill bridge") != null)
    and ([.evidence[] | select(.kind=="doctor_finding")
      and .fields.class=="skill bridge"] | length)==1
  ' <<<"$output"

  cp "$QUARTET_ROOT/AGENTS.md" "$P/AGENTS.md"
  fixture_replace_in_place "$P/.agents/config.toml" '^project_name.*$' \
    'project_name = "missing dependency: gh"'
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].doctor.state=="drift"
    and .fleet[0].doctor.exit_code==1
    and ([.coverage[] | select(.source=="doctor")][0]
      | .state=="available" and .reason=="ok")
  ' <<<"$output"

  fixture_replace_in_place "$P/.agents/config.toml" '^project_name.*$' \
    'project_name = "doctor-state"'
  fixture_replace_in_place "$P/.agents/config.toml" '^project_name.*\n?' ''
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].doctor.state=="error"
    and .fleet[0].doctor.exit_code==2
    and ([.coverage[] | select(.source=="doctor")][0]
      | .state=="error" and .reason=="command_failed")
  ' <<<"$output"
}

@test "inspect: doctor dependency failure is coverage unavailable" {
  install_doctor_fixture doctor-dep
  isolated="$BATS_TEST_TMPDIR/doctor-path"
  mkdir -p "$isolated"
  for cmd in bash python3 jq git systemctl claude crontab grep awk basename \
    sed sort tr wc paste readlink dirname find head cut; do
    target="$(command -v "$cmd")"
    [ -n "$target" ] && ln -s "$target" "$isolated/$cmd"
  done

  run env PATH="$isolated" SHIPYARD_INSPECT_NOW=2026-07-29T12:00:00Z \
    QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/skills/shipyard/shipyard.sh" inspect --json

  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].doctor.state=="unavailable"
    and .fleet[0].doctor.exit_code==2
    and ([.coverage[] | select(.source=="doctor")][0]
      | .state=="unavailable" and .reason=="missing_dependency")
  ' <<<"$output"
}

@test "inspect: systemctl adapter rejects every mutation verb" {
  project="$BATS_TEST_TMPDIR/projects/show-only"
  mkdir -p "$project"
  write_service show-only-release release "$project"
  write_timer show-only-release
  make_strict_show_stub
  seed_show_output show-only-release

  run run_inspect

  [ "$status" -eq 0 ]
  [ ! -s "$SHIM_LOG/systemctl.rejected" ]
  [ "$(stub_calls systemctl)" -eq 2 ]
  [ "$(grep -Fxc -- '--user show show-only-release.timer -p LoadState -p ActiveState -p SubState -p UnitFileState -p LastTriggerUSec -p NextElapseUSecRealtime' \
    "$SHIM_LOG/systemctl.argv")" -eq 1 ]
  [ "$(grep -Fxc -- '--user show show-only-release.service -p LoadState -p ActiveState -p SubState -p Result -p ExecMainStatus' \
    "$SHIM_LOG/systemctl.argv")" -eq 1 ]
  [ "$(grep -Fxc 'C|UTC' "$SHIM_LOG/systemctl.env")" -eq 2 ]
}

@test "inspect: dedupes canonical projects and roles" {
  project="$BATS_TEST_TMPDIR/projects/alpha"
  mkdir -p "$project"
  write_service alpha-proctor release "$project"
  write_service alpha-release release "$project"
  write_service alpha-helldiver build "$project"

  run run_inspect

  [ "$status" -eq 0 ]
  jq -e '
    .meta.project_count == 1
    and .meta.role_count == 2
    and .fleet[0].roles == ["build", "release"]
    and (.fleet[0].units | length) == 2
    and ([.coverage[] | select(.source == "manifest")][0].records_total == 3)
    and ([.evidence[] | select(.kind == "manifest_identity")] | length) == 3
  ' <<<"$output"
}

@test "inspect: excludes unrelated CODE_ROOT and other-root units" {
  project="$BATS_TEST_TMPDIR/projects/eligible"
  uninstalled="$BATS_TEST_TMPDIR/code/uninstalled"
  other_project="$BATS_TEST_TMPDIR/projects/other-core"
  other_core="$BATS_TEST_TMPDIR/other-core"
  mkdir -p "$project" "$uninstalled" "$other_project" \
    "$other_core/agents/release"
  printf '#!/usr/bin/env bash\n' >"$other_core/agents/release/runner.sh"
  write_service eligible-release release "$project"
  write_service other-release release "$other_project" "$other_core"
  cat >"$UNIT_DIR/unrelated.service" <<'EOF'
[Service]
WorkingDirectory=/
ExecStart=/bin/true
EOF

  run run_inspect

  [ "$status" -eq 0 ]
  jq -e --arg project "$(readlink -f "$project")" '
    .meta.project_count == 1
    and .meta.role_count == 1
    and .fleet[0].project_path == $project
    and (.fleet | all(.project_name != "uninstalled"))
    and (.fleet | all(.project_name != "other-core"))
  ' <<<"$output"
}

@test "inspect: excludes WorkingDirectory and project argument mismatch" {
  eligible="$BATS_TEST_TMPDIR/projects/eligible"
  wrong="$BATS_TEST_TMPDIR/projects/wrong"
  mkdir -p "$eligible" "$wrong"
  write_service eligible-release release "$eligible"
  cat >"$UNIT_DIR/missing-working-directory.service" <<EOF
[Service]
ExecStart=/bin/bash $QUARTET_ROOT/agents/release/runner.sh --project $eligible --mode fixture
EOF
  cat >"$UNIT_DIR/mismatched-project.service" <<EOF
[Service]
WorkingDirectory=$eligible
ExecStart=/bin/bash $QUARTET_ROOT/agents/release/runner.sh --project $wrong --mode fixture
EOF

  run run_inspect

  [ "$status" -eq 0 ]
  jq -e '
    .meta.project_count == 1
    and .meta.role_count == 1
    and .fleet[0].project_name == "eligible"
  ' <<<"$output"
}

@test "inspect: documents indistinguishable matching spoof" {
  project="$BATS_TEST_TMPDIR/projects/alpha"
  mkdir -p "$project"
  write_service alpha-release release "$project"
  write_service alpha-release-copy release "$project"

  run run_inspect

  [ "$status" -eq 0 ]
  jq -e '
    .meta.role_count == 1
    and ([.coverage[] | select(.source == "manifest")][0].records_total == 2)
    and (.meta.discovery_limitations
      | index("byte_matching_service_spoof_indistinguishable") != null)
  ' <<<"$output"
}

@test "inspect: no fleet exits 3 and emits no JSON" {
  run run_inspect

  [ "$status" -eq 3 ]
  [[ "$output" != *'"schema_version"'* ]]
  [[ "$output" == *"no eligible Shipyard installation"* ]]
}

@test "inspect: malformed flags clock and days exit 2" {
  run run_inspect --days 0
  [ "$status" -eq 2 ]
  [[ "$output" == *"--days must be a positive integer"* ]]

  run run_inspect --days nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"--days must be a positive integer"* ]]

  run env SHIPYARD_INSPECT_NOW=not-a-clock QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/skills/shipyard/shipyard.sh" inspect --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"timezone-aware RFC3339"* ]]

  run env SHIPYARD_INSPECT_NOW='2026-07-29 12:00:00+00:00' \
    QUARTET_DIR="$QUARTET_ROOT" \
    bash "$QUARTET_ROOT/skills/shipyard/shipyard.sh" inspect --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"timezone-aware RFC3339"* ]]

  run run_inspect --days 999999999
  [ "$status" -eq 2 ]

  run run_shipyard inspect --days
  [ "$status" -eq 2 ]
  [[ "$output" == *"--days requires a value"* ]]

  run run_shipyard inspect --unknown
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]

  run run_shipyard inspect --project "$PWD"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--project is not valid"* ]]

  run run_shipyard inspect unexpected
  [ "$status" -eq 2 ]
  [[ "$output" == *"unexpected positional argument"* ]]

  run run_shipyard status --days 7
  [ "$status" -eq 2 ]
  [[ "$output" == *"--json/--days apply only to inspect"* ]]
}

@test "inspect: default status output is unchanged" {
  project="$(make_fixture_project default-status)"

  run run_shipyard --project "$project"
  default_status="$status"
  default_output="$output"
  run run_shipyard status --project "$project"

  [ "$default_status" -eq 3 ]
  [ "$status" -eq 3 ]
  [ "$default_output" = "$output" ]
  [[ "$output" == *"no crew installed"* ]]
}

@test "inspect: schema v1 golden covers every enum and nullable branch" {
  golden="$FIXTURES_DIR/shipyard-inspect/full-schema-v1.json"

  run python3 -m json.tool "$golden"

  [ "$status" -eq 0 ]
  jq -e '
    (keys == [
      "attention", "coverage", "effectiveness", "evidence", "fleet",
      "meta", "priorities", "schema_version", "summary"
    ])
    and .schema_version == 1
    and (.meta.inspection_started_at | type == "string")
    and .meta.schema_catalog.coverage_state
      == ["available", "partial", "unavailable", "error", "not_applicable"]
    and .meta.schema_catalog.claim_kind == ["fact", "derived", "assessment"]
    and .meta.schema_catalog.fleet_state
      == ["fault_observed", "degraded_observed", "no_fault_observed", "unknown"]
    and .meta.schema_catalog.attention_kind
      == ["open_proposal", "observed_fault", "install_drift", "owner_decision", "coverage_gap"]
    and .meta.schema_catalog.effectiveness_state
      == ["measured", "partial", "unmeasured"]
    and .meta.schema_catalog.priority_category
      == ["confirmed_failure", "human_gate", "recurring_failure",
          "evidenced_opportunity", "instrumentation_gap", "hygiene"]
    and (.meta.schema_catalog.nullable_fields | length) == 46
    and ([paths(type == "null")] | length) > 0
  ' "$golden"

  run python3 -c '
import hashlib, json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
e = d["evidence"][0]
def identity(fields):
    operand = json.dumps(fields, sort_keys=True, separators=(",", ":"),
                         ensure_ascii=False, allow_nan=False)
    return hashlib.sha256(("manifest\0" + e["source_ref"] + "\0" + operand)
                          .encode("utf-8")).hexdigest()[:20]
ordered = dict(reversed(list(e["fields"].items())))
dropped = dict(e["fields"])
dropped.pop("event_root_env")
print(e["id"], identity(e["fields"]), identity(ordered), identity(dropped))
' "$golden"
  [ "$status" -eq 0 ]
  read -r golden_id calculated_id reordered_id dropped_id <<<"$output"
  [ "$golden_id" = "$calculated_id" ]
  [ "$golden_id" = "$reordered_id" ]
  [ "$golden_id" != "$dropped_id" ]

  project="$BATS_TEST_TMPDIR/projects/schema"
  mkdir -p "$project"
  write_service schema-release release "$project"
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e --slurpfile golden "$golden" '
    . as $actual | $golden[0] as $expected
    | ($actual | keys) == ($expected | keys)
    and ($actual.meta | keys) == ($expected.meta | del(.schema_catalog) | keys)
    and ($actual.coverage[0] | keys) == ($expected.coverage[0] | keys)
    and ([ $actual.evidence[] | select(.kind=="manifest_identity") ][0] | keys)
      == ($expected.evidence[0] | keys)
    and ([ $actual.evidence[] | select(.kind=="manifest_identity") ][0].fields | keys)
      == ($expected.evidence[0].fields | keys)
    and ($actual.fleet[0] | keys) == ($expected.fleet[0] | keys)
    and ($actual.fleet[0].units[0] | keys) == ($expected.fleet[0].units[0] | keys)
    and ($actual.fleet[0].doctor | keys) == ($expected.fleet[0].doctor | keys)
    and ($actual.fleet[0].jobs | keys) == ($expected.fleet[0].jobs | keys)
    and ($actual.fleet[0].critiques | keys) == ($expected.fleet[0].critiques | keys)
    and ($actual.fleet[0].pressure | keys) == ($expected.fleet[0].pressure | keys)
    and ($actual.fleet[0].pressure.daily_budget_consumers[0] | keys)
      == ($expected.fleet[0].pressure.daily_budget_consumers[0] | keys)
    and ($actual.fleet[0].safety | keys) == ($expected.fleet[0].safety | keys)
    and ($actual.fleet[0].overseer | keys) == ($expected.fleet[0].overseer | keys)
    and ($actual.summary | keys) == ($expected.summary | keys)
  ' <<<"$output"
}

@test "inspect: rolling window is start-inclusive and end-exclusive" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-window"
  mkdir -p "$root"
  make_phase3_project window "build" "$root"
  cat >"$root/2026-07-22.jsonl" <<'EOF'
{"ts":"2026-07-22T11:59:59Z","svc":"window-build","event":"job.end","status":"ok"}
{"ts":"2026-07-22T12:00:00Z","svc":"window-build","event":"job.end","status":"ok"}
EOF
  cat >"$root/2026-07-29.jsonl" <<'EOF'
{"ts":"2026-07-29T12:00:00Z","svc":"window-build","event":"job.end","status":"ok"}
{"ts":"2026-07-29T12:00:01Z","svc":"window-build","event":"job.end","status":"ok"}
EOF
  cat >"$P3_PROJECT/data/fyi-requests.jsonl" <<'EOF'
{"id":"fyi-old","ts":"2026-07-22T11:59:59Z","text":"synthetic old"}
{"id":"fyi-start","ts":"2026-07-22T12:00:00Z","text":"synthetic current"}
{"id":"fyi-end","ts":"2026-07-29T12:00:00Z","text":"synthetic end"}
EOF
  cat >"$P3_PROJECT/data/usage/beacons.jsonl" <<'EOF'
{"ts":"2026-07-22T12:00:00Z","action":"open","path":"/safe?drop=fixture"}
{"ts":"2026-07-29T12:00:00Z","action":"close","path":"/after"}
EOF
  before="$(phase3_hashes)"

  run run_phase3

  [ "$status" -eq 0 ]
  [ "$before" = "$(phase3_hashes)" ]
  jq -e '
    ([.coverage[] | select(.source=="events")][0]
      | .records_valid==1 and .records_out_of_window==3)
    and ([.coverage[] | select(.source=="fyi")][0]
      | .records_valid==1 and .records_out_of_window==2)
    and ([.coverage[] | select(.source=="usage")][0]
      | .records_valid==1 and .records_out_of_window==1)
    and ([.evidence[] | select(.kind=="usage_beacon")][0].fields.path=="/safe")
  ' <<<"$output"
  [[ "$output" != *"synthetic current"* ]]
  [ ! -s "$SHIM_LOG/systemctl.rejected" ]
  [ ! -s "$SHIM_LOG/journalctl.rejected" ]
  [ ! -s "$SHIM_LOG/runner.rejected" ]
  [ ! -s "$NOTIFY_LOG" ]
}

@test "inspect: canonical evidence ids pin JSONL lines and structured pointers" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-canonical"
  mkdir -p "$root"
  make_phase3_project canonical "build" "$root"
  line='{"ts":"2026-07-29T10:00:00Z","svc":"canonical-build","event":"job.end","status":"fail","reason":"fixture"}'
  printf '%s\n%s\n' "$line" "$line" >"$root/2026-07-29.jsonl"

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    [.evidence[] | select(.kind=="job_end")] as $jobs
    | ($jobs|length)==2
      and ($jobs[0].id != $jobs[1].id)
      and ($jobs[0].recurrence_key==$jobs[1].recurrence_key)
      and ([ $jobs[].source_ref | endswith(":line:1") or endswith(":line:2") ] | all)
  ' <<<"$output"
  run python3 -c '
import hashlib,json,sys
d=json.load(sys.stdin)
for e in [x for x in d["evidence"] if x["kind"]=="job_end"]:
    op=json.dumps(e["fields"],sort_keys=True,separators=(",",":"),
                  ensure_ascii=False,allow_nan=False)
    assert e["id"]==hashlib.sha256(
        ("event\0"+e["source_ref"]+"\0"+op).encode()).hexdigest()[:20]
' <<<"$output"
  [ "$status" -eq 0 ]
}

@test "inspect: exact event routing emits at most one evidence row per line" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-routing"
  mkdir -p "$root"
  make_phase3_project routing "design release medic" "$root"
  cat >"$root/2026-07-29.jsonl" <<'EOF'
{"ts":"2026-07-29T08:00:00Z","svc":"routing-release","event":"job.end","status":"ok"}
{"ts":"2026-07-29T08:01:00Z","svc":"routing-medic","event":"medic.incident","incident_id":"inc-route"}
{"ts":"2026-07-29T08:02:00Z","svc":"routing-release","event":"release.critique","source":"shoulder","block":1}
{"ts":"2026-07-29T08:03:00Z","svc":"routing-design","event":"design.proposal.opened","proposal_id":"p-route","type":"feature"}
{"ts":"2026-07-29T08:04:00Z","svc":"routing-release","event":"release.critique.skipped","source":"shoulder","reason":"budget"}
{"ts":"2026-07-29T08:05:00Z","svc":"routing-release","event":"release.critique.skipped","source":"shoulder","reason":"empty_diff"}
EOF

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    [.evidence[] | select(.source=="events")] as $events
    | ($events|length)==5
      and ([$events[].source_ref]|unique|length)==5
      and ([$events[].kind]|sort)==
        ["budget_control_event","critique_event","design_control_event",
         "incident_event","job_end"]
  ' <<<"$output"
}

@test "inspect: malformed missing-ts and out-of-window records remain coverage" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-malformed"
  mkdir -p "$root"
  make_phase3_project malformed "build" "$root"
  cat >"$root/2026-07-29.jsonl" <<'EOF'
not-json
{"svc":"malformed-build","event":"job.end","status":"ok"}
{"ts":"2026-07-29T12:00:00Z","svc":"malformed-build","event":"job.end","status":"ok"}
{"ts":"2026-07-29T11:00:00Z","svc":"malformed-build","event":"job.end","status":"ok"}
EOF

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.coverage[] | select(.source=="events")][0]
      | .state=="partial" and .reason=="malformed"
        and .records_total==2 and .records_valid==1
        and .records_invalid==0 and .records_out_of_window==1)
    and ([.coverage[] | select(.source=="events_attribution")][0]
      | .state=="partial" and .records_total==4
        and .records_valid==1 and .records_invalid==2
        and .records_out_of_window==1)
  ' <<<"$output"
}

@test "inspect: distinguishes fail abort partial and unknown job statuses" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-status"
  mkdir -p "$root"
  make_phase3_project statuses "build" "$root"
  cat >"$root/2026-07-29.jsonl" <<'EOF'
{"ts":"2026-07-29T08:00:00Z","svc":"statuses-build","event":"job.end","status":"fail","reason":"x"}
{"ts":"2026-07-29T08:01:00Z","svc":"statuses-build","event":"job.end","status":"abort","reason":"x"}
{"ts":"2026-07-29T08:02:00Z","svc":"statuses-build","event":"job.end","status":"partial","reason":"x"}
{"ts":"2026-07-29T08:03:00Z","svc":"statuses-build","event":"job.end","status":"future","reason":"x"}
EOF

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].jobs.by_status ==
      {"ok":0,"fail":1,"partial":1,"abort":1,"skipped":0,"other":1}
    and .fleet[0].state=="fault_observed"
    and ([.evidence[] | select(.kind=="job_end") | .fields.status]|sort)
      == ["abort","fail","future","partial"]
  ' <<<"$output"
}

@test "inspect: duration nearest-rank percentiles pin odd and even samples" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-duration"
  mkdir -p "$root"
  make_phase3_project duration "build" "$root"
  for n in 1 2 3 4 5; do
    printf '{"ts":"2026-07-29T08:00:0%sZ","svc":"duration-build","event":"job.end","status":"ok","duration_s":%s}\n' \
      "$n" "$n" >>"$root/2026-07-29.jsonl"
  done

  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '.fleet[0].jobs.duration_seconds_p50==3
    and .fleet[0].jobs.duration_seconds_p95==5' <<<"$output"

  printf '%s\n' \
    '{"ts":"2026-07-29T08:00:06Z","svc":"duration-build","event":"job.end","status":"ok","duration_s":6}' \
    >>"$root/2026-07-29.jsonl"
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '.fleet[0].jobs.duration_seconds_p50==3
    and .fleet[0].jobs.duration_seconds_p95==6' <<<"$output"
}

@test "inspect: dedupes incidents and rejects missing incident ids" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-incidents"
  mkdir -p "$root"
  make_phase3_project incidents "medic" "$root"
  cat >"$root/2026-07-29.jsonl" <<'EOF'
{"ts":"2026-07-29T08:00:00Z","svc":"incidents-medic","event":"medic.incident.detected","incident_id":"inc-1","probe":"web"}
{"ts":"2026-07-29T09:00:00Z","svc":"incidents-medic","event":"medic.incident.classified","incident_id":"inc-1","outcome":"restart"}
{"ts":"2026-07-29T10:00:00Z","svc":"incidents-medic","event":"medic.incident.resolved","incident_id":"inc-1","outcome":"healthy"}
{"ts":"2026-07-29T11:00:00Z","svc":"incidents-medic","event":"medic.incident","probe":"missing-id"}
EOF

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    (.fleet[0].incidents|length)==1
    and .fleet[0].incidents[0].incident_id=="inc-1"
    and .fleet[0].incidents[0].first_observed_at=="2026-07-29T08:00:00Z"
    and .fleet[0].incidents[0].last_observed_at=="2026-07-29T10:00:00Z"
    and .fleet[0].incidents[0].latest_event=="medic.incident.resolved"
    and ([.coverage[] | select(.source=="events")][0].records_invalid==1)
  ' <<<"$output"
}

@test "inspect: event directory precedence rejects mixed roots" {
  make_phase3_core
  root_a="$BATS_TEST_TMPDIR/events-a"
  root_b="$BATS_TEST_TMPDIR/events-b"
  mkdir -p "$root_a" "$root_b"
  make_phase3_project mixed "build" "$root_a"
  write_phase3_service mixed-release release "$P3_PROJECT" "$root_b"

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.coverage[] | select(.source=="events")][0]
      | .state=="error" and .reason=="mixed"
        and .records_total==0)
    and .fleet[0].pressure.daily_budget_consumers[1].event_root_state=="mixed"
  ' <<<"$output"
}

@test "inspect: shared event hub attributes exact service stems without contamination" {
  make_phase3_core
  shared="$BATS_TEST_TMPDIR/events-shared"
  mkdir -p "$shared"
  make_phase3_project alpha "build" "$shared"
  alpha="$P3_PROJECT"
  make_phase3_project beta "build" "$shared"
  cat >"$shared/2026-07-29.jsonl" <<'EOF'
{"ts":"2026-07-29T08:00:00Z","svc":"alpha-build","event":"job.end","status":"ok","tokens":11}
{"ts":"2026-07-29T08:01:00Z","svc":"beta-build","event":"job.end","status":"fail","tokens":22}
EOF

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.fleet[] | select(.project_name=="alpha")][0]
      | .jobs.by_status.ok==1 and .jobs.by_status.fail==0)
    and ([.fleet[] | select(.project_name=="beta")][0]
      | .jobs.by_status.ok==0 and .jobs.by_status.fail==1)
    and ([.coverage[] | select(.source=="events_attribution")][0]
      | .records_valid==2 and .records_unattributed==0
        and .records_ambiguous==0)
  ' <<<"$output"
}

@test "inspect: unknown event service is global unattributed coverage only" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-unattributed"
  mkdir -p "$root"
  make_phase3_project known "build" "$root"
  cat >"$root/2026-07-29.jsonl" <<'EOF'
{"ts":"2026-07-29T08:00:00Z","svc":"known-build","event":"job.end","status":"ok"}
{"ts":"2026-07-29T08:01:00Z","svc":"unknown-build","event":"job.end","status":"fail"}
EOF

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].jobs.by_status.ok==1 and .fleet[0].jobs.by_status.fail==0
    and ([.coverage[] | select(.source=="events_attribution")][0]
      | .records_valid==1 and .records_unattributed==1)
    and ([.evidence[] | select(.fields.svc?=="unknown-build")]|length)==0
  ' <<<"$output"
}

@test "inspect: per-project event roots may differ without conflict" {
  make_phase3_core
  root_a="$BATS_TEST_TMPDIR/events-alpha"
  root_b="$BATS_TEST_TMPDIR/events-beta"
  mkdir -p "$root_a" "$root_b"
  make_phase3_project alpha "build" "$root_a"
  make_phase3_project beta "build" "$root_b"
  printf '%s\n' \
    '{"ts":"2026-07-29T08:00:00Z","svc":"alpha-build","event":"job.end","status":"ok"}' \
    >"$root_a/2026-07-29.jsonl"
  printf '%s\n' \
    '{"ts":"2026-07-29T08:00:00Z","svc":"beta-build","event":"job.end","status":"ok"}' \
    >"$root_b/2026-07-29.jsonl"

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.coverage[] | select(.source=="events")] | length)==2
    and ([.coverage[] | select(.source=="events") | .state=="available"] | length)==2
    and ([.fleet[].jobs.by_status.ok]|add)==2
  ' <<<"$output"
}

@test "inspect: same-day budget consumers separate runner critic and gate scope" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-budget"
  mkdir -p "$root"
  make_phase3_project budget "design build release medic scribe" "$root"
  write_phase3_watcher "$P3_PROJECT" "$root"
  cat >"$root/2026-07-29.jsonl" <<'EOF'
{"ts":"2026-07-29T08:00:00Z","svc":"budget-design","event":"design.proposal.opened","proposal_id":"p1","type":"feature","tokens":10}
{"ts":"2026-07-29T08:01:00Z","svc":"budget-build","event":"job.end","status":"ok","tokens":15}
{"ts":"2026-07-29T08:02:00Z","svc":"budget-release","event":"job.end","status":"ok","tokens":20}
{"ts":"2026-07-29T08:03:00Z","svc":"budget-release","event":"release.critique","source":"shoulder","tokens":25}
{"ts":"2026-07-29T08:04:00Z","svc":"budget-medic","event":"job.end","status":"ok","tokens":30}
{"ts":"2026-07-29T08:05:00Z","svc":"budget-scribe","event":"job.end","status":"ok","tokens":40}
{"ts":"2026-07-29T08:06:00Z","event":"job.start"}
{"ts":"2026-07-29T08:07:00Z","svc":"budget-release","event":"release.critique","source":"shoulder","block":-1}
EOF

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].pressure.daily_budget_consumers as $d
    | ($d|map(.consumer)) == [
        "design_runner","build_runner","release_runner",
        "release_shoulder_critic","medic_runner","scribe_runner"]
      and ($d|map(.attributed_tokens_today)) == [10,15,20,25,30,40]
      and ($d|map(.gate_tokens_today)) == [10,15,20,25,30,40]
      and ($d|map(.gate_scope)) ==
        ["unscoped_event_root","exact_service","exact_service",
         "unscoped_event_root","exact_service","exact_service"]
      and ($d|map(.configured_daily_budget)) == [100,100,100,100,100,100]
      and ($d|map(.gate_records_invalid_today)) == [2,2,2,2,2,2]
  ' <<<"$output"
}

@test "inspect: absent unset non-design sentinel is zero not core-fallback use" {
  make_phase3_core
  make_phase3_project sentinel "build"
  printf '%s\n' \
    '{"ts":"2026-07-29T08:00:00Z","svc":"sentinel-build","event":"job.end","status":"ok","tokens":55}' \
    >"$P3_CORE/data/events/2026-07-29.jsonl"

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].pressure.daily_budget_consumers[1]
      | .consumer=="build_runner"
        and .event_root_state=="unset_sentinel"
        and .event_root=="/nonexistent"
        and .attributed_tokens_today==55
        and .gate_tokens_today==0
  ' <<<"$output"
  [ ! -e /nonexistent ]
}

@test "inspect: gate operand reproduces jq pipeline and shell normalization" {
  file="$BATS_TEST_TMPDIR/gate.jsonl"
  other="$BATS_TEST_TMPDIR/gate-other.jsonl"
  cp "$FIXTURES_DIR/shipyard-inspect/telemetry/gate-operand.jsonl" "$file"
  cat >"$other" <<'EOF'
{"ts":"2026-07-29T08:00:00Z","event":"job.end","svc":"fixture-build","tokens":11}
{"ts":"2026-07-29T08:01:00Z","event":"design.proposal.opened","svc":"fixture-design","tokens":9}
{"ts":"2026-07-29T08:02:00Z","event":"job.start"}
{"ts":"2026-07-29T08:03:00Z","event":"job.end","svc":"bad-build","tokens":"bad"}
EOF
  module="$QUARTET_ROOT/skills/shipyard/inspect.py"

  run python3 - "$module" "$file" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shipyard_inspect", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod.compute_gate_operand(sys.argv[2], "design_runner", "fixture-design"))
print(mod.compute_gate_operand(sys.argv[2], "build_runner", "fixture-build"))
print(mod.compute_gate_operand(sys.argv[2] + ".missing", "build_runner", "fixture-build"))
PY

  [ "$status" -eq 0 ]
  [ "$output" = $'4\n6\n0' ]

  printf '%s\n' \
    '{"event":"design.proposal.opened","tokens":1.5}' >"$file"
  run python3 - "$module" "$file" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shipyard_inspect", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print(mod.compute_gate_operand(sys.argv[2], "design_runner", "fixture-design"))
PY
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]

  cp "$FIXTURES_DIR/shipyard-inspect/telemetry/gate-operand.jsonl" "$file"
  run python3 - "$module" "$file" "$other" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shipyard_inspect", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
gate_cache = {}
decode_cache = {}
strict_cache = {}
real_run = mod.subprocess.run
first_stage_calls = 0
second_stage_calls = 0
def counting_run(argv, *args, **kwargs):
    global first_stage_calls, second_stage_calls
    if argv[1:3] == ["-R", "fromjson?"]:
        first_stage_calls += 1
    elif argv[1:2] == ["-s"]:
        second_stage_calls += 1
    return real_run(argv, *args, **kwargs)
mod.subprocess.run = counting_run
cases = [
    (sys.argv[2], "design_runner", "svc-a"),
    (sys.argv[2], "design_runner", "svc-b"),
    (sys.argv[2], "build_runner", "fixture-build"),
    (sys.argv[2], "build_runner", "other-build"),
    (sys.argv[3], "build_runner", "fixture-build"),
]
cached = [
    mod._cached_gate_operand(
        path, consumer, svc, gate_cache, decode_cache
    )
    for path, consumer, svc in cases
]
cached_counts = (first_stage_calls, second_stage_calls, len(decode_cache))
first_stage_calls = second_stage_calls = 0
direct = [
    mod.compute_gate_operand(path, consumer, svc)
    for path, consumer, svc in cases
]
direct_counts = (first_stage_calls, second_stage_calls)
failed_first_calls = 0
failed_second_calls = 0
def failing_first_stage(argv, *args, **kwargs):
    global failed_first_calls, failed_second_calls
    if argv[1:3] == ["-R", "fromjson?"]:
        failed_first_calls += 1
        return mod.subprocess.CompletedProcess(argv, 23, "", "fixture failure")
    failed_second_calls += 1
    return real_run(argv, *args, **kwargs)
mod.subprocess.run = failing_first_stage
failed_cache = {}
failed = [
    mod.compute_gate_operand(
        sys.argv[2], consumer, svc, decode_cache=failed_cache
    )
    for consumer, svc in (
        ("design_runner", "fixture-design"),
        ("build_runner", "fixture-build"),
    )
]
mod.subprocess.run = real_run
missing_cache = {}
missing = [
    mod.compute_gate_operand(
        sys.argv[2] + ".missing",
        "build_runner",
        "fixture-build",
        decode_cache=missing_cache,
    )
    for _ in range(2)
]
strict = [
    mod._cached_strict_gate_invalid_count(sys.argv[2], strict_cache),
    mod._cached_strict_gate_invalid_count(sys.argv[2], strict_cache),
    mod._cached_strict_gate_invalid_count(sys.argv[3], strict_cache),
]
print(cached)
print(direct)
print(cached_counts, direct_counts)
print(failed, failed_first_calls, failed_second_calls, len(failed_cache))
print(missing, len(missing_cache))
print(len(gate_cache), strict, len(strict_cache))
PY
  [ "$status" -eq 0 ]
  [ "$output" = $'[4, 4, 6, 0, 11]\n[4, 4, 6, 0, 11]\n(2, 4, 2) (5, 5)\n[0, 0] 1 0 1\n[0, 0] 1\n4 [(3, True), (3, True), (2, True)] 2' ]
}

@test "inspect: duplicate keys affect gate compatibility but never evidence" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-duplicate"
  mkdir -p "$root"
  make_phase3_project duplicate "design" "$root"
  cp "$FIXTURES_DIR/shipyard-inspect/telemetry/duplicate-nonfinite.jsonl" \
    "$root/2026-07-29.jsonl"

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.evidence[] | select(.source=="events" and .kind!="coverage_gap")]|length)==0
    and ([.coverage[] | select(.source=="events_attribution")][0]
      | .records_invalid==2)
    and .fleet[0].pressure.daily_budget_consumers[0].gate_tokens_today==9
    and (.fleet[0].limitations | index("gate_parser_differs_from_v1"))!=null
  ' <<<"$output"
}

@test "inspect: shoulder gate root is proven from watcher manifest or unknown" {
  make_phase3_core
  crew_root="$BATS_TEST_TMPDIR/events-crew"
  watcher_root="$BATS_TEST_TMPDIR/events-watcher"
  mkdir -p "$crew_root" "$watcher_root"
  make_phase3_project shoulder "release" "$crew_root"
  cat >>"$P3_PROJECT/.agents/config.toml" <<'EOF'
[shoulder]
auto_wire = true
EOF
  write_phase3_watcher "$P3_PROJECT" "$watcher_root"
  printf '%s\n' \
    '{"ts":"2026-07-29T08:00:00Z","svc":"foreign-release","event":"release.critique","source":"shoulder","tokens":100}' \
    >"$watcher_root/2026-07-29.jsonl"

  run run_phase3
  [ "$status" -eq 0 ]
  jq -e --arg root "$(realpath "$watcher_root")" '
    .fleet[0].pressure.daily_budget_consumers[3]
      | .applicability=="applicable"
        and .event_root_state=="configured" and .event_root==$root
        and .attributed_tokens_today==0 and .gate_tokens_today==100
  ' <<<"$output"
  jq -e '
    . as $doc
    | .fleet[0].state=="degraded_observed"
      and (.fleet[0].state_reason_ids|length)>0
      and all(.fleet[0].state_reason_ids[]; . as $id
        | any($doc.evidence[]; .id==$id))
  ' <<<"$output"

  project_default="$P3_PROJECT/data/events"
  mkdir -p "$project_default"
  write_phase3_watcher "$P3_PROJECT" "$project_default"
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e --arg root "$(realpath "$project_default")" '
    .fleet[0].pressure.daily_budget_consumers[3]
      | .event_root_state=="project_default" and .event_root==$root
  ' <<<"$output"

  rm "$UNIT_DIR/shoulder-release-watch.service"
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].pressure.daily_budget_consumers[3]
      | .applicability=="applicable" and .event_root_state=="unknown"
        and .event_root==null and .gate_tokens_today==null
  ' <<<"$output"
}

@test "inspect: under-cap use is healthy while exhaustion and deferral degrade" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-pressure"
  mkdir -p "$root"
  make_phase3_project pressure "design" "$root"
  printf '%s\n' \
    '{"ts":"2026-07-29T08:00:00Z","svc":"pressure-design","event":"design.proposal.opened","proposal_id":"p1","type":"feature","tokens":50}' \
    >"$root/2026-07-29.jsonl"

  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].state=="no_fault_observed"
    and .fleet[0].pressure.daily_budget_consumers[0].gate_fraction_today==0.5
  ' <<<"$output"

  printf '%s\n' \
    '{"ts":"2026-07-29T09:00:00Z","svc":"pressure-design","event":"design.proposal.opened","proposal_id":"p2","type":"feature","tokens":50}' \
    >>"$root/2026-07-29.jsonl"
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].state=="degraded_observed"
    and .fleet[0].pressure.daily_budget_consumers[0].gate_fraction_today==1
    and (.fleet[0].state_reason_ids|length)>0
  ' <<<"$output"

  printf '%s\n' \
    '{"ts":"2026-07-29T10:00:00Z","svc":"pressure-design","event":"design.unrouted","tokens":100}' \
    >"$root/2026-07-29.jsonl"
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '
    . as $doc
    | .fleet[0].state=="degraded_observed"
      and .fleet[0].pressure.daily_budget_consumers[0].gate_tokens_today==100
      and ([.evidence[] | select(.source=="events" and .kind!="coverage_gap")]|length)==0
      and (.fleet[0].state_reason_ids|length)>0
      and all(.fleet[0].state_reason_ids[]; . as $id
        | any($doc.evidence[]; .id==$id))
  ' <<<"$output"

  printf '%s\n' \
    '{"ts":"2026-07-29T10:00:00Z","svc":"foreign-design","event":"design.unrouted","tokens":100}' \
    >"$root/2026-07-29.jsonl"
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '
    . as $doc
    | .fleet[0].state=="degraded_observed"
      and .fleet[0].pressure.daily_budget_consumers[0].attributed_tokens_today==0
      and .fleet[0].pressure.daily_budget_consumers[0].gate_tokens_today==100
      and ([.coverage[] | select(.source=="events_attribution")][0]
        .records_unattributed==1)
      and all(.fleet[0].state_reason_ids[]; . as $id
        | any($doc.evidence[]; .id==$id))
  ' <<<"$output"

  : >"$root/2026-07-29.jsonl"
  fixture_replace_in_place "$P3_PROJECT/.agents/config.toml" \
    'budget_tokens_daily = 100' 'budget_tokens_daily = 0' 1
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '
    . as $doc
    | .fleet[0].state=="degraded_observed"
      and .fleet[0].pressure.daily_budget_consumers[0].configured_daily_budget==0
      and .fleet[0].pressure.daily_budget_consumers[0].gate_tokens_today==0
      and all(.fleet[0].state_reason_ids[]; . as $id
        | any($doc.evidence[]; .id==$id))
  ' <<<"$output"
}

@test "inspect: budget and open-cap deferrals are not job failures" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-deferrals"
  mkdir -p "$root"
  make_phase3_project deferrals "design build" "$root"
  cat >"$root/2026-07-29.jsonl" <<'EOF'
{"ts":"2026-07-29T08:00:00Z","svc":"deferrals-design","event":"design.proposal.skipped","reason":"budget","tokens_used":100,"budget":100}
{"ts":"2026-07-29T08:01:00Z","svc":"deferrals-design","event":"design.proposal.skipped","reason":"open_cap","open":1,"cap":1}
{"ts":"2026-07-29T08:02:00Z","svc":"deferrals-build","event":"design.proposal.skipped","reason":"budget","tokens_used":100,"budget":100}
{"ts":"2026-07-29T08:03:00Z","svc":"deferrals-build","event":"design.proposal.skipped","reason":"open_cap","open":1,"cap":1}
EOF

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].jobs.by_status ==
      {"ok":0,"fail":0,"partial":0,"abort":0,"skipped":0,"other":0}
    and .fleet[0].pressure.budget_deferrals_by_consumer.design_runner==1
    and .fleet[0].pressure.open_cap_deferrals==1
    and ([.evidence[] | select(.kind=="budget_control_event")]|length)==2
    and ([.evidence[] | select(.kind=="design_control_event")]|length)==2
    and .fleet[0].state=="degraded_observed"
  ' <<<"$output"
}

@test "inspect: present empty and unavailable sources are distinct" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-empty"
  mkdir -p "$root"
  make_phase3_project empty "build" "$root"
  : >"$P3_PROJECT/data/fyi-requests.jsonl"
  : >"$P3_PROJECT/data/usage/empty.jsonl"

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.coverage[] | select(.source=="events")][0]
      | .state=="available" and .reason=="ok" and .records_total==0)
    and ([.coverage[] | select(.source=="fyi")][0]
      | .state=="available" and .records_total==0)
    and ([.coverage[] | select(.source=="usage")][0]
      | .state=="available" and .records_total==0)
    and ([.coverage[] | select(.source=="incident_state")][0]
      | .state=="unavailable" and .reason=="missing")
  ' <<<"$output"
}

@test "inspect: Caddy is end-exclusive strips query and never networks" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-caddy"
  mkdir -p "$root"
  make_phase3_project caddy "medic" "$root"
  add_phase3_probe
  cp "$FIXTURES_DIR/shipyard-inspect/telemetry/caddy-journal.jsonl" \
    "$SHIM_LOG/journalctl.stdout"

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.coverage[] | select(.source=="caddy")][0]
      | .state=="available" and .records_total==2
        and .records_valid==1 and .records_invalid==0
        and .records_out_of_window==1)
    and ([.evidence[] | select(.kind=="caddy_path_count")][0].fields
      | .domain=="example.test" and .path=="/callback" and .requests==1)
  ' <<<"$output"
  [[ "$output" != *"debug=fixture"* ]]
  [[ "$output" != *"debug=end"* ]]
  [ "$(cat "$SHIM_LOG/journalctl.argv")" = \
    "--user -u caddy -o json --no-pager --output-fields=__REALTIME_TIMESTAMP,MESSAGE --since 2026-07-22T12:00:00Z --until 2026-07-29T12:00:00Z" ]
  journal_calls="$(wc -l <"$SHIM_LOG/journalctl.argv")"
  fixture_replace_in_place "$P3_PROJECT/.agents/config.toml" \
    'https://Example\.TEST/health\?fixture=ignored' 'https://[broken'
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '
    ([.coverage[] | select(.source=="caddy")][0]
      | .state=="partial" and .reason=="malformed"
        and .records_total==1 and .records_valid==0
        and .records_invalid==1)
  ' <<<"$output"
  [ "$(wc -l <"$SHIM_LOG/journalctl.argv")" -eq "$journal_calls" ]
  [ ! -s "$SHIM_LOG/journalctl.rejected" ]
  [ ! -s "$SHIM_LOG/systemctl.rejected" ]
  [ ! -s "$SHIM_LOG/runner.rejected" ]
  [ ! -s "$NOTIFY_LOG" ]
  for command in curl wget nc gh claude codex hermes; do
    [ ! -s "$SHIM_LOG/$command.rejected" ]
  done
}

@test "inspect: current incident state uses configured result file and redacts summary" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-state"
  mkdir -p "$root"
  make_phase3_project current "medic" "$root"
  cp "$FIXTURES_DIR/shipyard-inspect/telemetry/incidents-current.json" \
    "$P3_PROJECT/tmp/medic-incidents-current.json"

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.coverage[] | select(.source=="incident_state")][0]
      | .state=="partial" and .records_total==3
        and .records_valid==1 and .records_invalid==2)
    and ([.evidence[] | select(.kind=="incident_state")]|length)==3
    and ([.evidence[] | select(.kind=="incident_state")
      | select(.fields.incident_id=="inc-current")][0]
      | .source_ref|endswith(":pointer:/0"))
    and ([.evidence[] | select(.kind=="incident_state")
      | select(.fields.incident_id=="inc-current")][0].fields.summary_present==true)
    and ([.evidence[] | select(.kind=="incident_state")
      | select(.fields.incident_id=="inc-bad-status")][0].fields.http_status==null)
    and (.fleet[0].limitations|index("incident_summary_redacted"))!=null
  ' <<<"$output"
  [[ "$output" != *"SYNTHETIC_REDACT_ME"* ]]
}

@test "inspect: configured result dir and themed design display locate proposals" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-results"
  mkdir -p "$root"

  make_phase3_project plain "design" "$root"
  write_phase4_result tmp design "[$(phase4_proposal plain-open)]"

  make_phase3_project spacetime "design" "$root"
  fixture_replace_in_place "$P3_PROJECT/.agents/config.toml" \
    'result_dir = "tmp"' 'result_dir = "observations"'
  cat >>"$P3_PROJECT/.agents/config.toml" <<'EOF'
[names]
design = "mentat"
EOF
  write_phase4_result observations mentat "[$(phase4_proposal space-open)]"

  make_phase3_project custom "design" "$root"
  fixture_replace_in_place "$P3_PROJECT/.agents/config.toml" \
    'result_dir = "tmp"' 'result_dir = "state/design"'
  cat >>"$P3_PROJECT/.agents/config.toml" <<'EOF'
[names]
design = "navigator"
EOF
  write_phase4_result state/design navigator "[$(phase4_proposal custom-open)]"

  make_phase3_project absolute "design" "$root"
  fixture_replace_in_place "$P3_PROJECT/.agents/config.toml" \
    'result_dir = "tmp"' 'result_dir = "/abs"'
  write_phase4_result abs design "[$(phase4_proposal absolute-open)]"

  make_phase3_project empty "design" "$root"
  fixture_replace_in_place "$P3_PROJECT/.agents/config.toml" \
    'result_dir = "tmp"' 'result_dir = ""'
  write_phase4_result . design "[$(phase4_proposal empty-open)]"

  make_phase3_project integer "design" "$root"
  fixture_replace_in_place "$P3_PROJECT/.agents/config.toml" \
    'result_dir = "tmp"' 'result_dir = 7'
  write_phase4_result 7 design "[$(phase4_proposal integer-open)]"

  make_phase3_project structured "design" "$root"
  fixture_replace_in_place "$P3_PROJECT/.agents/config.toml" \
    'result_dir = "tmp"' 'result_dir = ["not","silently","tmp"]'

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.evidence[] | select(.kind=="open_proposal") | .fields.id] | sort)
      ==["absolute-open","custom-open","empty-open","integer-open",
         "plain-open","space-open"]
    and ([.coverage[] | select(.source=="proposals" and .state=="available")]
      | length)==6
    and ([.coverage[] | select(.source=="proposals"
      and .state=="partial" and .reason=="malformed")]|length)==1
    and ([.evidence[] | select(.kind=="open_proposal")
      | .source_ref | select(contains("/observations/spacetime-mentat-result.json:pointer:/proposals/0"))]
      | length)==1
    and ([.evidence[] | select(.kind=="open_proposal")
      | .source_ref | select(contains("/state/design/custom-navigator-result.json:pointer:/proposals/0"))]
      | length)==1
    and ([.evidence[] | select(.kind=="open_proposal")
      | .source_ref | select(contains("/absolute/abs/absolute-design-result.json:pointer:/proposals/0"))]
      | length)==1
    and ([.evidence[] | select(.kind=="open_proposal")
      | .source_ref | select(contains("/empty/empty-design-result.json:pointer:/proposals/0"))]
      | length)==1
    and ([.evidence[] | select(.kind=="open_proposal")
      | .source_ref | select(contains("/integer/7/integer-design-result.json:pointer:/proposals/0"))]
      | length)==1
  ' <<<"$output"
}

@test "inspect: suppresses exact approve deny decisions and counts malformed rows" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-decisions"
  mkdir -p "$root"
  make_phase3_project decisions "design" "$root"
  cat >"$P3_PROJECT/tmp/decisions-design-result.json" <<'EOF'
{"ts":"2026-07-28T09:30:00Z","project":"decisions","proposals":[
{"id":"approved","type":"feature","title":"Approved","severity":"med","status":"open","signal_ids":[]},
{"id":"denied","type":"bug","title":"Denied","severity":"high","status":"open","signal_ids":[]},
{"id":"malformed-only","type":"instrumentation","title":"Malformed target","severity":"low","status":"open"},
{"id":"unknown-only","type":"feature","title":"Unknown target","severity":"med","status":"open","signal_ids":[]},
{"id":"bad-ts-only","type":"feature","title":"Bad timestamp target","severity":"med","status":"open","signal_ids":[]},
{"id":"signals-absent","type":"feature","title":"Signals absent","severity":"med","status":"open"},
{"id":"signals-sorted","type":"feature","title":"Signals sorted","severity":"med","status":"open","signal_ids":["z","a","z"],"rationale":"RAW_RATIONALE","evidence":"RAW_EVIDENCE"},
{"id":"","type":"feature","title":"Empty id","severity":"med","status":"open","signal_ids":[]},
{"id":"empty-title","type":"feature","title":"","severity":"med","status":"open","signal_ids":[]},
{"id":"unknown-type","type":"other","title":"Unknown type","severity":"med","status":"open","signal_ids":[]},
{"id":"unknown-severity","type":"feature","title":"Unknown severity","severity":"urgent","status":"open","signal_ids":[]},
{"id":"closed-status","type":"feature","title":"Closed","severity":"med","status":"closed","signal_ids":[]},
{"id":"bad-signals","type":"feature","title":"Bad signals","severity":"med","status":"open","signal_ids":[""]}
]}
EOF
  mkdir -p "$P3_PROJECT/data"
  cat >"$P3_PROJECT/data/decisions.jsonl" <<'EOF'
{"proposal_id":"approved","decision":"approve","ts":"2026-07-28T10:00:00Z","reason":"SYNTHETIC_SECRET"}
{"proposal_id":"denied","decision":"deny","ts":"2026-07-28T10:01:00Z"}
{"id":"malformed-only","decision":"approve","ts":"2026-07-28T10:02:00Z"}
{"proposal_id":"unknown-only","decision":"later","ts":"2026-07-28T10:03:00Z"}
{"proposal_id":"bad-ts-only","decision":"deny","ts":"not-a-time"}
EOF

  make_phase3_project duplicate-result "design" "$root"
  cat >"$P3_PROJECT/tmp/duplicate-result-design-result.json" <<'EOF'
{"ts":"2026-07-28T09:30:00Z","ts":"2026-07-28T09:31:00Z","project":"duplicate-result","proposals":[]}
EOF
  make_phase3_project nonfinite-result "design" "$root"
  cat >"$P3_PROJECT/tmp/nonfinite-result-design-result.json" <<'EOF'
{"ts":"2026-07-28T09:30:00Z","project":"nonfinite-result","score":NaN,"proposals":[]}
EOF
  make_phase3_project invalid-source-ts "design" "$root"
  cat >"$P3_PROJECT/tmp/invalid-source-ts-design-result.json" <<'EOF'
{"ts":"invalid","project":"invalid-source-ts","proposals":[{"id":"bad-source-ts","type":"feature","title":"Bad source ts","severity":"med","status":"open","signal_ids":[]}]}
EOF

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.fleet[] | select(.project_name=="decisions")][0].project_id) as $pid
    | (([.evidence[] | select(.kind=="open_proposal") | .fields.id] | sort)
      ==["bad-ts-only","malformed-only","signals-absent","signals-sorted",
         "unknown-only"]
    and ([.evidence[] | select(.kind=="open_proposal"
      and .fields.id=="signals-sorted")][0].fields.signal_ids)==["a","z"]
    and ([.coverage[] | select(.project_id==$pid and .source=="proposals")][0]
      | .state=="partial" and .reason=="malformed"
        and .records_total==13 and .records_valid==7 and .records_invalid==6)
    and ([.coverage[] | select(.project_id==$pid and .source=="decisions")][0]
      | .state=="partial" and .reason=="malformed"
        and .records_total==5 and .records_valid==2 and .records_invalid==3)
    and ([.evidence[] | select(.kind=="decision")]|length)==2
    and ([.evidence[] | select(.kind=="decision") | .source_ref]
      | sort | map(endswith(":line:1") or endswith(":line:2")) | all)
    and ([.coverage[] | select(.source=="proposals"
      and .state=="partial" and .reason=="malformed"
      and .records_total==1 and .records_valid==0 and .records_invalid==1)]
      | length)==3
    )
  ' <<<"$output"
  [[ "$output" != *"SYNTHETIC_SECRET"* ]]
  [[ "$output" != *"RAW_RATIONALE"* ]]
  [[ "$output" != *"RAW_EVIDENCE"* ]]
}

@test "inspect: conflicting valid decisions suppress with partial mixed coverage" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-conflict"
  mkdir -p "$root"
  make_phase3_project conflict "design" "$root"
  write_phase4_result tmp design "[$(phase4_proposal conflict-id)]"
  mkdir -p "$P3_PROJECT/data"
  cat >"$P3_PROJECT/data/decisions.jsonl" <<'EOF'
{"proposal_id":"conflict-id","decision":"approve","ts":"2026-07-28T10:00:00Z"}
{"proposal_id":"conflict-id","decision":"deny","ts":"2026-07-28T10:01:00Z"}
EOF

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.evidence[] | select(.kind=="open_proposal" and .fields.id=="conflict-id")]
      | length)==0
    and ([.coverage[] | select(.source=="decisions")][0]
      | .state=="partial" and .reason=="mixed"
        and .records_total==2 and .records_valid==2 and .records_invalid==0)
    and ([.attention[] | select(.kind=="owner_decision")]|length)==1
    and ([.attention[] | select(.kind=="owner_decision")][0].evidence_ids|length)==2
  ' <<<"$output"
}

@test "inspect: bogus signal proposal stays assessment not evidenced opportunity" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-signals"
  mkdir -p "$root"
  make_phase3_project signals "design" "$root"
  cat >"$P3_PROJECT/data/fyi-requests.jsonl" <<'EOF'
{"id":"fyi-resolved","ts":"2026-07-28T08:00:00Z","text":"SYNTHETIC_REDACT_ME"}
EOF
  proposals="[$(phase4_proposal resolved '["fyi-resolved"]'),$(phase4_proposal bogus '["fyi-missing"]')]"
  write_phase4_result tmp design "$proposals"

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.evidence[] | select(.kind=="fyi_request")][0].id) as $fyi_evidence
    | ([.attention[] | select(.kind=="open_proposal")
      | select(.title=="Proposal bogus")][0]
      | .claim_kind=="assessment"
        and (.limitations|index("unresolved_signal_ids"))!=null)
    and ([.attention[] | select(.kind=="open_proposal")
      | select(.title=="Proposal resolved")][0]
      | (.limitations|index("unresolved_signal_ids"))==null
        and (.evidence_ids|length)==2
        and (.evidence_ids|index($fyi_evidence))!=null)
    and ([.priorities[] | select(.category=="evidenced_opportunity")
      | .title=="Proposal bogus"]|length)==0
  ' <<<"$output"
  [[ "$output" != *"SYNTHETIC_REDACT_ME"* ]]
}

@test "inspect: missing persisted approval action is explicit" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-approval"
  mkdir -p "$root"
  make_phase3_project approval "design" "$root"
  write_phase4_result tmp design "[$(phase4_proposal approval-missing)]"

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.evidence[] | select(.kind=="open_proposal")][0]
      .fields.approval_action_present)==false
    and ([.attention[] | select(.kind=="open_proposal")][0]
      | .approval_action==null
        and (.limitations|index("approval_action_not_persisted"))!=null)
  ' <<<"$output"
}

@test "inspect: undecided proposals populate current open-cap pressure" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-open-cap"
  mkdir -p "$root"
  make_phase3_project capped "design" "$root"
  write_phase4_result tmp design "[$(phase4_proposal at-cap)]"

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].pressure.undecided_open_proposals==1
    and .fleet[0].pressure.configured_max_open_proposals==1
    and .fleet[0].pressure.open_cap_remaining==0
    and .fleet[0].state=="degraded_observed"
    and (.fleet[0].state_reason_ids|length)>0
  ' <<<"$output"
}

@test "inspect: Overseer distinguishes applicable absent and not applicable" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-overseer-applicability"
  mkdir -p "$root"
  make_phase3_project auto "build" "$root"
  fixture_replace_in_place "$P3_PROJECT/.agents/config.toml" \
    '\A' $'autonomous = true\n' 1
  write_phase4_result tmp design "[$(phase4_proposal must-not-read)]"
  cat >"$P3_PROJECT/data/decisions.jsonl" <<'EOF'
{"proposal_id":"must-not-read","decision":"approve","ts":"2026-07-28T10:00:00Z"}
EOF
  make_phase3_project manual "build" "$root"
  fixture_replace_in_place "$P3_PROJECT/.agents/config.toml" \
    '\A' $'autonomous = false\n' 1

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    .fleet as $fleet
    | ([$fleet[] | select(.project_name=="auto")][0]) as $auto
    | ([$fleet[] | select(.project_name=="manual")][0]) as $manual
    | ($auto.overseer
      | .applicability=="applicable" and .state=="absent"
        and .reason=="no_result")
    and ([.coverage[] | select(.project_id==
      $auto.project_id
      and .source=="overseer")][0]
      | .state=="unavailable" and .reason=="no_result")
    and ($manual.overseer
      | .applicability=="not_applicable" and .state=="absent"
        and .reason=="not_autonomous")
    and ([.coverage[] | select(.project_id==
      $manual.project_id
      and .source=="overseer")][0]
      | .state=="not_applicable" and .reason=="not_autonomous")
    and ([.coverage[] | select((.project_id==$auto.project_id
      or .project_id==$manual.project_id)
      and (.source=="proposals" or .source=="decisions")
      and .state=="not_applicable")]|length)==4
    and ([.evidence[] | select(.project_id==$auto.project_id
      and (.source=="proposals" or .source=="decisions"))]|length)==0
    and ([.attention[] | select((.project_id==$auto.project_id
      or .project_id==$manual.project_id)
      and (.title=="Coverage gap: proposals"
        or .title=="Coverage gap: decisions"))]|length)==0
  ' <<<"$output"
}

@test "inspect: unknown autonomy makes Overseer unavailable not inapplicable" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-overseer-unknown"
  mkdir -p "$root"
  make_phase3_project unknown "build" "$root"
  printf '\n[broken\n' >>"$P3_PROJECT/.agents/config.toml"

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].autonomous==null
    and (.fleet[0].overseer
      | .applicability=="unknown" and .state=="unavailable"
        and .reason=="config_unknown")
    and ([.coverage[] | select(.source=="overseer")][0]
      | .state=="unavailable" and .reason=="config_unknown")
  ' <<<"$output"
}

@test "inspect: attention contains faults drift gates and coverage gaps" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-attention"
  mkdir -p "$root"
  make_phase3_project needs-focus "design" "$root"
  write_phase4_result tmp design "[$(phase4_proposal needs-owner)]"
  cat >"$P3_CORE/install.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'DOCTOR symlink_drift: synthetic install drift'
exit 1
EOF
  chmod +x "$P3_CORE/install.sh"
  cat >"$SHIM_LOG/needs-focus-design.service.stdout" <<'EOF'
LoadState=loaded
ActiveState=failed
SubState=failed
Result=failed
ExecMainStatus=1
EOF

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    (["open_proposal","observed_fault","install_drift","coverage_gap"]
      - [.attention[].kind] | length)==0
    and ([.attention[] | select(.kind=="open_proposal")]|length)==1
    and ([.attention[] | select(.kind=="observed_fault")]|length)>0
    and ([.attention[] | select(.kind=="install_drift")]|length)==1
    and ([.attention[] | select(.kind=="coverage_gap")]|length)>0
    and ([.attention[].evidence_ids[]] -
      [.evidence[].id] | length)==0
    and ([.attention[].id | test("^att_[0-9a-f]{16}$")] | all)
    and .summary.attention_count==(.attention|length)
  ' <<<"$output"
}

@test "inspect: never invokes Overseer or runner check-config" {
  make_phase3_core
  mkdir -p "$P3_CORE/agents/overseer"
  cat >"$P3_CORE/agents/overseer/runner.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SHIM_LOG/overseer.rejected"
exit 97
EOF
  chmod +x "$P3_CORE/agents/overseer/runner.sh"
  root="$BATS_TEST_TMPDIR/events-readonly-phase4"
  mkdir -p "$root"
  make_phase3_project readonly "design" "$root"
  fixture_replace_in_place "$P3_PROJECT/.agents/config.toml" \
    '\A' $'autonomous = true\n' 1
  write_phase4_result tmp design "[$(phase4_proposal readonly-open)]"
  cat >"$P3_PROJECT/tmp/overseer-result.json" <<'EOF'
{"healthy":false,"status":"concerns","summary":"SYNTHETIC_REDACT_ME","findings":[{"kind":"x"}],"ts":"2026-07-28T11:00:00Z"}
EOF

  make_phase3_project overseer-duplicate "build" "$root"
  fixture_replace_in_place "$P3_PROJECT/.agents/config.toml" \
    '\A' $'autonomous = true\n' 1
  cat >"$P3_PROJECT/tmp/overseer-result.json" <<'EOF'
{"healthy":true,"healthy":false,"status":"bad","summary":"DUPLICATE_SECRET","findings":[],"ts":"2026-07-28T11:00:00Z"}
EOF
  make_phase3_project overseer-nonfinite "build" "$root"
  fixture_replace_in_place "$P3_PROJECT/.agents/config.toml" \
    '\A' $'autonomous = true\n' 1
  cat >"$P3_PROJECT/tmp/overseer-result.json" <<'EOF'
{"healthy":true,"status":"bad","summary":"NONFINITE_SECRET","findings":[],"score":Infinity,"ts":"2026-07-28T11:00:00Z"}
EOF
  make_phase3_project overseer-malformed "build" "$root"
  fixture_replace_in_place "$P3_PROJECT/.agents/config.toml" \
    '\A' $'autonomous = true\n' 1
  cat >"$P3_PROJECT/tmp/overseer-result.json" <<'EOF'
{"healthy":"yes","status":"","summary":"MALFORMED_SECRET","findings":{},"ts":"invalid"}
EOF
  before="$(phase3_hashes)"

  run run_phase3

  [ "$status" -eq 0 ]
  [ "$before" = "$(phase3_hashes)" ]
  jq -e '
    ([.fleet[] | select(.project_name=="readonly")][0]) as $valid
    | ($valid.overseer
      | .applicability=="applicable" and .state=="present"
        and .reason=="ok" and .healthy==false
        and .status=="concerns" and .summary==null
        and .findings_count==1
        and .assessed_at=="2026-07-28T11:00:00Z"
        and (.evidence_ids|length)==1)
    and ([.evidence[] | select(.kind=="overseer_assessment")][0]
      .claim_kind)=="assessment"
    and ([.fleet[] | select(.project_name|startswith("overseer-"))
      | .overseer
      | .applicability=="applicable" and .state=="malformed"
        and .reason=="malformed"]|all)
    and ([.fleet[] | select(.project_name|startswith("overseer-"))
      | .project_id] | sort) as $bad_ids
    | ([.coverage[] | select(.source=="overseer"
      and (.project_id as $id | $bad_ids|index($id))!=null)
      | .state=="partial" and .reason=="malformed"
        and .records_total==1 and .records_valid==0 and .records_invalid==1]
      | length)==3
    and ([.evidence[] | select(.kind=="overseer_assessment")]|length)==1
  ' <<<"$output"
  [[ "$output" != *"SYNTHETIC_REDACT_ME"* ]]
  [[ "$output" != *"DUPLICATE_SECRET"* ]]
  [[ "$output" != *"NONFINITE_SECRET"* ]]
  [[ "$output" != *"MALFORMED_SECRET"* ]]
  [ ! -s "$SHIM_LOG/overseer.rejected" ]
  [ ! -s "$SHIM_LOG/runner.rejected" ]
  [ ! -s "$SHIM_LOG/systemctl.rejected" ]
  [ ! -s "$NOTIFY_LOG" ]
  for command in curl wget nc gh claude codex hermes; do
    [ ! -s "$SHIM_LOG/$command.rejected" ]
  done
}

@test "inspect: historical benchmark windows and targets are labelled" {
  make_phase3_core
  root="$BATS_TEST_TMPDIR/events-benchmark-labels"
  mkdir -p "$root"
  make_phase3_project labels "build" "$root"

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    [.effectiveness[].key] == [
      "bugs_caught_and_fixed",
      "usage_assessed_projects",
      "features_shipped_end_to_end",
      "consequential_decisions_surfaced",
      "critique_actionability",
      "execute_ticket_delegation_claude",
      "execute_ticket_delegation_codex",
      "execute_ticket_delegation_hermes"
    ]
    and ([.effectiveness[0:4][]
      | [.benchmark_label,.benchmark_window_days,.target_operator,
         .target_value]]
      | all((.==["Historical 5-day trial benchmark",5,"gte",1])
        or (.==["Historical 5-day trial benchmark",5,"gte",3])))
    and ([.effectiveness[0:4][].target_value] == [1,3,1,1])
    and (.effectiveness[4]
      | .benchmark_label=="Historical 2-week benchmark"
        and .benchmark_window_days==14 and .target_operator=="gte"
        and .target_value==0.333333 and .unit=="ratio")
    and ([.effectiveness[5:8][]
      | [.benchmark_label,.benchmark_window_days,.target_operator,.target_value]]
      | all(.==["No presentation target",null,null,null]))
  ' <<<"$output"
}

@test "inspect: missing linkage is partial with null value" {
  make_phase5_benchmark_fixture

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    [.effectiveness[0:5][] | [.state,.value,.reason]] == [
      ["partial",null,"missing_bug_fix_lineage"],
      ["partial",null,"missing_usage_assessment_lineage"],
      ["partial",null,"missing_feature_delivery_lineage"],
      ["partial",null,"missing_decision_consequence_judgment"],
      ["partial",null,"missing_operator_actionability_judgment"]
    ]
    and ([.effectiveness[0:5][].evidence_ids|length] | all(.>0))
    and ([.effectiveness[0:5][].limitations|length] | all(.>0))
  ' <<<"$output"
}

@test "inspect: benchmark component facts never claim measured in v1" {
  make_phase5_benchmark_fixture

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.effectiveness[0:5][].state] | all(.=="partial" or .=="unmeasured"))
    and ([.effectiveness[0:5][].value] | all(.==null))
    and (.effectiveness[0].components.bug_proposals==1)
    and (.effectiveness[1].components.usage_projects_observed==1)
    and (.effectiveness[2].components.feature_proposals==1)
    and (.effectiveness[3].components.valid_decisions==1)
    and (.effectiveness[4].components.critique_findings==2)
  ' <<<"$output"
  [[ "$output" != *"BENCHMARK_SECRET"* ]]
}

@test "inspect: successful delegation cohort is measured with partial window coverage" {
  make_phase5_reporter_fixture
  PHASE5_COMPLETION_MARKERS="$BATS_TEST_TMPDIR/reporter-completion"
  export PHASE5_COMPLETION_MARKERS
  mkdir -p "$PHASE5_COMPLETION_MARKERS"
  cat >"$P3_CORE/scripts/delegation-report.py" <<'PY'
import json
import os
import pathlib
import sys
import time

source = sys.argv[sys.argv.index("--source") + 1]
marker_dir = pathlib.Path(os.environ["PHASE5_COMPLETION_MARKERS"])
marker_dir.joinpath(source + ".start").write_text(
    str(time.time()), encoding="utf-8"
)
time.sleep(1.1)
marker_dir.joinpath(source + ".return").write_text(
    str(time.time()), encoding="utf-8"
)
summary = {
    "sessions": 1,
    "turns": 3 if source == "claude" else 2,
    "agent_calls": 1,
    "zero_agent_sessions": 0,
    "zero_agent_pct": 0.0,
    "malformed_timestamps": 1,
}
if source == "codex":
    summary.update({"malformed_records": 1, "malformed_boundaries": 1})
print(json.dumps(summary))
PY

  run run_phase3

  [ "$status" -eq 0 ]
  claude_completed="$(jq -r '
    [.effectiveness[] | select(.key=="execute_ticket_delegation_claude")][0]
    .components.reporter_completed_at' <<<"$output")"
  codex_completed="$(jq -r '
    [.effectiveness[] | select(.key=="execute_ticket_delegation_codex")][0]
    .components.reporter_completed_at' <<<"$output")"
  python3 - "$claude_completed" "$codex_completed" \
    "$PHASE5_COMPLETION_MARKERS/claude.start" \
    "$PHASE5_COMPLETION_MARKERS/claude.return" \
    "$PHASE5_COMPLETION_MARKERS/codex.start" \
    "$PHASE5_COMPLETION_MARKERS/codex.return" <<'PY'
import datetime
import pathlib
import sys

def epoch(value):
    parsed = datetime.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    return int(parsed.replace(tzinfo=datetime.timezone.utc).timestamp())

claude = epoch(sys.argv[1])
codex = epoch(sys.argv[2])
claude_start = float(pathlib.Path(sys.argv[3]).read_text())
claude_return = float(pathlib.Path(sys.argv[4]).read_text())
codex_start = float(pathlib.Path(sys.argv[5]).read_text())
codex_return = float(pathlib.Path(sys.argv[6]).read_text())
assert sys.argv[1] != "2026-07-29T12:00:00Z"
assert sys.argv[2] != "2026-07-29T12:00:00Z"
assert max(claude_start, codex_start) < min(claude_return, codex_return)
assert int(claude_return) <= claude
assert int(codex_return) <= codex
PY
  jq -e '
    ([.effectiveness[] | select(.key=="execute_ticket_delegation_claude")][0]) as $claude
    | ([.effectiveness[] | select(.key=="execute_ticket_delegation_codex")][0]) as $codex
    | ($claude
      | .state=="measured" and .value==1 and .unit=="sessions"
        and .components.sessions==1 and .components.agent_calls==1
        and (.components.reporter_completed_at
          | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
        and .reason=="upper_bound_unsupported"
        and (.limitations|index("exclusive_upper_bound_unsupported"))!=null
        and (.evidence_ids|length)==1)
    and ($codex.components.reporter_completed_at
      | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and ([.coverage[] | select(.source=="delegation_claude")][0]
      | .state=="partial" and .reason=="upper_bound_unsupported")
    and ([.evidence[] | select(.kind=="delegation_cohort"
      and .fields.source=="claude")][0]
      | .claim_kind=="fact"
        and .observed_at==$claude.components.reporter_completed_at
        and .fields.reporter_completed_at==$claude.components.reporter_completed_at)
    and ([.evidence[] | select(.kind=="delegation_cohort"
      and .fields.source=="codex")][0]
      | .observed_at==$codex.components.reporter_completed_at
        and .fields.reporter_completed_at==$codex.components.reporter_completed_at)
  ' <<<"$output"
}

@test "inspect: Claude and Codex delegation cohorts are independent" {
  make_phase5_reporter_fixture
  cat >"$CLAUDE_PROJECTS_DIR/fixture/session-two.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-07-28T11:00:00Z","message":{"content":[{"type":"tool_use","id":"skill-2","name":"Skill","input":{"skill":"execute-ticket"}}],"usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
EOF

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.effectiveness[] | select(.key=="execute_ticket_delegation_claude")][0]
      | .state=="measured" and .value==2
        and .components.sessions==2 and .components.turns==4
        and .components.zero_agent_sessions==1)
    and ([.effectiveness[] | select(.key=="execute_ticket_delegation_codex")][0]
      | .state=="measured" and .value==1
        and .components.sessions==1 and .components.turns==2
        and .components.zero_agent_sessions==0)
    and ([.evidence[] | select(.kind=="delegation_cohort")
      | .fields.source] | sort)==["claude","codex"]
  ' <<<"$output"
}

@test "inspect: missing reporter root degrades only that cohort" {
  make_phase5_reporter_fixture
  CLAUDE_PROJECTS_DIR="$BATS_TEST_TMPDIR/transcripts/missing-claude"
  export CLAUDE_PROJECTS_DIR

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.effectiveness[] | select(.key=="execute_ticket_delegation_claude")][0]
      | .state=="unmeasured" and .value==null
        and .reason=="reporter_root_missing" and .evidence_ids==[])
    and ([.coverage[] | select(.source=="delegation_claude")][0]
      | .state=="unavailable" and .reason=="missing")
    and ([.effectiveness[] | select(.key=="execute_ticket_delegation_codex")][0]
      | .state=="measured" and .value==1)
  ' <<<"$output"

  cat >"$P3_CORE/scripts/delegation-report.py" <<'PY'
import json
import sys

source = sys.argv[sys.argv.index("--source") + 1]
if source == "claude":
    sys.stdout.buffer.write(b"\xffinvalid-reporter-output")
else:
    print(json.dumps({
        "sessions": 1,
        "turns": 2,
        "agent_calls": 1,
        "zero_agent_sessions": 0,
        "zero_agent_pct": 0.0,
        "malformed_records": 0,
        "malformed_boundaries": 0,
        "malformed_timestamps": 0,
    }))
PY

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    (.effectiveness[5]
      | .key=="execute_ticket_delegation_claude"
        and .state=="unmeasured" and .value==null
        and .reason=="reporter_malformed_output" and .evidence_ids==[])
    and (.effectiveness[6]
      | .key=="execute_ticket_delegation_codex"
        and .state=="measured" and .value==1)
    and ([.coverage[] | select(.source=="delegation_claude")][0]
      | .state=="error" and .reason=="malformed"
        and .records_total==1 and .records_valid==0 and .records_invalid==1)
    and ([.coverage[] | select(.source=="delegation_codex")][0]
      | .state=="partial" and .reason=="upper_bound_unsupported")
    and ([.evidence[] | select(.kind=="delegation_cohort")
      | .fields.source])==["codex"]
  ' <<<"$output"
}

@test "inspect: reporter malformed counts propagate to coverage" {
  make_phase5_reporter_fixture

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.coverage[] | select(.source=="delegation_claude")][0]
      | .records_total==2 and .records_valid==1 and .records_invalid==1
        and (.limitations|index("reporter_malformed_timestamps"))!=null)
    and ([.coverage[] | select(.source=="delegation_codex")][0]
      | .records_total==4 and .records_valid==1 and .records_invalid==3
        and (.limitations|index("reporter_malformed_records"))!=null
        and (.limitations|index("reporter_malformed_boundaries"))!=null
        and (.limitations|index("reporter_malformed_timestamps"))!=null)
    and ([.evidence[] | select(.kind=="delegation_cohort"
      and .fields.source=="claude")][0].fields
      | .malformed_records==0 and .malformed_boundaries==0
        and .malformed_timestamps==1)
    and ([.evidence[] | select(.kind=="delegation_cohort"
      and .fields.source=="codex")][0].fields
      | .malformed_records==1 and .malformed_boundaries==1
        and .malformed_timestamps==1)
  ' <<<"$output"
}

@test "inspect: reporter upper bound limitation covers at-and-after start records" {
  make_phase5_reporter_fixture

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.effectiveness[] | select(.key=="execute_ticket_delegation_claude")][0]
      | .components.turns==3
        and (.limitations|index("records_at_or_after_inspection_started_at_may_be_included"))!=null)
    and ([.effectiveness[] | select(.key=="execute_ticket_delegation_codex")][0]
      | .components.turns==2
        and (.limitations|index("records_at_or_after_inspection_started_at_may_be_included"))!=null)
    and ([.coverage[] | select(.source=="delegation_claude"
      or .source=="delegation_codex")]
      | all(.state=="partial" and .reason=="upper_bound_unsupported"))
  ' <<<"$output"
}

@test "inspect: unsupported Hermes is unmeasured not zero" {
  make_phase5_reporter_fixture

  run run_phase3

  [ "$status" -eq 0 ]
  jq -e '
    ([.effectiveness[] | select(.key=="execute_ticket_delegation_hermes")][0]
      | .state=="unmeasured" and .value==null and .components=={}
        and .evidence_ids==[] and .reason=="unsupported"
        and (.limitations|index("unsupported_in_v1"))!=null)
    and ([.coverage[] | select(.source=="delegation_hermes")][0]
      | .state=="unavailable" and .reason=="unsupported"
        and .records_total==0 and .records_valid==0 and .records_invalid==0)
  ' <<<"$output"
}

@test "inspect: no transcript content enters output" {
  make_phase5_reporter_fixture

  run run_phase3

  [ "$status" -eq 0 ]
  [[ "$output" != *"CLAUDE_TRANSCRIPT_SECRET"* ]]
  [[ "$output" != *"CLAUDE_MALFORMED_SECRET"* ]]
  [[ "$output" != *"CLAUDE_AT_BOUNDARY_SECRET"* ]]
  [[ "$output" != *"CODEX_TRANSCRIPT_SECRET"* ]]
  [[ "$output" != *"CODEX_CALL_SECRET"* ]]
  [[ "$output" != *"CODEX_MALFORMED_RECORD_SECRET"* ]]
  [[ "$output" != *"CODEX_MALFORMED_TIME_SECRET"* ]]
  [[ "$output" != *"CODEX_AT_BOUNDARY_SECRET"* ]]
  jq -e '
    ([.evidence[] | select(.kind=="delegation_cohort")]|length)==2
    and ([.evidence[] | select(.kind=="delegation_cohort")
      | (.fields|keys)] | all(.==[
        "agent_calls","malformed_boundaries","malformed_records",
        "malformed_timestamps","reporter_completed_at","sessions","source",
        "turns","zero_agent_pct","zero_agent_sessions"
      ]))
  ' <<<"$output"
}

make_phase6_project_at() {
  local project="$1" name="$2" roles="$3" event_root="${4:-}"
  mkdir -p "$project/.agents" "$project/data/usage" "$project/tmp"
  cat >"$project/.agents/config.toml" <<EOF
project_name = "$name"
branch = "main"
[paths]
result_dir = "tmp"
[design]
budget_tokens_daily = 100
max_open_proposals = 4
[build]
budget_tokens_daily = 100
allow_no_ci = false
[release]
budget_tokens_daily = 100
verify_gate = true
test_cmd = "true"
typecheck = "true"
[medic]
budget_tokens_daily = 100
can_merge = false
[scribe]
budget_tokens_daily = 100
EOF
  local role
  for role in $roles; do
    write_phase3_service "$name-$role" "$role" "$project" "$event_root"
  done
  P3_PROJECT="$project"
}

make_phase6_priority_fixture() {
  make_phase3_core
  PHASE6_ROOT="$BATS_TEST_TMPDIR/events-phase6"
  mkdir -p "$PHASE6_ROOT"
  make_phase6_project_at "$P3_CORE" core "design build" "$PHASE6_ROOT"
  PHASE6_CORE="$P3_PROJECT"
  make_phase6_project_at "$BATS_TEST_TMPDIR/projects/app-one" app-one \
    "build" "$PHASE6_ROOT"
  PHASE6_APP_ONE="$P3_PROJECT"
  make_phase6_project_at "$BATS_TEST_TMPDIR/projects/app-two" app-two \
    "build" "$PHASE6_ROOT"
  PHASE6_APP_TWO="$P3_PROJECT"
  write_phase3_service core-build-duplicate build "$PHASE6_CORE" "$PHASE6_ROOT"
  cat >"$PHASE6_CORE/data/fyi-requests.jsonl" <<'EOF'
{"id":"core-signal","ts":"2026-07-28T07:00:00Z","text":"PHASE6_REDACTED"}
EOF
  cat >"$PHASE6_CORE/tmp/core-design-result.json" <<'EOF'
{"ts":"2026-07-28T08:00:00Z","project":"core","proposals":[
 {"id":"resolved","type":"feature","title":"Improve core dispatch","severity":"high","status":"open","signal_ids":["core-signal"]},
 {"id":"unresolved","type":"bug","title":"Unresolved core ask","severity":"med","status":"open","signal_ids":["missing-signal"]}
]}
EOF
  : >"$PHASE6_CORE/data/decisions.jsonl"
  cat >"$PHASE6_ROOT/2026-07-28.jsonl" <<'EOF'
{"ts":"2026-07-28T09:00:00Z","svc":"core-build","role":"build","event":"job.end","status":"fail","reason":"core_break","tokens":3}
{"ts":"2026-07-28T09:10:00Z","svc":"app-one-build","role":"build","event":"job.end","status":"fail","reason":"provider_down","tokens":4}
{"ts":"2026-07-28T09:20:00Z","svc":"app-two-build","role":"build","event":"job.end","status":"fail","reason":"provider_down","tokens":5}
{"ts":"2026-07-28T09:30:00Z","svc":"app-one-build","role":"build","event":"job.end","status":"fail","reason":"app_only","tokens":6}
EOF
}

make_phase6_shared_budget_fixture() {
  make_phase3_core
  PHASE6_ROOT="$BATS_TEST_TMPDIR/events-shared-budget"
  mkdir -p "$PHASE6_ROOT"
  make_phase6_project_at "$BATS_TEST_TMPDIR/projects/shared-a" shared-a \
    "design release" "$PHASE6_ROOT"
  local first="$P3_PROJECT"
  write_phase3_watcher "$first" "$PHASE6_ROOT"
  make_phase6_project_at "$BATS_TEST_TMPDIR/projects/shared-b" shared-b \
    "design release" "$PHASE6_ROOT"
  write_phase3_watcher "$P3_PROJECT" "$PHASE6_ROOT"
  : >"$PHASE6_ROOT/2026-07-29.jsonl"
}

make_phase6_empty_fixture() {
  make_phase3_core
  PHASE6_ROOT="$BATS_TEST_TMPDIR/events-empty-priorities"
  mkdir -p "$PHASE6_ROOT"
  make_phase6_project_at "$BATS_TEST_TMPDIR/projects/quiet" quiet \
    "design" "$PHASE6_ROOT"
  : >"$PHASE6_ROOT/2026-07-29.jsonl"
  : >"$P3_PROJECT/data/fyi-requests.jsonl"
  : >"$P3_PROJECT/data/usage/empty.jsonl"
  : >"$P3_PROJECT/data/decisions.jsonl"
  printf '[]\n' >"$P3_PROJECT/tmp/medic-incidents-current.json"
  cat >"$P3_PROJECT/tmp/quiet-design-result.json" <<'EOF'
{"ts":"2026-07-28T08:00:00Z","project":"quiet","proposals":[]}
EOF
}

run_phase3_human() {
  SHIPYARD_INSPECT_NOW=2026-07-29T12:00:00Z \
    python3 "$QUARTET_ROOT/skills/shipyard/inspect.py" \
      --core-root "$P3_CORE" --unit-dir "$UNIT_DIR" --days "${1:-7}"
}

@test "inspect: priorities obey category evidence recency id order" {
  make_phase6_priority_fixture
  run run_phase3
  [ "$status" -eq 0 ]
  priority_json="$BATS_TEST_TMPDIR/phase6-priorities.json"
  printf '%s\n' "$output" >"$priority_json"
  python3 - "$priority_json" <<'PY'
import hashlib
import json
import sys

doc = json.load(open(sys.argv[1], encoding="utf-8"))
names = (
    "confirmed_failure", "human_gate", "recurring_failure",
    "evidenced_opportunity", "instrumentation_gap", "hygiene",
)
order = {name: index for index, name in enumerate(names)}
priorities = doc["priorities"]
assert {item["category"] for item in priorities} == set(names)
for before, after in zip(priorities, priorities[1:]):
    if order[before["category"]] != order[after["category"]]:
        assert order[before["category"]] < order[after["category"]]
    elif before["evidence_count"] != after["evidence_count"]:
        assert before["evidence_count"] > after["evidence_count"]
    elif before["newest_ts"] != after["newest_ts"]:
        assert after["newest_ts"] is None or (
            before["newest_ts"] is not None
            and before["newest_ts"] > after["newest_ts"]
        )
    else:
        assert before["id"] < after["id"]
for rank, item in enumerate(priorities, 1):
    payload = (
        item["rule_id"] + "\0" + item["scope"] + "\0"
        + ",".join(sorted(set(item["project_ids"]))) + "\0"
        + ",".join(sorted(set(item["evidence_ids"])))
    ).encode()
    assert item["id"] == "pri_" + hashlib.sha256(payload).hexdigest()[:16]
    assert item["rank"] == rank
assert doc["summary"]["priority_count"] == len(priorities)
assert doc["summary"]["top_priority_ids"] == [
    item["id"] for item in priorities[:3]
]
PY
  printf 'ORDERED_PRIORITY_IDS=%s\n' \
    "$(jq -c '[.priorities[].id]' "$priority_json")"
}

@test "inspect: attention and priority ids survive input reordering" {
  make_phase6_priority_fixture
  run run_phase3
  [ "$status" -eq 0 ]
  document="$BATS_TEST_TMPDIR/phase6-reorder.json"
  printf '%s\n' "$output" >"$document"
  run python3 - "$QUARTET_ROOT/skills/shipyard/inspect.py" "$document" <<'PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("shipyard_inspect", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
doc = json.load(open(sys.argv[2], encoding="utf-8"))
expected_attention = sorted(item["id"] for item in doc["attention"])
expected_priorities = [item["id"] for item in doc["priorities"]]
for key in ("fleet", "coverage", "evidence", "attention", "effectiveness"):
    doc[key].reverse()
actual = module._derive_priorities(doc)
assert sorted(item["id"] for item in doc["attention"]) == expected_attention
assert [item["id"] for item in actual] == expected_priorities
PY
  [ "$status" -eq 0 ]
}

@test "inspect: direct core failure is shipyard_core" {
  make_phase6_priority_fixture
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '
    ([.priorities[] | select(.rule_id=="core_job_failure_v1")][0]
      | .category=="confirmed_failure" and .scope=="shipyard_core"
        and .claim_kind=="fact" and .evidence_count==1)
  ' <<<"$output"
}

@test "inspect: exact cross-project recurrence is core_candidate assessment" {
  make_phase6_priority_fixture
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '
    ([.priorities[] | select(.rule_id=="cross_project_recurrence_v1"
      and .operands.recurrence_key=="job:build:fail:provider_down")][0]
      | .category=="recurring_failure" and .scope=="core_candidate"
        and .claim_kind=="assessment" and (.project_ids|length)==2
        and (.limitations|index("cross_project_recurrence_is_not_core_proof"))!=null)
  ' <<<"$output"
}

@test "inspect: project-local failure stays attention" {
  make_phase6_priority_fixture
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '
    ([.evidence[] | select(.recurrence_key=="job:build:fail:app_only")][0].id) as $id
    | ([.attention[] | select(.kind=="observed_fault"
        and (.evidence_ids|index($id))!=null)]|length)==1
      and ([.priorities[] | select((.evidence_ids|index($id))!=null)]|length)==0
  ' <<<"$output"
}

@test "inspect: unresolved proposal signal cannot become opportunity" {
  make_phase6_priority_fixture
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '
    ([.attention[] | select(.title=="Unresolved core ask")][0]
      | (.limitations|index("unresolved_signal_ids"))!=null) and
    ([.priorities[] | select(.category=="evidenced_opportunity"
      and .title=="Unresolved core ask")]|length)==0
  ' <<<"$output"
}

@test "inspect: benchmark gap becomes explainable instrumentation priority" {
  make_phase6_priority_fixture
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '
    ([.priorities[] | select(.rule_id=="historical_benchmark_gap_v1")]|length)>0
    and ([.priorities[] | select(.rule_id=="historical_benchmark_gap_v1")][0]
      | .category=="instrumentation_gap" and .scope=="shipyard_core"
        and .claim_kind=="derived" and .operands.effectiveness_key!=null
        and .evidence_count>0 and (.confidence_basis|length)>0)
  ' <<<"$output"
}

@test "inspect: shared-root budget gate becomes Shipyard instrumentation priority" {
  make_phase6_shared_budget_fixture
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '
    ([.priorities[] | select(.rule_id=="budget_gate_scope_mismatch_v1")][0]
      | .category=="instrumentation_gap" and .scope=="shipyard_core"
        and .claim_kind=="derived" and (.project_ids|length)==2
        and (.operands.consumers|sort)
          ==["design_runner","release_shoulder_critic"]
        and (.operands.members|length)==4
        and (.operands.members
          | all(has("attributed_tokens_today") and has("gate_tokens_today"))))
  ' <<<"$output"
}

@test "inspect: unset non-design gate becomes Shipyard instrumentation priority" {
  make_phase3_core
  make_phase6_project_at "$BATS_TEST_TMPDIR/projects/unset-root" unset-root \
    "build"
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '
    ([.priorities[] | select(.rule_id=="budget_gate_root_mismatch_v1")][0]
      | .category=="instrumentation_gap" and .scope=="shipyard_core"
        and .operands.consumers==["build_runner"]
        and .operands.members[0].emitted_event_root_state=="core_fallback"
        and .operands.members[0].gate_event_root_state=="unset_sentinel")
  ' <<<"$output"
}

@test "inspect: unknown shoulder root cannot become shared-root priority" {
  make_phase3_core
  PHASE6_ROOT="$BATS_TEST_TMPDIR/events-unknown-shoulder"
  mkdir -p "$PHASE6_ROOT"
  make_phase6_project_at "$BATS_TEST_TMPDIR/projects/unknown-a" unknown-a \
    "release" "$PHASE6_ROOT"
  printf '\n[shoulder]\nauto_wire = true\n' >>"$P3_PROJECT/.agents/config.toml"
  make_phase6_project_at "$BATS_TEST_TMPDIR/projects/unknown-b" unknown-b \
    "release" "$PHASE6_ROOT"
  printf '\n[shoulder]\nauto_wire = true\n' >>"$P3_PROJECT/.agents/config.toml"
  : >"$PHASE6_ROOT/2026-07-29.jsonl"
  run run_phase3
  [ "$status" -eq 0 ]
  jq -e '
    ([.fleet[].pressure.daily_budget_consumers[]
      | select(.consumer=="release_shoulder_critic")
      | select(.applicability=="applicable" and .event_root_state=="unknown")]
      | length)==2
    and ([.priorities[] | select(.rule_id=="budget_gate_scope_mismatch_v1"
      and (.operands.consumers|index("release_shoulder_critic"))!=null)]
      | length)==0
  ' <<<"$output"
}

@test "inspect: human output is bounded and summarized" {
  make_phase6_priority_fixture
  run run_phase3
  [ "$status" -eq 0 ]
  document="$BATS_TEST_TMPDIR/oversized-human-document.json"
  printf '%s\n' "$output" >"$document"

  python3 - "$QUARTET_ROOT/skills/shipyard/inspect.py" "$document" <<'PY'
import copy
import importlib.util
import json
import re
import sys

spec = importlib.util.spec_from_file_location("shipyard_inspect", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with open(sys.argv[2], encoding="utf-8") as handle:
    document = json.load(handle)

long_project = "project-" + ("界" * 180)
long_title = "operator focus " + ("x" * 240)
long_reason = "source reason " + ("y" * 240)

project_states = (
    "fault_observed",
    "degraded_observed",
    "no_fault_observed",
    "unknown",
)
base_project = document["fleet"][0]
fleet = []
for index in range(13):
    item = copy.deepcopy(base_project)
    item["project_id"] = f"{index + 1:012x}"
    item["project_name"] = f"{long_project}-{index}"
    item["state"] = project_states[index % len(project_states)]
    item["safety"]["configured_branch"] = "branch-" + ("z" * 180)
    for consumer_index, consumer in enumerate(
        item["pressure"]["daily_budget_consumers"]
    ):
        consumer["applicability"] = "applicable"
        consumer["gate_fraction_today"] = (consumer_index + 1) / 10
        consumer["configured_daily_budget"] = 100
        item["pressure"]["budget_deferrals_by_consumer"][
            consumer["consumer"]
        ] = consumer_index
    item["pressure"]["undecided_open_proposals"] = index
    item["pressure"]["configured_max_open_proposals"] = 20
    item["pressure"]["open_cap_deferrals"] = index % 3
    fleet.append(item)
document["fleet"] = fleet
document["meta"]["project_count"] = len(fleet)
document["meta"]["role_count"] = sum(len(item["roles"]) for item in fleet)
document["summary"]["project_state_counts"] = {
    state: sum(item["state"] == state for item in fleet)
    for state in project_states
}

attention_kinds = (
    "open_proposal",
    "owner_decision",
    "observed_fault",
    "install_drift",
    "coverage_gap",
)
base_attention = document["attention"][0]
attention = []
for index in range(12):
    item = copy.deepcopy(base_attention)
    item["id"] = f"att_{index + 1:016x}"
    item["project_id"] = fleet[index]["project_id"]
    item["kind"] = attention_kinds[index % len(attention_kinds)]
    item["title"] = f"{long_title}-{index}"
    item["limitations"] = [long_reason]
    attention.append(item)
document["attention"] = attention
document["summary"]["attention_count"] = len(attention)

effectiveness_states = ("measured", "partial", "unmeasured")
effectiveness = copy.deepcopy(document["effectiveness"][:8])
assert len(effectiveness) == 8
for index, item in enumerate(effectiveness):
    item["state"] = effectiveness_states[index % len(effectiveness_states)]
    item["reason"] = long_reason
    item["limitations"] = [long_reason]
document["effectiveness"] = effectiveness
document["summary"]["effectiveness_state_counts"] = {
    state: sum(item["state"] == state for item in effectiveness)
    for state in effectiveness_states
}

base_priority = document["priorities"][0]
priorities = []
for index in range(9):
    item = copy.deepcopy(base_priority)
    item["id"] = f"pri_{index + 1:016x}"
    item["rank"] = index + 1
    item["title"] = f"{long_title}-{index}"
    item["project_ids"] = [fleet[index]["project_id"]]
    priorities.append(item)
document["priorities"] = priorities
document["summary"]["priority_count"] = len(priorities)
document["summary"]["top_priority_ids"] = [
    item["id"] for item in priorities[:3]
]

coverage_states = (
    "available",
    "not_applicable",
    "partial",
    "error",
    "unavailable",
    "partial",
    "available",
    "unavailable",
    "error",
    "partial",
    "unavailable",
    "partial",
)
coverage_sources = (
    "manifest",
    "config",
    "systemd",
    "doctor",
    "events",
    "events_attribution",
    "fyi",
    "usage",
    "caddy",
    "incident_state",
    "proposals",
    "decisions",
)
base_coverage = document["coverage"][0]
coverage = []
for index, state in enumerate(coverage_states):
    item = copy.deepcopy(base_coverage)
    item["project_id"] = fleet[index]["project_id"]
    item["source"] = coverage_sources[index]
    item["state"] = state
    item["reason"] = f"{long_reason}-{index}"
    item["records_total"] = index + 2
    item["records_valid"] = index + 1
    coverage.append(item)
document["coverage"] = coverage

before = json.dumps(
    document, sort_keys=True, separators=(",", ":"), ensure_ascii=False
)
human = module.render_human(document)
after = json.dumps(
    document, sort_keys=True, separators=(",", ":"), ensure_ascii=False
)
assert before == after, "render_human mutated its source document"

lines = human.splitlines()
headings = ("FLEET", "ATTENTION", "EFFECTIVENESS", "NEXT SHIPYARD PR", "COVERAGE")
assert [line for line in lines if line in headings] == list(headings)

def section(name, following=None):
    start = lines.index(name) + 1
    end = lines.index(following) if following is not None else len(lines)
    return [line for line in lines[start:end] if line]

fleet_rows = section("FLEET", "ATTENTION")
attention_rows = section("ATTENTION", "EFFECTIVENESS")
effectiveness_rows = section("EFFECTIVENESS", "NEXT SHIPYARD PR")
priority_rows = section("NEXT SHIPYARD PR", "COVERAGE")
coverage_rows = section("COVERAGE")

expected_fleet = (
    "  counts: fault_observed=4 degraded_observed=3 "
    "no_fault_observed=3 unknown=3"
)
assert fleet_rows[0] == expected_fleet, (
    f"FLEET aggregate mismatch: {fleet_rows[0]!r}"
)
assert attention_rows[0] == (
    "  counts: open_proposal=3 owner_decision=3 observed_fault=2 "
    "install_drift=2 coverage_gap=2"
)
assert effectiveness_rows[0] == (
    "  counts: measured=3 partial=3 unmeasured=2"
)
assert priority_rows[0] == "  candidates: 9"
assert coverage_rows[0] == (
    "  counts: available=2 partial=4 unavailable=3 error=2 not_applicable=1"
)

assert len([line for line in fleet_rows if re.match(r"^  \[[^]]+\]", line)]) == 10
assert len([line for line in fleet_rows if line.startswith("  pressure:")]) == 10
assert fleet_rows[-1] == "  … 3 more; use --json for full evidence"
assert len(attention_rows[1:-1]) == 5
assert attention_rows[-1] == "  … 7 more; use --json for full evidence"
assert len(effectiveness_rows[1:]) == 8
assert all("more; use --json" not in line for line in effectiveness_rows)
assert len(priority_rows[1:-1]) == 5
assert priority_rows[-1] == "  … 4 more; use --json for full evidence"
assert len(coverage_rows[1:-1]) == 5
assert coverage_rows[-1] == "  … 4 more; use --json for full evidence"
assert all("not_applicable" not in line for line in coverage_rows[1:])

attention_ids = re.findall(r"att_[0-9a-f]{16}", "\n".join(attention_rows[1:]))
priority_ids = re.findall(r"pri_[0-9a-f]{16}", "\n".join(priority_rows[1:]))
source_attention_ids = [item["id"] for item in document["attention"]]
source_priority_ids = [item["id"] for item in document["priorities"]]
assert attention_ids == source_attention_ids[:5]
assert priority_ids == source_priority_ids[:5]
assert set(attention_ids) <= set(source_attention_ids)
assert set(priority_ids) <= set(source_priority_ids)

actionable = [
    item for item in coverage
    if item["state"] in {"partial", "unavailable", "error"}
]
displayed_coverage = [
    re.match(r"^  - ([^/]+)/([^ ]+) ", line).groups()
    for line in coverage_rows[1:-1]
]
assert displayed_coverage == [
    (item["project_id"], item["source"]) for item in actionable[:5]
]
assert len(lines) <= 80, f"human output has {len(lines)} lines"
assert max(map(len, lines), default=0) <= 120, (
    f"human output max width is {max(map(len, lines), default=0)}"
)
assert any(line.endswith("…") for line in lines), "overlong text was not clipped"
print(
    f"lines={len(lines)} max_width={max(map(len, lines), default=0)} "
    "caps=10/5/8/5/5 omissions=3/7/0/4/4"
)
PY
}

@test "inspect: human fleet lines expose pressure and configured safety posture" {
  make_phase6_priority_fixture
  run run_phase3_human
  [ "$status" -eq 0 ]
  [[ "$output" == *"FLEET"* ]]
  [[ "$output" == *"roles=2 doctor=clean"* ]]
  [[ "$output" != *"roles=2("* ]]
  [[ "$output" == *"doctor=clean"* ]]
  [[ "$output" == *"  pressure: budget=max:"* ]]
  [[ "$output" == *" deferred="* ]]
  [[ "$output" == *" open="* ]]
  [[ "$output" == *" def="* ]]
  [[ "$output" == *"gates=merge:false,no-ci:false,verify:true,branch:main"* ]]
}

@test "inspect: empty and unavailable sections render explicitly" {
  make_phase6_empty_fixture
  run run_phase3
  [ "$status" -eq 0 ]
  document="$BATS_TEST_TMPDIR/empty-unavailable-document.json"
  printf '%s\n' "$output" >"$document"
  run python3 - "$QUARTET_ROOT/skills/shipyard/inspect.py" "$document" <<'PY'
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("shipyard_inspect", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with open(sys.argv[2], encoding="utf-8") as handle:
    document = json.load(handle)

actionable_states = {"partial", "unavailable", "error"}
actionable = sum(
    item["state"] in actionable_states for item in document["coverage"]
)
for item in document["coverage"]:
    if actionable >= 7:
        break
    if item["state"] not in actionable_states:
        item["state"] = "unavailable"
        item["reason"] = "guard_missing"
        actionable += 1

states = ("available", "partial", "unavailable", "error", "not_applicable")
counts = {
    state: sum(item["state"] == state for item in document["coverage"])
    for state in states
}
coverage_row = "  counts: " + " ".join(
    f"{state}={counts[state]}" for state in states
)
human = module.render_human(document)
assert (
    "ATTENTION\n"
    "  counts: open_proposal=0 owner_decision=0 observed_fault=0 "
    "install_drift=0 coverage_gap=0\n"
    "  none"
) in human
assert "NEXT SHIPYARD PR\n  candidates: 0\n  none" in human
assert coverage_row in human
assert (
    f"  … {actionable - 5} more; use --json for full evidence"
) in human
assert "COVERAGE\n\n" not in human
print(human)
PY
  [ "$status" -eq 0 ]
}

@test "inspect: JSON stdout contains JSON only and diagnostics use stderr" {
  make_phase6_empty_fixture
  run --separate-stderr run_phase3
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  jq -e '.schema_version==1 and (.priorities|type)=="array"' <<<"$output"
  printf 'JSON_STDOUT_BYTES=%s JSON_STDERR_BYTES=%s\n' \
    "${#output}" "${#stderr}"

  run --separate-stderr env SHIPYARD_INSPECT_NOW=2026-07-29T12:00:00Z \
    python3 "$QUARTET_ROOT/skills/shipyard/inspect.py" \
      --core-root "$P3_CORE" --unit-dir "$UNIT_DIR" --days 0 --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"--days must be a positive integer"* ]]
  printf 'DIAGNOSTIC_STDOUT_BYTES=%s DIAGNOSTIC_STDERR=%s\n' \
    "${#output}" "$stderr"
}
