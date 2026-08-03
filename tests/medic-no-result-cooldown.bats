#!/usr/bin/env bats
#
# medic-no-result-cooldown.bats — classifier failure and origin→medic paging.
# Hermetic: all model, transport, ops, and event surfaces are local fixtures.

setup() {
  load helpers
  quartet_setup
  make_stub systemctl 0
}

enable_actionable_policy() {
  printf '\n[notify]\nsignal_level = "actionable"\n' >>"$1/.agents/config.toml"
}

stage_failed_unit() {
  local name="$1"
  OPS_JSON="$BATS_TEST_TMPDIR/ops.json"
  jq -n --arg unit "$name-web" \
    '{cron:[],systemd:[{name:$unit,state:"failed",description:"web",timerSchedule:""}]}' \
    >"$OPS_JSON"
  export OPS_JSON
}

run_medic_scan() {
  run env QUARTET_DIR="$QUARTET_ROOT" \
    QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    QUARTET_OPS_JSON="$OPS_JSON" \
    QUARTET_SOURCE=test \
    bash "$QUARTET_ROOT/agents/medic/runner.sh" --project "$1" --mode scan
}

@test "classifier no-result emits one actionable page across two identical scans" {
  p="$(make_fixture_project noresult branch-present.toml)"
  enable_actionable_policy "$p"
  stage_failed_unit noresult
  make_stub claude 1 '{"type":"result","result":"upstream unavailable","usage":{}}'

  run_medic_scan "$p"
  [ "$status" -eq 1 ]
  run_medic_scan "$p"
  [ "$status" -eq 1 ]

  [ "$(notify_log | grep -c 'Medic detected')" = "1" ]
  [ "$(events_json | jq -r 'select(.event=="notification.decision") | .outcome')" = $'delivered\ndeduped' ]
  [ "$(events_json | jq -r 'select(.event=="notification.decision") | .class' | sort -u)" = "actionable" ]
  [ "$(events_json | jq -r 'select(.event=="notification.decision") | .episode' | sort -u | wc -l | tr -d ' ')" = "1" ]
}

@test "origin failure and post-run medic no-result share one episode and page once" {
  p="$(make_fixture_project origin branch-present.toml)"
  enable_actionable_policy "$p"
  make_stub_script claude '
for a in "$@"; do last="$a"; done
rf="$(printf "%s" "$last" | grep -oE "\"result_file\":[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/.*\"result_file\":[[:space:]]*\"//; s/\"$//")"
case "$rf" in
  *origin-release-result.json)
    printf "%s" "{\"pass\":false,\"mode\":\"daily\",\"timestamp\":\"2026-07-28T00:00:00Z\",\"errors\":[\"real gate failure\"]}" >"$rf" ;;
  *medic-result.json) : ;; # classifier fails to write
esac
printf "%s" "{\"type\":\"result\",\"result\":\"done\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
'

  run run_runner release "$p" --mode daily
  [ "$status" -eq 1 ]

  [ "$(notify_log | wc -l | tr -d ' ')" = "1" ]
  [ "$(notify_log)" = "origin Release FAILED (daily)|origin-release completed (mode=daily, exit=1). See $p/tmp/origin-release-last-run.log." ]
  [ "$(events_json | jq -r 'select(.event=="notification.decision") | .outcome')" = $'delivered\ndeduped' ]
  [ "$(events_json | jq -r 'select(.event=="notification.decision") | .class' | sort -u)" = "actionable" ]
  episodes="$(events_json | jq -r 'select(.event=="notification.decision") | .episode')"
  [ "$(printf '%s\n' "$episodes" | sort -u | wc -l | tr -d ' ')" = "1" ]
  [ -n "$(printf '%s\n' "$episodes" | head -1)" ]
}
