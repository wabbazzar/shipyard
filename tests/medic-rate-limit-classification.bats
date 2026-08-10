#!/usr/bin/env bats
#
# medic-rate-limit-classification.bats — deterministic classification for the
# proven Claude weekly-limit incident family. All commands are PATH stubs; no
# test reaches a model, network, notification transport, or user service.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
}

make_fake_quartet() {
  FAKE_QD="$BATS_TEST_TMPDIR/fake-quartet"
  mkdir -p "$FAKE_QD/agents/build" "$FAKE_QD/agents/release"
  ln -s "$QUARTET_ROOT/agents/lib" "$FAKE_QD/agents/lib"
  cat >"$FAKE_QD/agents/build/runner.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$SHIM_LOG/build-runner.argv"
exit 1
STUB
  chmod +x "$FAKE_QD/agents/build/runner.sh"
}

prepare_incident() {
  local project="$1" name="$2" class="$3" action="$4"
  local summary="$5" hypothesis="$6"
  UNIT="$name-web"
  OPS_JSON="$BATS_TEST_TMPDIR/ops.json"
  IID="$(printf '%s' "systemd-failed $UNIT $(date -u +%Y-%m-%d)" |
    sha256sum | awk '{print $1}')"
  MENTAT_RESULT="$project/tmp/$name-design-result.json"
  EXPECTED_SUMMARY="$summary"
  EXPECTED_HYPOTHESIS="$hypothesis"

  jq -n --arg unit "$UNIT" \
    '{cron:[], systemd:[{name:$unit, state:"failed", description:"web", timerSchedule:""}]}' \
    >"$OPS_JSON"
  jq -n --arg iid "$IID" --arg class "$class" --arg action "$action" \
    --arg summary "$summary" --arg hypothesis "$hypothesis" \
    '{pass:true, errors:[], incidents_classified:[{
      incident_id:$iid, class:$class, action:$action,
      surface:"runners", source:"systemd",
      incident_summary:$summary, hypothesis:$hypothesis
    }]}' >"$BATS_TEST_TMPDIR/medic-classification.json"

  make_stub_script claude \
    "cp '$BATS_TEST_TMPDIR/medic-classification.json' '$project/tmp/medic-result.json'; exit 0"
  make_stub_script systemctl '
case "$*" in
  *list-units*) echo "'"$UNIT"' loaded failed"; exit 0 ;;
  *restart*) exit 0 ;;
  *) exit 0 ;;
esac'
  make_stub sleep 0
}

run_medic_scan() {
  run env QUARTET_DIR="$FAKE_QD" \
    QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    QUARTET_NOTIFY_CMD="$NOTIFY_CMD" \
    QUARTET_OPS_JSON="$OPS_JSON" \
    QUARTET_SOURCE="test" \
    bash "$QUARTET_ROOT/agents/medic/runner.sh" --project "$1" --mode scan
}

