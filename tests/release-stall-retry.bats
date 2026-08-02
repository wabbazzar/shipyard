#!/usr/bin/env bats
#
# release-stall-retry.bats — [release] stall_retries: a transient mid-stream
# model stall (the run writes NO result.json) is retried in-process, bounded,
# before the job fails — so a one-off stall self-heals instead of triggering a
# medic retry storm (proposal shipyard:3b5a75e8). A run that WROTE a verdict
# (pass OR fail) is a real result and is NEVER retried. Default (unset) = 0 =
# today's behavior exactly (a single spawn, no retry).
#
# The claude harness is a PATH stub whose behavior (write / withhold the
# result.json whose path it reads out of the prompt) is driven per test. No
# network, no model. Retry behavior is asserted from the release.stall.retry
# event stream + job.end status, which the medic-escalation path (real runner,
# stubbed claude) can never forge.

setup() {
  load helpers
  quartet_setup
  make_stub systemctl 0
  make_stub notify.sh 0
  RELCOUNT="$BATS_TEST_TMPDIR/relcount"
}

# stub_claude <behavior> — install a claude stub. <behavior> is a snippet that
# runs with $rf = the release result.json path and $n = this release-spawn's
# 1-based attempt number; it decides whether to write $rf.
stub_claude() {
  local behavior="$1"
  make_stub_script claude '
for a in "$@"; do _last="$a"; done
# the REAL result path is the RUN_CONTEXT "result_file" JSON field, not a
# <project> template literal in the prompt prose; medic escalation carries its
# own result_file (medic-result.json) which we ignore.
rf="$(printf "%s" "$_last" | grep -oE "\"result_file\":[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/.*\"result_file\":[[:space:]]*\"//; s/\"$//")"
case "$rf" in *medic*) rf="" ;; esac
if [ -n "$rf" ]; then
  n=$(( $(cat "'"$RELCOUNT"'" 2>/dev/null || echo 0) + 1 )); echo "$n" > "'"$RELCOUNT"'"
  '"$behavior"'
fi
printf "%s" "{\"result\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
'
}

stub_codex_incomplete() {
  # Medic escalation still uses its default Claude harness; keep that path
  # inert while the release turn exercises Codex's stdin prompt transport.
  stub_claude ':'
  make_stub_script codex '
prompt="$(cat)"
rf="$(printf "%s" "$prompt" | grep -oE "\"result_file\":[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/.*\"result_file\":[[:space:]]*\"//; s/\"$//")"
if [ -n "$rf" ]; then
  n=$(( $(cat "'"$RELCOUNT"'" 2>/dev/null || echo 0) + 1 )); echo "$n" > "'"$RELCOUNT"'"
  printf "%s" "{\"pass\":false,\"mode\":\"daily\",\"timestamp\":\"t\",\"incomplete\":true,\"errors\":[\"run-in-progress\"]}" > "$rf"
fi
out=""
while [ "$#" -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done
[ -z "$out" ] || printf "%s" "model ended early" > "$out"
printf "%s\n" "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
'
}

stub_hermes_incomplete() {
  stub_claude ':'
  make_stub_script hermes '
if [ "$1" = "chat" ]; then
  shift
  prompt=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "-q" ]; then prompt="$2"; shift 2; else shift; fi
  done
  rf="$(printf "%s" "$prompt" | grep -oE "\"result_file\":[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/.*\"result_file\":[[:space:]]*\"//; s/\"$//")"
  if [ -n "$rf" ]; then
    n=$(( $(cat "'"$RELCOUNT"'" 2>/dev/null || echo 0) + 1 )); echo "$n" > "'"$RELCOUNT"'"
    printf "%s" "{\"pass\":false,\"mode\":\"daily\",\"timestamp\":\"t\",\"incomplete\":true,\"errors\":[\"run-in-progress\"]}" > "$rf"
  fi
  printf "%s\n" "model ended early"
  printf "%s\n" "session_id: TESTSID" >&2
elif [ "$1" = "sessions" ]; then
  printf "%s" "{\"input_tokens\":1,\"output_tokens\":1}"
fi
'
}

run_release() {
  RELEASE_STALL_BACKOFF_SEC=0 run_runner release "$PROJ" --mode daily
}

run_release_with_harness() {
  RELEASE_HARNESS="$1" RELEASE_STALL_BACKOFF_SEC=0 \
    run_runner release "$PROJ" --mode daily
}

