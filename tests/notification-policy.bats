#!/usr/bin/env bats
#
# notification-policy.bats — classified Signal policy + episode dedup.
# Hermetic: transport and event stream are captured under BATS_TEST_TMPDIR.

setup() {
  load helpers
  quartet_setup

  PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  PROJECT_NAME="fixture"
  CFG_JSON='{"project_name":"fixture","notify":{"signal_level":"actionable"}}'
  mkdir -p "$PROJECT_DIR/tmp"
  export PROJECT_DIR PROJECT_NAME CFG_JSON
  export QUARTET_DIR="$QUARTET_ROOT"
  export QUARTET_EVENTS_DIR="$EVENTS_DIR"
  export QUARTET_SOURCE="test"
  source "$QUARTET_ROOT/agents/lib/load-config.sh"
}

decisions() {
  events_json | jq -c 'select(.event=="notification.decision")'
}

@test "legacy two-argument notify is byte-compatible and emits no decision event" {
  quartet_notify "legacy title" "legacy body"

  [ "$(notify_log)" = "legacy title|legacy body" ]
  [ -z "$(decisions)" ]
}

@test "actionable policy suppresses routine and delivers actionable plus urgent" {
  quartet_notify --class routine --episode pass-1 "routine" "pass"
  quartet_notify --class actionable --episode fail-1 "actionable" "gate failed"
  quartet_notify --class urgent --episode outage-1 "urgent" "service down"

  [ "$(notify_log)" = $'actionable|gate failed\nurgent|service down' ]
  [ "$(decisions | jq -r '.outcome')" = $'suppressed\ndelivered\ndelivered' ]
  [ "$(decisions | jq -r '.class')" = $'routine\nactionable\nurgent' ]
  [ "$(decisions | jq -r 'select(.class=="routine") | .reason')" = "policy" ]
}

@test "all actionable urgent and off policies obey the ordered threshold" {
  local policy
  for policy in all actionable urgent off; do
    CFG_JSON="$(jq -cn --arg p "$policy" '{project_name:"fixture",notify:{signal_level:$p}}')"
    export CFG_JSON
    quartet_notify --class routine "${policy}-routine" "body"
    quartet_notify --class actionable "${policy}-actionable" "body"
    quartet_notify --class urgent "${policy}-urgent" "body"
  done

  [ "$(notify_log)" = $'all-routine|body\nall-actionable|body\nall-urgent|body\nactionable-actionable|body\nactionable-urgent|body\nurgent-urgent|body' ]
}

@test "unset policy preserves delivery for every classified level" {
  CFG_JSON='{"project_name":"fixture"}'
  export CFG_JSON

  quartet_notify --class routine "routine" "body"
  quartet_notify --class actionable "actionable" "body"
  quartet_notify --class urgent "urgent" "body"

  [ "$(notify_log)" = $'routine|body\nactionable|body\nurgent|body' ]
  [ "$(decisions | jq -r '.policy' | uniq)" = "all" ]
}

@test "same episode dedupes within window while different and expired keys deliver" {
  quartet_notify --class actionable --episode same --window 86400 "first" "body"
  quartet_notify --class actionable --episode same --window 86400 "duplicate" "body"
  quartet_notify --class actionable --episode other --window 86400 "other" "body"

  state="$PROJECT_DIR/tmp/notification-dedup.json"
  [ -s "$state" ]
  tmp="$state.test"
  jq '.episodes |= with_entries(.value = 0)' "$state" >"$tmp"
  mv "$tmp" "$state"
  quartet_notify --class actionable --episode same --window 1 "expired" "body"

  [ "$(notify_log)" = $'first|body\nother|body\nexpired|body' ]
  [ "$(decisions | jq -r '.outcome')" = $'delivered\ndeduped\ndelivered\ndelivered' ]
}

@test "urgent notifications dedupe when they share an explicit episode" {
  CFG_JSON='{"project_name":"fixture","notify":{"signal_level":"urgent"}}'
  export CFG_JSON

  quartet_notify --class urgent --episode outage "urgent one" "body"
  quartet_notify --class urgent --episode outage "urgent two" "body"

  [ "$(notify_log)" = "urgent one|body" ]
  [ "$(decisions | jq -r '.outcome')" = $'delivered\ndeduped' ]
}

@test "failed transport does not consume the episode key" {
  make_notify_stub_rc 9
  quartet_notify --class actionable --episode retryable "first attempt" "body"

  [ ! -s "$PROJECT_DIR/tmp/notification-dedup.json" ] ||
    [ "$(jq '.episodes | length' "$PROJECT_DIR/tmp/notification-dedup.json")" -eq 0 ]

  make_notify_stub_rc 0
  quartet_notify --class actionable --episode retryable "second attempt" "body"

  [ "$(notify_log)" = $'first attempt|body\nsecond attempt|body' ]
  [ "$(decisions | jq -r '.outcome + ":" + (.reason // "")')" = $'suppressed:transport_failed\ndelivered:' ]
}

@test "dedup lock failure fails open instead of swallowing the alert" {
  mkdir "$PROJECT_DIR/tmp/notification-dedup.lock"

  quartet_notify --class urgent --episode lock-failed "must deliver" "body"

  [ "$(notify_log)" = "must deliver|body" ]
  [ "$(decisions | jq -r '.outcome + ":" + .reason')" = "delivered:dedup_unavailable" ]
}

@test "invalid policy fails open and records the reason" {
  CFG_JSON='{"project_name":"fixture","notify":{"signal_level":"typo"}}'
  export CFG_JSON

  quartet_notify --class routine --episode invalid-policy "still delivered" "body"

  [ "$(notify_log)" = "still delivered|body" ]
  [ "$(decisions | jq -r '.outcome + ":" + .reason + ":" + .policy')" = "delivered:invalid_policy:all" ]
}

@test "concurrent callers deliver one notification for one episode" {
  local i
  for i in 1 2 3 4 5 6 7 8; do
    (
      source "$QUARTET_ROOT/agents/lib/load-config.sh"
      quartet_notify --class actionable --episode concurrent "attempt $i" "body"
    ) &
  done
  wait

  [ "$(notify_log | wc -l | tr -d ' ')" = "1" ]
  [ "$(decisions | jq -r 'select(.outcome=="delivered") | .episode' | wc -l | tr -d ' ')" = "1" ]
  [ "$(decisions | jq -r 'select(.outcome=="deduped") | .episode' | wc -l | tr -d ' ')" = "7" ]
  jq -e '.episodes | length == 1' "$PROJECT_DIR/tmp/notification-dedup.json"
}
