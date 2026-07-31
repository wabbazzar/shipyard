#!/usr/bin/env bats
#
# release-blocking-gate.bats — runner-owned deterministic release stages.
# The public verdict and terminal event must wait for the configured command,
# whose outcome is reconciled into both JSON and process/event status.

setup() {
  load helpers
  quartet_setup
  make_stub systemctl 0
  make_stub notify.sh 0
  MODEL_PROMPT="$BATS_TEST_TMPDIR/model-prompt"
}

stub_model_pass() {
  make_stub_script claude '
for a in "$@"; do _last="$a"; done
printf "%s" "$_last" > "'"$MODEL_PROMPT"'"
rf="$(printf "%s" "$_last" | grep -oE "\"result_file\":[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/.*\"result_file\":[[:space:]]*\"//; s/\"$//")"
case "$rf" in
  *medic*) ;;
  *) printf "%s" "{\"pass\":true,\"mode\":\"daily\",\"timestamp\":\"model\"}" > "$rf" ;;
esac
printf "%s" "{\"result\":\"model complete\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
'
}

stub_model_in_progress() {
  make_stub_script claude '
for a in "$@"; do _last="$a"; done
rf="$(printf "%s" "$_last" | grep -oE "\"result_file\":[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/.*\"result_file\":[[:space:]]*\"//; s/\"$//")"
case "$rf" in
  *medic*) ;;
  *) printf "%s" "{\"pass\":false,\"incomplete\":true,\"errors\":[\"run-in-progress: waiting on e2eIsolated\"],\"e2eIsolated\":{\"status\":\"run-in-progress\"}}" > "$rf" ;;
esac
printf "%s" "{\"result\":\"model ended early\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
'
}

stub_model_in_progress_with_error() {
  make_stub_script claude '
for a in "$@"; do _last="$a"; done
rf="$(printf "%s" "$_last" | grep -oE "\"result_file\":[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/.*\"result_file\":[[:space:]]*\"//; s/\"$//")"
case "$rf" in
  *medic*) ;;
  *) printf "%s" "{\"pass\":false,\"incomplete\":true,\"errors\":[\"run-in-progress: waiting on e2eIsolated\",\"vitest failed: 2 specs\"],\"e2eIsolated\":{\"status\":\"run-in-progress\"}}" > "$rf" ;;
esac
printf "%s" "{\"result\":\"model found a failure\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
'
}

stub_model_hygiene_only() {
  make_stub_script claude '
for a in "$@"; do _last="$a"; done
if [ ! -e "'"$MODEL_PROMPT"'" ]; then
  printf "%s" "$_last" > "'"$MODEL_PROMPT"'"
fi
rf="$(printf "%s" "$_last" | grep -oE "\"result_file\":[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/.*\"result_file\":[[:space:]]*\"//; s/\"$//")"
project="$(dirname "$(dirname "$rf")")"
if [ "${MODEL_CREATE_DIRT_DURING_RUN:-0}" = "1" ]; then
  printf "%s\n" "created by model" >"$project/CREATED_DURING_RUN"
fi
case "$rf" in
  *medic*) ;;
  *)
    printf "%s" "{\"pass\":false,\"mode\":\"daily\",\"timestamp\":\"model\",\"incomplete\":true,\"vitest\":{\"passed\":325,\"failed\":0,\"skipped\":0},\"pytest\":{\"passed\":265,\"failed\":0,\"skipped\":1},\"typecheck\":{\"errors\":0,\"warnings\":13},\"build\":{\"ok\":true},\"fixAttempts\":[],\"scriptChecks\":{\"dbAudit\":true,\"liveApiHealth200\":true,\"worktreeClean\":false},\"dbIssues\":[],\"errors\":[\"run-in-progress: waiting on e2eIsolated\",\"worktree not clean: pre-existing files present at run start, not touched by this run - notify-only\"],\"e2eIsolated\":{\"status\":\"run-in-progress\"}}" > "$rf"
    ;;
esac
printf "%s" "{\"result\":\"model found pre-existing hygiene only\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
'
}

stub_model_pass_exit_9() {
  make_stub_script claude '
for a in "$@"; do _last="$a"; done
rf="$(printf "%s" "$_last" | grep -oE "\"result_file\":[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/.*\"result_file\":[[:space:]]*\"//; s/\"$//")"
case "$rf" in
  *medic*) ;;
  *) printf "%s" "{\"pass\":true,\"mode\":\"daily\",\"timestamp\":\"model\"}" > "$rf" ;;