n_retry_events() { events_json | jq -c 'select(.event=="release.stall.retry")' | wc -l | tr -d ' '; }
job_end_status() { events_json | jq -r 'select(.event=="job.end" and (.svc|endswith("-release"))) | .status' | tail -1; }
release_job_end() { events_json | jq -c 'select(.event=="job.end" and (.svc|endswith("-release")))' | tail -1; }

@test "a clean harness exit with an incomplete sentinel fails the runner closed" {
  PROJ="$(make_fixture_project incomplete0 can-merge-true.toml)"
  fixture_replace_in_place "$PROJ/.agents/config.toml" '^\[release\]$' \
    $'[release]\nstall_retries = 2'
  stub_claude 'printf "%s" "{\"pass\":false,\"mode\":\"daily\",\"timestamp\":\"t\",\"incomplete\":true,\"errors\":[\"run-in-progress\"]}" > "$rf"'

  run run_release

  if [ "$status" -ne 1 ]; then
    echo "expected fail-closed outer status 1, observed $status" >&2
    false
  fi
  result="$PROJ/tmp/incomplete0-release-result.json"
  [ "$(jq -r '.pass' "$result")" = "false" ]
  [ "$(jq -r '.incomplete' "$result")" = "true" ]
  jq -e '.errors == ["run-in-progress"]' "$result"
  [ "$(cat "$RELCOUNT")" -eq 1 ]
  [ "$(n_retry_events)" -eq 0 ]
  [ "$(release_job_end | jq -r '.status')" = "fail" ]
  [ "$(release_job_end | jq -r '.exit_code')" -eq 1 ]
  grep -q '\[incomplete0-release\] done pass=false exit=1' \
    "$PROJ/tmp/incomplete0-release-last-run.log"
  [[ "$(notify_log)" == *"incomplete0 Release DID NOT FINISH (daily)"* ]]
  [ "$(events_json | jq -r 'select(.event=="notification.decision" and (.svc|endswith("-release"))) | .class' | tail -1)" = "routine" ]
}

@test "Codex transport exit zero with an incomplete sentinel fails closed" {
  PROJ="$(make_fixture_project incomplete-codex can-merge-true.toml)"
  stub_codex_incomplete

  run run_release_with_harness codex

  [ "$status" -eq 1 ]
  [ "$(cat "$RELCOUNT")" -eq 1 ]
  [ "$(n_retry_events)" -eq 0 ]
  result="$PROJ/tmp/incomplete-codex-release-result.json"
  [ "$(jq -r '.pass' "$result")" = "false" ]
  [ "$(jq -r '.incomplete' "$result")" = "true" ]
  [ "$(release_job_end | jq -r '.exit_code')" -eq 1 ]
}

@test "Hermes transport exit zero with an incomplete sentinel fails closed" {
  PROJ="$(make_fixture_project incomplete-hermes can-merge-true.toml)"
  stub_hermes_incomplete

  run run_release_with_harness hermes

  [ "$status" -eq 1 ]
  [ "$(cat "$RELCOUNT")" -eq 1 ]
  [ "$(n_retry_events)" -eq 0 ]
  result="$PROJ/tmp/incomplete-hermes-release-result.json"
  [ "$(jq -r '.pass' "$result")" = "false" ]
  [ "$(jq -r '.incomplete' "$result")" = "true" ]
  [ "$(release_job_end | jq -r '.exit_code')" -eq 1 ]
}

@test "pass true with transport zero remains a successful runner exit" {
  PROJ="$(make_fixture_project pass0 can-merge-true.toml)"
  stub_claude 'printf "%s" "{\"pass\":true,\"mode\":\"daily\",\"timestamp\":\"t\"}" > "$rf"'

  run run_release

  [ "$status" -eq 0 ]
  [ "$(cat "$RELCOUNT")" -eq 1 ]
  [ "$(release_job_end | jq -r '.status')" = "ok" ]
  [ "$(release_job_end | jq -r '.exit_code')" -eq 0 ]
  grep -q '\[pass0-release\] done pass=true exit=0' \
    "$PROJ/tmp/pass0-release-last-run.log"
}

@test "pass true preserves a genuine nonzero transport as partial" {
  PROJ="$(make_fixture_project pass9 can-merge-true.toml)"
  stub_claude 'printf "%s" "{\"pass\":true,\"mode\":\"daily\",\"timestamp\":\"t\"}" > "$rf"; exit 9'

  run run_release

  [ "$status" -eq 9 ]
  [ "$(cat "$RELCOUNT")" -eq 1 ]
  [ "$(release_job_end | jq -r '.status')" = "partial" ]
  [ "$(release_job_end | jq -r '.exit_code')" -eq 9 ]
  grep -q '\[pass9-release\] done pass=true exit=9' \
    "$PROJ/tmp/pass9-release-last-run.log"
}

