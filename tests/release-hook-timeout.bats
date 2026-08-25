#!/usr/bin/env bats
#
# release-hook-timeout.bats — [release] hook_wall_clock_sec: a hard cap on
# `runner.sh --mode hook`.
#
# The bug (aurora ticket 059, 2026-08-25): hook mode is SYNCHRONOUS — an
# interactive session shells out to it and blocks on the verdict. It shared
# `wall_clock_sec` with daily (default 3600), and that cap only ever wrapped the
# model spawn; the runner-owned blocking gate and verify_gate then ran their own
# unbounded/extra time on top. A session sat 15+ minutes watching
# `run-in-progress` and the operator finally killed the release agent to get
# moving — exactly the outcome the gate exists to prevent.
#
# The fix: hook mode runs against a DEADLINE covering the whole run. Every
# bounded stage draws from the remaining budget; a stage with no budget left is
# skipped and the verdict is marked incomplete (DID NOT FINISH, not FAILED) so
# medic doesn't escalate it and the hub doesn't mint a false dispatch item.
#
# The effective timeout is observed by stubbing `timeout` on PATH — spawn.sh and
# the runner both invoke it by name, so the stub records the seconds each stage
# was actually given.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
  make_stub systemctl 0
  make_stub notify.sh 0
}

# ---------------------------------------------------------------------------
# Local helpers
# ---------------------------------------------------------------------------

# record_timeout — a `timeout` stub that logs the seconds it was handed and
# then really runs the command, so the rest of the runner behaves normally.
record_timeout() {
  make_stub_script timeout '
printf "%s\n" "$1" >> "'"$SHIM_LOG"'/timeout.secs"
shift
exec "$@"
'
}

# timeout_secs — every recorded budget, one per line, in call order.
timeout_secs() {
  local f="$SHIM_LOG/timeout.secs"
  [ -f "$f" ] && cat "$f" || true
}

# first_timeout — the budget handed to the model spawn (the first `timeout`).
first_timeout() { timeout_secs | head -1; }

# stub_model <pass> — a claude stub that writes the verdict the "model"
# returns into the result_file named in its prompt.
stub_model() {
  local pass="${1:-true}"
  make_stub_script claude '
for a in "$@"; do _last="$a"; done
rf="$(printf "%s" "$_last" | grep -oE "\"result_file\":[[:space:]]*\"[^\"]*\"" | head -1 | sed "s/.*\"result_file\":[[:space:]]*\"//; s/\"$//")"
case "$rf" in
  *release-result.json) printf "%s" "{\"pass\":'"$pass"',\"mode\":\"hook\",\"timestamp\":\"t\"}" > "$rf" ;;
esac
printf "%s" "{\"result\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}"
'
}

# set_release_key <project> <line> — insert a key into the [release] table.
set_release_key() {
  fixture_replace_in_place "$1/.agents/config.toml" '^\[release\]$' "[release]
$2"
}

result_file() { echo "$1/tmp/$(basename "$1")-release-result.json"; }
job_status() { events_json | jq -r 'select(.event=="job.end" and (.svc|endswith("-release"))) | .status' | tail -1; }

# ---------------------------------------------------------------------------
# The cap itself
# ---------------------------------------------------------------------------

@test "hook mode caps the run at 600s by default, not the 3600s daily wall clock" {
  PROJ="$(make_fixture_project hookdef can-merge-true.toml)"
  record_timeout
  stub_model true
  run run_runner release "$PROJ" --mode hook
  [ "$status" -eq 0 ]
  [ "$(first_timeout)" -le 600 ]
  [ "$(first_timeout)" -ge 590 ]
}

@test "daily mode is untouched — it still gets the full wall_clock_sec" {
  PROJ="$(make_fixture_project dailyuncapped can-merge-true.toml)"
  record_timeout
  stub_model true
  run run_runner release "$PROJ" --mode daily
  [ "$status" -eq 0 ]
  [ "$(first_timeout)" -eq 3600 ]
}

