#!/usr/bin/env bats
# shipyard-inspect.bats — hermetic contract for the read-only fleet inspector.

setup() {
  load helpers
  quartet_setup
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
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
  find "$P3_CORE" "$P3_PROJECT" "$UNIT_DIR" -type f -print0 \
    | sort -z \
    | xargs -0 sha256sum
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

  sed -i 's/ActiveState=active/ActiveState=activating/; s/UnitFileState=enabled/UnitFileState=enabled-runtime/' \
    "$SHIM_LOG/normal-release.timer.stdout"
  run run_inspect
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fleet[0].state' <<<"$output")" != "fault_observed" ]

  sed -i 's/ActiveState=activating/ActiveState=failed/' \
    "$SHIM_LOG/normal-release.timer.stdout"
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

  sed -i 's/"007"/1.5/' "$P/.agents/config.toml"
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

  sed -i 's/Thu 2026-07-30 06:00:00 UTC/Thu 2026-07-30 01:00:00 CDT/' \
    "$SHIM_LOG/timestamps-release.timer.stdout"
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
  sed -i '/ExecMainStatus=/d' "$SHIM_LOG/timestamps-release.service.stdout"
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].units[0].exec_main_status == null
    and ([.coverage[] | select(.source=="systemd")][0]
      | .state=="partial" and .reason=="malformed")
  ' <<<"$output"

  seed_show_output timestamps-release
  sed -i 's/Thu 2026-07-30 06:00:00 UTC/Wed 2026-07-29 11:55:00 UTC/' \
    "$SHIM_LOG/timestamps-release.timer.stdout"
  run run_inspect
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fleet[0].units[0].timer_stale_state' <<<"$output")" = "fresh" ]
  sed -i 's/Wed 2026-07-29 11:55:00 UTC/Wed 2026-07-29 11:54:59 UTC/' \
    "$SHIM_LOG/timestamps-release.timer.stdout"
  run run_inspect
  [ "$status" -eq 0 ]
  [ "$(jq -r '.fleet[0].units[0].timer_stale_state' <<<"$output")" = "stale" ]

  seed_show_output timestamps-release
  cat >>"$SHIM_LOG/timestamps-release.timer.stdout" <<'EOF'
UnexpectedProperty=value
LoadState=duplicate
malformed-line
EOF
  sed -i '/ExecMainStatus=/d' "$SHIM_LOG/timestamps-release.service.stdout"
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
  sed -i 's/ActiveState=active/ActiveState=inactive/; s/SubState=waiting/SubState=dead/; s/UnitFileState=enabled/UnitFileState=disabled/' \
    "$SHIM_LOG/faults-release.timer.stdout"

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
  sed -i 's/ActiveState=inactive/ActiveState=failed/; s/Result=success/Result=failed/; s/ExecMainStatus=0/ExecMainStatus=1/' \
    "$SHIM_LOG/faults-release.service.stdout"
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
  sed -i 's/^project_name.*/project_name = "missing dependency: gh"/' \
    "$P/.agents/config.toml"
  run run_inspect
  [ "$status" -eq 0 ]
  jq -e '
    .fleet[0].doctor.state=="drift"
    and .fleet[0].doctor.exit_code==1
    and ([.coverage[] | select(.source=="doctor")][0]
      | .state=="available" and .reason=="ok")
  ' <<<"$output"

  sed -i 's/^project_name.*/project_name = "doctor-state"/' \
    "$P/.agents/config.toml"
  sed -i '/^project_name/d' "$P/.agents/config.toml"
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
strict_cache = {}
cases = [
    (sys.argv[2], "design_runner", "svc-a"),
    (sys.argv[2], "design_runner", "svc-b"),
    (sys.argv[2], "build_runner", "fixture-build"),
    (sys.argv[2], "build_runner", "other-build"),
    (sys.argv[3], "build_runner", "fixture-build"),
]
cached = [
    mod._cached_gate_operand(path, consumer, svc, gate_cache)
    for path, consumer, svc in cases
]
direct = [
    mod.compute_gate_operand(path, consumer, svc)
    for path, consumer, svc in cases
]
strict = [
    mod._cached_strict_gate_invalid_count(sys.argv[2], strict_cache),
    mod._cached_strict_gate_invalid_count(sys.argv[2], strict_cache),
    mod._cached_strict_gate_invalid_count(sys.argv[3], strict_cache),
]
print(cached)
print(direct)
print(len(gate_cache), strict, len(strict_cache))
PY
  [ "$status" -eq 0 ]
  [ "$output" = $'[4, 4, 6, 0, 11]\n[4, 4, 6, 0, 11]\n4 [(3, True), (3, True), (2, True)] 2' ]
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
  sed -i '0,/budget_tokens_daily = 100/s//budget_tokens_daily = 0/' \
    "$P3_PROJECT/.agents/config.toml"
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
  sed -i 's#https://Example.TEST/health?fixture=ignored#https://[broken#' \
    "$P3_PROJECT/.agents/config.toml"
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