esac
printf "%s" "{\"result\":\"model partial\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
exit 9
'
}

configure_gate() {
  local project="$1" command="$2" timeout_sec="${3:-5}"
  local modes="${4:-[\"daily\"]}" result_key="${5:-e2eIsolated}"
  cat >>"$project/.agents/config.toml" <<EOF

[release.blocking_gate]
command = "$command"
timeout_sec = $timeout_sec
modes = $modes
result_key = "$result_key"
EOF
}

job_end() {
  events_json | jq -c 'select(.event=="job.end" and (.svc|endswith("-release")))' | tail -1
}

wait_for_file() {
  local path="$1" i
  for i in $(seq 1 100); do
    [ -e "$path" ] && return 0
    sleep 0.02
  done
  return 1
}

@test "configured gate keeps prior public verdict and job.end private until one successful completion" {
  project="$(make_fixture_project blockpass can-merge-true.toml)"
  public="$project/tmp/blockpass-release-result.json"
  printf '%s' '{"pass":false,"timestamp":"prior"}' >"$public"
  prior="$(sha256sum "$public")"

  gate="$BATS_TEST_TMPDIR/blocking-pass.sh"
  started="$BATS_TEST_TMPDIR/gate-started"
  release="$BATS_TEST_TMPDIR/gate-release"
  calls="$BATS_TEST_TMPDIR/gate-calls"
  cat >"$gate" <<EOF
#!/usr/bin/env bash
echo call >>"$calls"
touch "$started"
while [ ! -e "$release" ]; do sleep 0.02; done
exit 0
EOF
  chmod +x "$gate"
  configure_gate "$project" "bash $gate"
  stub_model_pass

  QUARTET_DIR="$QUARTET_ROOT" QUARTET_EVENTS_DIR="$EVENTS_DIR" \
    QUARTET_NOTIFY_CMD="$NOTIFY_CMD" QUARTET_SOURCE=test \
    bash "$QUARTET_ROOT/agents/release/runner.sh" \
      --project "$project" --mode daily >"$BATS_TEST_TMPDIR/runner.out" 2>&1 &
  runner_pid=$!

  wait_for_file "$started"
  [ "$(sha256sum "$public")" = "$prior" ]
  [ -z "$(job_end)" ]
  touch "$release"
  wait "$runner_pid"

  [ "$(wc -l <"$calls" | tr -d ' ')" -eq 1 ]
  [ "$(jq -r '.pass' "$public")" = "true" ]
  [ "$(jq -r '.e2eIsolated.status' "$public")" = "completed" ]
  [ "$(jq -r '.e2eIsolated.pass' "$public")" = "true" ]
  [ "$(jq -r '.e2eIsolated.exitCode' "$public")" -eq 0 ]
  [ "$(job_end | jq -r '.status')" = "ok" ]
  [ "$(job_end | jq -r '.exit_code')" -eq 0 ]
  [ -z "$(find "$project/tmp" -maxdepth 1 -name '.*release-result.json' -print)" ]
  grep -q '"runner_owned": true' "$MODEL_PROMPT"
  grep -q '"result_key": "e2eIsolated"' "$MODEL_PROMPT"
}

@test "configured gate failure forces JSON event and runner exit to the same failure" {
  project="$(make_fixture_project blockfail can-merge-true.toml)"
  gate="$BATS_TEST_TMPDIR/blocking-fail.sh"
  calls="$BATS_TEST_TMPDIR/fail-calls"
  cat >"$gate" <<EOF
#!/usr/bin/env bash
echo call >>"$calls"
exit 7
EOF
  chmod +x "$gate"
  configure_gate "$project" "bash $gate"
  stub_model_pass

  run run_runner release "$project" --mode daily
  [ "$status" -eq 7 ]
  public="$project/tmp/blockfail-release-result.json"
  [ "$(wc -l <"$calls" | tr -d ' ')" -eq 1 ]
  [ "$(jq -r '.pass' "$public")" = "false" ]
  [ "$(jq -r '.e2eIsolated.status' "$public")" = "completed" ]
  [ "$(jq -r '.e2eIsolated.pass' "$public")" = "false" ]
  [ "$(jq -r '.e2eIsolated.exitCode' "$public")" -eq 7 ]
  [ "$(job_end | jq -r '.status')" = "fail" ]
  [ "$(job_end | jq -r '.exit_code')" -eq 7 ]
  jq -e '.errors[] | contains("e2eIsolated") and contains("exit 7")' "$public"
}