assert_rate_limit_skip() {
  local project="$1" result="$project/tmp/medic-result.json"
  jq -e --arg iid "$IID" --arg summary "$EXPECTED_SUMMARY" \
    --arg hypothesis "$EXPECTED_HYPOTHESIS" '
    .incidents_detected == 1 and
    .build_invocations == 0 and
    .daily_cap_hit == false and
    .incidents_classified == [{
      incident_id:$iid, class:"rate_limit", action:"skip",
      surface:"runners", source:"systemd",
      incident_summary:$summary,
      hypothesis:$hypothesis
    }] and
    .actions_taken == [{incident_id:$iid, action:"skip", outcome:"rate_limit"}]
  ' "$result" >/dev/null

  events_json | jq -s -e --arg iid "$IID" '
    ([.[] | select(.event=="medic.incident.detected" and .incident_id==$iid)] | length) == 1 and
    ([.[] | select(.event=="medic.incident.classified" and .incident_id==$iid and
      .class=="rate_limit" and .action=="skip")] | length) == 1 and
    ([.[] | select(.event=="medic.incident" and .incident_id==$iid and
      .restart_action=="skip:rate_limit")] | length) == 1 and
    ([.[] | select(.incident_id==$iid and (.event=="medic.incident.frozen" or
      .event=="medic.incident.repair_proposed" or .event=="medic.action.restart" or
      .event=="medic.incident.resolved"))] | length) == 0 and
    ([.[] | select(.event=="design.proposal.opened" or
      .event=="notification.decision")] | length) == 0
  ' >/dev/null

  [ -z "$(notify_log)" ]
  jq -e --arg iid "$IID" '
    (.cooldowns | has($iid) | not) and
    (([.daily_escalations[]] | add // 0) == 0)
  ' "$project/tmp/medic-state.json" >/dev/null
  [ ! -e "$MENTAT_RESULT" ]
  [ "$(stub_calls build-runner)" -eq 0 ]
  [ "$(stub_calls sleep)" -eq 0 ]
  ! stub_argv systemctl | grep -q 'restart'
}

assert_infra_escalation() {
  local project="$1" result="$project/tmp/medic-result.json"
  jq -e --arg iid "$IID" '
    .incidents_classified[0].incident_id == $iid and
    .incidents_classified[0].class == "infra" and
    .incidents_classified[0].action == "notify" and
    .actions_taken == [{incident_id:$iid, action:"freeze", outcome:"infra"}]
  ' "$result" >/dev/null
  events_json | jq -s -e --arg iid "$IID" '
    any(.[]; .event=="medic.incident.classified" and .incident_id==$iid and
      .class=="infra" and .action=="notify") and
    any(.[]; .event=="medic.incident.frozen" and .incident_id==$iid and
      .reason=="infra") and
    any(.[]; .event=="medic.incident" and .incident_id==$iid and
      .restart_action=="freeze:infra")
  ' >/dev/null
  [ -n "$(notify_log)" ]
  [ "$(jq -r --arg iid "$IID" '.cooldowns[$iid].reason' \
    "$project/tmp/medic-state.json")" = "infra" ]
  [ ! -e "$MENTAT_RESULT" ]
  [ "$(stub_calls build-runner)" -eq 0 ]
  [ "$(stub_calls sleep)" -eq 0 ]
  ! stub_argv systemctl | grep -q 'restart'
}

assert_regression_escalation() {
  local project="$1" result="$project/tmp/medic-result.json"
  jq -e --arg iid "$IID" '
    .incidents_classified[0].incident_id == $iid and
    .incidents_classified[0].class == "regression" and
    .incidents_classified[0].action == "propose_repair" and
    .actions_taken[0].incident_id == $iid and
    .actions_taken[0].action == "propose_repair" and
    .actions_taken[0].outcome == "proposed"
  ' "$result" >/dev/null
  events_json | jq -s -e --arg iid "$IID" '
    any(.[]; .event=="medic.incident.classified" and .incident_id==$iid and
      .class=="regression" and .action=="propose_repair") and
    any(.[]; .event=="medic.incident.repair_proposed" and .incident_id==$iid) and
    any(.[]; .event=="medic.incident" and .incident_id==$iid and
      (.restart_action | startswith("propose_repair:proposed"))) and
    any(.[]; .event=="design.proposal.opened")
  ' >/dev/null
  [ -n "$(notify_log)" ]
  [ -s "$MENTAT_RESULT" ]
  [ "$(jq -r '[.daily_escalations[]] | add // 0' \
    "$project/tmp/medic-state.json")" -eq 1 ]
  [ "$(stub_calls build-runner)" -eq 0 ]
  [ "$(stub_calls sleep)" -eq 0 ]
  ! stub_argv systemctl | grep -q 'restart'
}

@test "weekly Claude limit true rewrites Claude weekly-limit outage to rate_limit skip" {
  make_fake_quartet
  project="$(make_fixture_project weekly-hyphen branch-present.toml)"
  printf '\nweekly_limit_classification = true\n' >>"$project/.agents/config.toml"
  prepare_incident "$project" weekly-hyphen infra notify \
    "Claude weekly-limit outage" "account capacity is temporarily exhausted"

  run_medic_scan "$project"
  [ "$status" -eq 0 ]

  assert_rate_limit_skip "$project"
}

@test "weekly Claude limit true rewrites weekly Claude usage limit from hypothesis" {
  make_fake_quartet
  project="$(make_fixture_project weekly-order branch-present.toml)"
  printf '\nweekly_limit_classification = true\n' >>"$project/.agents/config.toml"
  prepare_incident "$project" weekly-order regression propose_repair \
    "account capacity incident" "provider reports a weekly Claude usage limit"

  run_medic_scan "$project"
  [ "$status" -eq 0 ]
  assert_rate_limit_skip "$project"
}

@test "weekly Claude limit true leaves generic weekly limit infra escalation unchanged" {
  make_fake_quartet
  project="$(make_fixture_project weekly-generic branch-present.toml)"
  printf '\nweekly_limit_classification = true\n' >>"$project/.agents/config.toml"
  prepare_incident "$project" weekly-generic infra notify \
    "generic weekly usage limit" "provider capacity is exhausted"

  run_medic_scan "$project"
  [ "$status" -eq 0 ]
  assert_infra_escalation "$project"
}

@test "weekly Claude limit explicit false preserves matching infra escalation" {
  make_fake_quartet
  project="$(make_fixture_project weekly-false branch-present.toml)"
  printf '\nweekly_limit_classification = false\n' >>"$project/.agents/config.toml"
  prepare_incident "$project" weekly-false infra notify \
    "Claude weekly-limit outage" "account capacity is temporarily exhausted"

  run_medic_scan "$project"
  [ "$status" -eq 0 ]
  assert_infra_escalation "$project"
}

@test "weekly Claude limit unset preserves matching regression escalation" {
  make_fake_quartet
  project="$(make_fixture_project weekly-unset branch-present.toml)"
  prepare_incident "$project" weekly-unset regression propose_repair \
    "weekly Claude usage limit" "classifier believes a repair is required"

  run_medic_scan "$project"
  [ "$status" -eq 0 ]
  assert_regression_escalation "$project"
}
