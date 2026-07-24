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

run_release() {
  RELEASE_STALL_BACKOFF_SEC=0 run_runner release "$PROJ" --mode daily
}

n_retry_events() { events_json | jq -c 'select(.event=="release.stall.retry")' | wc -l | tr -d ' '; }
job_end_status() { events_json | jq -r 'select(.event=="job.end" and (.svc|endswith("-release"))) | .status' | tail -1; }

@test "default (stall_retries unset) = 0: a stall is NOT retried (today's behavior)" {
  PROJ="$(make_fixture_project stall0 can-merge-true.toml)"
  stub_claude ':'                       # never writes rf → persistent stall
  run_release
  [ "$(n_retry_events)" -eq 0 ]         # no retry fired
  [ "$(cat "$RELCOUNT" 2>/dev/null || echo 0)" -eq 1 ]   # exactly one release spawn
  [ "$(job_end_status)" = "fail" ]      # synth-failure path unchanged
}

@test "stall_retries=2: a stall then a written pass self-heals (one retry, no fail)" {
  PROJ="$(make_fixture_project stallpass can-merge-true.toml)"
  sed -i "/^\[release\]/a stall_retries = 2" "$PROJ/.agents/config.toml"
  stub_claude '[ "$n" -ge 2 ] && printf "%s" "{\"pass\":true,\"mode\":\"daily\",\"timestamp\":\"t\"}" > "$rf"'
  run_release
  [ "$(n_retry_events)" -eq 1 ]                   # retried exactly once
  [ "$(cat "$RELCOUNT")" -eq 2 ]                  # two release spawns
  [ "$(jq -r '.pass' "$PROJ/tmp/stallpass-release-result.json")" = "true" ]
  [ "$(job_end_status)" != "fail" ]               # ok/partial → medic NOT escalated
}

@test "stall_retries=2: a genuine pass:false verdict is NEVER retried" {
  PROJ="$(make_fixture_project genuinefail can-merge-true.toml)"
  sed -i "/^\[release\]/a stall_retries = 2" "$PROJ/.agents/config.toml"
  stub_claude 'printf "%s" "{\"pass\":false,\"mode\":\"daily\",\"timestamp\":\"t\",\"errors\":[\"real gate failure\"]}" > "$rf"'
  run_release
  [ "$(n_retry_events)" -eq 0 ]         # a real verdict is not a stall
  [ "$(cat "$RELCOUNT")" -eq 1 ]        # one spawn only
  [ "$(job_end_status)" = "fail" ]
}

@test "stall_retries=2: a persistent stall exhausts the retries then fails" {
  PROJ="$(make_fixture_project stallexhaust can-merge-true.toml)"
  sed -i "/^\[release\]/a stall_retries = 2" "$PROJ/.agents/config.toml"
  stub_claude ':'                       # never writes → stall every attempt
  run_release
  [ "$(n_retry_events)" -eq 2 ]         # retried twice (1 + 2 = 3 spawns)
  [ "$(cat "$RELCOUNT")" -eq 3 ]
  [ "$(job_end_status)" = "fail" ]
}