@test "configured gate timeout is preserved as exit 124 and a completed failure" {
  project="$(make_fixture_project blocktimeout can-merge-true.toml)"
  gate="$BATS_TEST_TMPDIR/blocking-timeout.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'sleep 2' >"$gate"
  chmod +x "$gate"
  configure_gate "$project" "bash $gate" 1
  stub_model_pass

  run run_runner release "$project" --mode daily
  [ "$status" -eq 124 ]
  public="$project/tmp/blocktimeout-release-result.json"
  [ "$(jq -r '.pass' "$public")" = "false" ]
  [ "$(jq -r '.e2eIsolated.status' "$public")" = "completed" ]
  [ "$(jq -r '.e2eIsolated.pass' "$public")" = "false" ]
  [ "$(jq -r '.e2eIsolated.exitCode' "$public")" -eq 124 ]
  [ "$(job_end | jq -r '.status')" = "fail" ]
  [ "$(job_end | jq -r '.exit_code')" -eq 124 ]
}

@test "model run-in-progress claim for runner-owned gate is never published as final" {
  project="$(make_fixture_project blockstale can-merge-true.toml)"
  configure_gate "$project" "true"
  stub_model_in_progress

  run run_runner release "$project" --mode daily
  [ "$status" -eq 0 ]
  public="$project/tmp/blockstale-release-result.json"
  [ "$(jq -r '.e2eIsolated.status' "$public")" = "completed" ]
  [ "$(jq -r '.e2eIsolated.pass' "$public")" = "true" ]
  [ "$(jq -r '.incomplete // false' "$public")" = "false" ]
  ! jq -e '.errors[]? | startswith("run-in-progress")' "$public"
  [ "$(jq -r '.pass' "$public")" = "true" ]
  [ "$(job_end | jq -r '.status')" = "ok" ]
  [ "$(job_end | jq -r '.exit_code')" -eq 0 ]
}

@test "successful gate preserves independent model failure while clearing its sentinel" {
  project="$(make_fixture_project blockindependent can-merge-true.toml)"
  configure_gate "$project" "true"
  stub_model_in_progress_with_error

  run run_runner release "$project" --mode daily
  [ "$status" -eq 0 ]
  public="$project/tmp/blockindependent-release-result.json"
  [ "$(jq -r '.e2eIsolated.status' "$public")" = "completed" ]
  [ "$(jq -r '.e2eIsolated.pass' "$public")" = "true" ]
  [ "$(jq -r '.incomplete // false' "$public")" = "false" ]
  [ "$(jq -r '.pass' "$public")" = "false" ]
  ! jq -e '.errors[]? | startswith("run-in-progress")' "$public"
  jq -e '.errors == ["vitest failed: 2 specs"]' "$public"
  [ "$(job_end | jq -r '.status')" = "fail" ]
}

@test "successful gate promotes unchanged pre-existing worktree hygiene and still notifies" {
  project="$(make_fixture_project blockhygiene can-merge-true.toml)"
  configure_gate "$project" "true"
  printf '\n[notify]\nsignal_level = "actionable"\n' >>"$project/.agents/config.toml"
  git -C "$project" add .agents/config.toml
  git -C "$project" commit -qm "configure release fixture"
  printf '%s\n' "pre-existing" >"$project/PREEXISTING"
  stub_model_hygiene_only

  run run_runner release "$project" --mode daily
  [ "$status" -eq 0 ]
  public="$project/tmp/blockhygiene-release-result.json"
  [ "$(jq -r '.pass' "$public")" = "true" ]
  [ "$(jq -r '.scriptChecks.worktreeClean' "$public")" = "false" ]
  [ "$(jq -r '.errors | length' "$public")" -eq 0 ]
  jq -e '.hygieneNotifications == [
    "worktree not clean: pre-existing files present at run start, not touched by this run - notify-only"
  ]' "$public"
  [ "$(job_end | jq -r '.status')" = "ok" ]
  decision="$(events_json | jq -c 'select(.event=="notification.decision")')"
  [ "$(jq -r '.class' <<<"$decision")" = "actionable" ]
  [ "$(jq -r '.outcome' <<<"$decision")" = "delivered" ]
  [[ "$(notify_log)" == *"pre-existing files present at run start"* ]]
  grep -q '"initial_worktree"' "$MODEL_PROMPT"
  grep -q '"dirty": true' "$MODEL_PROMPT"
  grep -Fq '?? PREEXISTING' "$MODEL_PROMPT"
}