@test "[release] hook_wall_clock_sec sets the hook cap explicitly" {
  PROJ="$(make_fixture_project hookexplicit can-merge-true.toml)"
  set_release_key "$PROJ" 'hook_wall_clock_sec = 120'
  record_timeout
  stub_model true
  run run_runner release "$PROJ" --mode hook
  # discriminates from the 600s default: that would be far above 120
  [ "$status" -eq 0 ]
  [ "$(first_timeout)" -le 120 ]
  [ "$(first_timeout)" -ge 110 ]
}

@test "a hook cap ABOVE the default is honored when set deliberately" {
  PROJ="$(make_fixture_project hooklong can-merge-true.toml)"
  set_release_key "$PROJ" 'hook_wall_clock_sec = 1800'
  record_timeout
  stub_model true
  run run_runner release "$PROJ" --mode hook
  [ "$status" -eq 0 ]
  [ "$(first_timeout)" -le 1800 ]
  [ "$(first_timeout)" -gt 600 ]
}

@test "a tighter wall_clock_sec still wins for hooks (never loosened by the default)" {
  PROJ="$(make_fixture_project hooktight can-merge-true.toml)"
  set_release_key "$PROJ" 'wall_clock_sec = 90'
  record_timeout
  stub_model true
  run run_runner release "$PROJ" --mode hook
  [ "$status" -eq 0 ]
  [ "$(first_timeout)" -le 90 ]
  [ "$(first_timeout)" -ge 80 ]
}

@test "a garbage hook_wall_clock_sec falls back to the safe default" {
  PROJ="$(make_fixture_project hookjunk can-merge-true.toml)"
  set_release_key "$PROJ" 'hook_wall_clock_sec = "soon"'
  record_timeout
  stub_model true
  run run_runner release "$PROJ" --mode hook
  [ "$status" -eq 0 ]
  [ "$(first_timeout)" -le 600 ]
  [ "$(first_timeout)" -gt 0 ]
}

# ---------------------------------------------------------------------------
# The deadline covers the WHOLE run, not just the model spawn
# ---------------------------------------------------------------------------

@test "the blocking gate draws from the remaining hook budget, not its own full timeout" {
  # blocking_gate timeout_sec (900) exceeds the hook cap (60): the gate must be
  # bounded by what is left of the hook budget, or the hook blows past its cap.
  PROJ="$(make_fixture_project hookgate can-merge-true.toml)"
  set_release_key "$PROJ" 'hook_wall_clock_sec = 60
blocking_gate = { command = "true", timeout_sec = 900, modes = ["hook"], result_key = "gate" }'
  record_timeout
  stub_model true
  run run_runner release "$PROJ" --mode hook
  # two bounded stages ran: the model spawn, then the gate
  [ "$(timeout_secs | wc -l)" -ge 2 ]
  gate_budget="$(timeout_secs | sed -n 2p)"
  [ "$gate_budget" -le 60 ]
  [ "$gate_budget" -gt 0 ]
}

@test "verify_gate re-runs are bounded by the remaining hook budget" {
  # verify_gate eval'd typecheck + test_cmd with NO timeout at all — on aurora
  # that is a 20-minute pytest suite running AFTER the model already spent the
  # wall clock. Under a hook deadline both must be wrapped.
  PROJ="$(make_fixture_project hookverify can-merge-true.toml)"
  set_release_key "$PROJ" 'hook_wall_clock_sec = 60
verify_gate = true'
  fixture_replace_in_place "$PROJ/.agents/config.toml" '^test_cmd .*$' 'test_cmd     = "true"'
  fixture_replace_in_place "$PROJ/.agents/config.toml" '^typecheck .*$' 'typecheck    = "true"'
  record_timeout
  stub_model true
  run run_runner release "$PROJ" --mode hook
  # spawn + typecheck + test_cmd = three bounded stages
  [ "$(timeout_secs | wc -l)" -ge 3 ]
  for b in $(timeout_secs); do
    [ "$b" -le 60 ]
    [ "$b" -gt 0 ]
  done
}

# ---------------------------------------------------------------------------
# What happens when the cap actually trips
# ---------------------------------------------------------------------------

