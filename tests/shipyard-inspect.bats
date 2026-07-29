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