@test "successful gate does not promote dirt first created during the model run" {
  project="$(make_fixture_project blocknewdirt can-merge-true.toml)"
  configure_gate "$project" "true"
  printf '\n[notify]\nsignal_level = "actionable"\n' >>"$project/.agents/config.toml"
  git -C "$project" add .agents/config.toml
  git -C "$project" commit -qm "configure release fixture"
  stub_model_hygiene_only
  export MODEL_CREATE_DIRT_DURING_RUN=1

  run run_runner release "$project" --mode daily
  [ "$status" -eq 0 ]
  public="$project/tmp/blocknewdirt-release-result.json"
  [ "$(jq -r '.pass' "$public")" = "false" ]
  [ "$(jq -r '.hygieneNotifications // [] | length' "$public")" -eq 0 ]
  jq -e '.errors == [
    "worktree not clean: pre-existing files present at run start, not touched by this run - notify-only"
  ]' "$public"
  [ "$(job_end | jq -r '.status')" = "fail" ]
  grep -q '"initial_worktree"' "$MODEL_PROMPT"
  grep -q '"dirty": false' "$MODEL_PROMPT"
}

@test "successful gate cannot turn a nonzero model exit into job.end ok" {
  project="$(make_fixture_project blockpartial can-merge-true.toml)"
  configure_gate "$project" "true"
  stub_model_pass_exit_9

  run run_runner release "$project" --mode daily
  [ "$status" -eq 9 ]
  public="$project/tmp/blockpartial-release-result.json"
  [ "$(jq -r '.pass' "$public")" = "true" ]
  [ "$(jq -r '.e2eIsolated.pass' "$public")" = "true" ]
  [ "$(job_end | jq -r '.status')" = "partial" ]
  [ "$(job_end | jq -r '.exit_code')" -eq 9 ]
}

@test "configured nonmatching mode does not stage or execute the gate" {
  project="$(make_fixture_project blockhook can-merge-true.toml)"
  marker="$BATS_TEST_TMPDIR/nonmatching-called"
  configure_gate "$project" "touch $marker" 5 '["daily"]'
  stub_model_pass

  run run_runner release "$project" --mode hook
  [ "$status" -eq 0 ]
  [ ! -e "$marker" ]
  [ "$(jq -r '.pass' "$project/tmp/blockhook-release-result.json")" = "true" ]
  [ -z "$(find "$project/tmp" -maxdepth 1 -name '.*release-result.json' -print)" ]
}

@test "absent blocking gate preserves direct model result behavior" {
  project="$(make_fixture_project blockabsent can-merge-true.toml)"
  stub_model_pass

  run run_runner release "$project" --mode daily
  [ "$status" -eq 0 ]
  public="$project/tmp/blockabsent-release-result.json"
  [ "$(jq -r '.pass' "$public")" = "true" ]
  [ "$(jq -r '.e2eIsolated // "absent"' "$public")" = "absent" ]
  ! grep -q '"runner_owned_gate"' "$MODEL_PROMPT"
  grep -q '"initial_worktree"' "$MODEL_PROMPT"
  grep -q '"dirty": false' "$MODEL_PROMPT"
}

@test "malformed blocking gate fails with exit 2 before model result or events" {
  cases=(
    'command = ""|timeout_sec = 5|modes = ["daily"]|result_key = "gate"'
    'command = "true"|timeout_sec = 0|modes = ["daily"]|result_key = "gate"'
    'command = "true"|timeout_sec = 5|modes = []|result_key = "gate"'
    'command = "true"|timeout_sec = 5|modes = ["post-merge"]|result_key = "gate"'
    'command = "true"|timeout_sec = 5|modes = ["daily"]|result_key = ""'
    'command = "true"|timeout_sec = 5|modes = ["daily"]|result_key = "gate"|extra = true'
  )
  make_stub claude 99

  i=0
  for fields in "${cases[@]}"; do
    i=$((i + 1))
    project="$(make_fixture_project "badgate$i" can-merge-true.toml)"
    {
      printf '\n[release.blocking_gate]\n'
      tr '|' '\n' <<<"$fields"
    } >>"$project/.agents/config.toml"

    run run_runner release "$project" --mode daily
    [ "$status" -eq 2 ]
    [ ! -e "$project/tmp/badgate$i-release-result.json" ]
  done
  [ "$(stub_calls claude)" -eq 0 ]
  [ -z "$(events_json)" ]
}
