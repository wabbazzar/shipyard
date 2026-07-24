#!/usr/bin/env bats
#
# release-incomplete-notify.bats — a wall-clock-timeout'd (or SIGKILL'd) release
# run must NOT be reported as a FAILED check. Regression for the 2026-07-24
# false-alarm class: "<project> Proctor FAILED (daily)" fired on exit 124 while
# every suite was green (the `run-in-progress` sentinel was read as the verdict),
# and that pass:false result also became a false "proctor failed" dispatch item.
#
# These unit-test the pure decision logic in agents/lib/release-verdict.sh that
# the runner now keys the notify title (and the `incomplete` result flag) on.

setup() {
  load helpers
  quartet_setup
  # shellcheck disable=SC1091
  source "$QUARTET_ROOT/agents/lib/release-verdict.sh"
}

# ---- release_incomplete: what counts as "did not finish" -------------------

@test "exit 124 (timeout kill) is incomplete, not a failure" {
  run release_incomplete 124 ""
  [ "$status" -eq 0 ]
}

@test "exit 137 (SIGKILL / OOM) is incomplete" {
  run release_incomplete 137 ""
  [ "$status" -eq 0 ]
}

@test "clean exit with the run-in-progress sentinel is incomplete" {
  rf="$BATS_TEST_TMPDIR/result.json"
  printf '%s' '{"pass":false,"errors":["run-in-progress"]}' > "$rf"
  run release_incomplete 0 "$rf"
  [ "$status" -eq 0 ]
}

@test "an already-stamped incomplete result stays incomplete" {
  rf="$BATS_TEST_TMPDIR/result.json"
  printf '%s' '{"pass":false,"incomplete":true,"errors":[]}' > "$rf"
  run release_incomplete 0 "$rf"
  [ "$status" -eq 0 ]
}

@test "a genuine check failure (clean exit, real errors) is NOT incomplete" {
  rf="$BATS_TEST_TMPDIR/result.json"
  printf '%s' '{"pass":false,"vitest":{"failed":3},"errors":["vitest failed: 3 specs"]}' > "$rf"
  run release_incomplete 0 "$rf"
  [ "$status" -eq 1 ]
}

@test "a real pass (exit 0) is NOT incomplete" {
  rf="$BATS_TEST_TMPDIR/result.json"
  printf '%s' '{"pass":true,"errors":[]}' > "$rf"
  run release_incomplete 0 "$rf"
  [ "$status" -eq 1 ]
}

# ---- release_notify_title: the exact string the owner sees -----------------

@test "incomplete run says DID NOT FINISH, never FAILED" {
  run release_notify_title "bopthere" "Proctor" "daily" "false" "1"
  [ "$status" -eq 0 ]
  [ "$output" = "bopthere Proctor DID NOT FINISH (daily)" ]
  [[ "$output" != *FAILED* ]]
}

@test "a real failure still says FAILED" {
  run release_notify_title "bopthere" "Proctor" "daily" "false" "0"
  [ "$output" = "bopthere Proctor FAILED (daily)" ]
}

@test "a pass uses the plain title" {
  run release_notify_title "bopthere" "Proctor" "daily" "true" "0"
  [ "$output" = "bopthere Proctor (daily)" ]
}