@test "pass false preserves a genuine nonzero transport code" {
  PROJ="$(make_fixture_project fail7 can-merge-true.toml)"
  stub_claude 'printf "%s" "{\"pass\":false,\"mode\":\"daily\",\"timestamp\":\"t\",\"errors\":[\"real gate failure\"]}" > "$rf"; exit 7'

  run run_release

  [ "$status" -eq 7 ]
  [ "$(cat "$RELCOUNT")" -eq 1 ]
  [ "$(n_retry_events)" -eq 0 ]
  [ "$(release_job_end | jq -r '.status')" = "fail" ]
  [ "$(release_job_end | jq -r '.exit_code')" -eq 7 ]
  grep -q '\[fail7-release\] done pass=false exit=7' \
    "$PROJ/tmp/fail7-release-last-run.log"
}

@test "default (stall_retries unset) = 0: a stall is NOT retried (today's behavior)" {
  PROJ="$(make_fixture_project stall0 can-merge-true.toml)"
  stub_claude ':'                       # never writes rf → persistent stall
  run run_release
  [ "$status" -eq 1 ]
  [ "$(n_retry_events)" -eq 0 ]         # no retry fired
  [ "$(cat "$RELCOUNT" 2>/dev/null || echo 0)" -eq 1 ]   # exactly one release spawn
  [ "$(job_end_status)" = "fail" ]      # synth-failure path unchanged
  [ "$(release_job_end | jq -r '.exit_code')" -eq 1 ]
}

@test "stall_retries=2: a stall then a written pass self-heals (one retry, no fail)" {
  PROJ="$(make_fixture_project stallpass can-merge-true.toml)"
  fixture_replace_in_place "$PROJ/.agents/config.toml" '^\[release\]$' \
    $'[release]\nstall_retries = 2'
  stub_claude '[ "$n" -ge 2 ] && printf "%s" "{\"pass\":true,\"mode\":\"daily\",\"timestamp\":\"t\"}" > "$rf"'
  run run_release
  [ "$status" -eq 0 ]
  [ "$(n_retry_events)" -eq 1 ]                   # retried exactly once
  [ "$(cat "$RELCOUNT")" -eq 2 ]                  # two release spawns
  [ "$(jq -r '.pass' "$PROJ/tmp/stallpass-release-result.json")" = "true" ]
  [ "$(job_end_status)" != "fail" ]               # ok/partial → medic NOT escalated
  [ "$(events_json | jq -r 'select(.event=="notification.decision") | .class' | sort -u)" = "routine" ]
}

@test "stall_retries=2: a genuine pass:false verdict is NEVER retried" {
  PROJ="$(make_fixture_project genuinefail can-merge-true.toml)"
  fixture_replace_in_place "$PROJ/.agents/config.toml" '^\[release\]$' \
    $'[release]\nstall_retries = 2'
  stub_claude 'printf "%s" "{\"pass\":false,\"mode\":\"daily\",\"timestamp\":\"t\",\"errors\":[\"real gate failure\"]}" > "$rf"'
  run run_release
  [ "$status" -eq 1 ]
  [ "$(n_retry_events)" -eq 0 ]         # a real verdict is not a stall
  [ "$(cat "$RELCOUNT")" -eq 1 ]        # one spawn only
  [ "$(job_end_status)" = "fail" ]
  [ "$(release_job_end | jq -r '.exit_code')" -eq 1 ]
  grep -q '\[genuinefail-release\] done pass=false exit=1' \
    "$PROJ/tmp/genuinefail-release-last-run.log"
  [ "$(events_json | jq -r 'select(.event=="notification.decision") | .class' | sort -u)" = "actionable" ]
}

@test "stall_retries=2: a persistent stall exhausts the retries then fails" {
  PROJ="$(make_fixture_project stallexhaust can-merge-true.toml)"
  fixture_replace_in_place "$PROJ/.agents/config.toml" '^\[release\]$' \
    $'[release]\nstall_retries = 2'
  stub_claude ':'                       # never writes → stall every attempt
  run run_release
  [ "$status" -eq 1 ]
  [ "$(n_retry_events)" -eq 2 ]         # retried twice (1 + 2 = 3 spawns)
  [ "$(cat "$RELCOUNT")" -eq 3 ]
  [ "$(job_end_status)" = "fail" ]
  [ "$(release_job_end | jq -r '.exit_code')" -eq 1 ]
}