@test "a hook killed by its cap reports DID NOT FINISH, not FAILED" {
  PROJ="$(make_fixture_project hookkill can-merge-true.toml)"
  set_release_key "$PROJ" 'hook_wall_clock_sec = 1'
  # a model that never returns — the cap is the only thing that ends this run
  make_stub_script claude 'sleep 30'
  run run_runner release "$PROJ" --mode hook
  [ "$status" -ne 0 ]
  RF="$(result_file "$PROJ")"
  [ -s "$RF" ]
  [ "$(jq -r '.pass' "$RF")" = "false" ]
  [ "$(jq -r '.incomplete' "$RF")" = "true" ]
  # the owner is told it ran out of time, not that a check failed
  notify_log | grep -q 'DID NOT FINISH'
}

@test "a hook that exhausts its budget skips the blocking gate rather than overrunning" {
  PROJ="$(make_fixture_project hookexhaust can-merge-true.toml)"
  set_release_key "$PROJ" 'hook_wall_clock_sec = 1
blocking_gate = { command = "sleep 30 && true", timeout_sec = 900, modes = ["hook"], result_key = "gate" }'
  make_stub_script claude 'sleep 30'
  run run_runner release "$PROJ" --mode hook
  [ "$status" -ne 0 ]
  RF="$(result_file "$PROJ")"
  [ "$(jq -r '.incomplete' "$RF")" = "true" ]
  # the gate never got to burn another 30s past an already-blown deadline
  run jq -r '.gate // "absent"' "$RF"
  [ "$output" != "true" ]
}

@test "the cap trip is recorded as an event with the budget that was enforced" {
  PROJ="$(make_fixture_project hookevent can-merge-true.toml)"
  set_release_key "$PROJ" 'hook_wall_clock_sec = 1'
  make_stub_script claude 'sleep 30'
  run run_runner release "$PROJ" --mode hook
  [ "$(events_json | jq -r 'select(.event=="release.hook.timeout") | .cap_sec' | tail -1)" = "1" ]
}

@test "a hook finishing inside its budget is unaffected — normal pass, no timeout event" {
  PROJ="$(make_fixture_project hookfast can-merge-true.toml)"
  set_release_key "$PROJ" 'hook_wall_clock_sec = 600'
  stub_model true
  run run_runner release "$PROJ" --mode hook
  [ "$status" -eq 0 ]
  [ "$(job_status)" = "ok" ]
  [ "$(jq -r '.pass' "$(result_file "$PROJ")")" = "true" ]
  [ "$(events_json | jq -r 'select(.event=="release.hook.timeout")' | wc -l)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The model is told its budget
# ---------------------------------------------------------------------------

@test "the hook budget is handed to the model in RUN CONTEXT" {
  # A cap the model cannot see just kills it mid-suite with no verdict. It has
  # to know how long it has so it can scope the checks it starts.
  PROJ="$(make_fixture_project hookctx can-merge-true.toml)"
  set_release_key "$PROJ" 'hook_wall_clock_sec = 300'
  stub_model true
  run run_runner release "$PROJ" --mode hook
  [ "$status" -eq 0 ]
  budget="$(stub_argv claude | grep -oE '"wall_clock_budget_sec":[[:space:]]*[0-9]+' | head -1 | grep -oE '[0-9]+')"
  [ -n "$budget" ]
  [ "$budget" -le 300 ]
  [ "$budget" -ge 290 ]
}

@test "daily hands the model the full wall_clock_sec as its budget" {
  PROJ="$(make_fixture_project dailyctx can-merge-true.toml)"
  stub_model true
  run run_runner release "$PROJ" --mode daily
  [ "$status" -eq 0 ]
  stub_argv claude | grep -qE '"wall_clock_budget_sec":[[:space:]]*3600'
}

# ---------------------------------------------------------------------------
# Discoverability
# ---------------------------------------------------------------------------

@test "--check-config advertises the effective hook cap" {
  PROJ="$(make_fixture_project hookcfg can-merge-true.toml)"
  run run_runner release "$PROJ" --check-config
  [ "$status" -eq 0 ]
  run jq -r '.budgets.hook_wall_clock_sec' <<<"$output"
  [ "$output" = "600" ]
}
