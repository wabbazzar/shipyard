#!/usr/bin/env bash
# release-verdict.sh — decide how a release/proctor run is reported to the human.
#
# The bug this fixes (2026-07-24): a run killed by its wall-clock timeout leaves
# the caller's `run-in-progress` sentinel (or no result.json at all) as the
# verdict. `pass:false` then read as a hard failure fired a Signal "<proj>
# <Display> FAILED" even though every suite was green, AND that pass:false result
# became an approvable "proctor failed" dispatch item on the hub. An unfinished
# run is NOT a failed check: it should be reported honestly ("DID NOT FINISH")
# and flagged so the dashboard does not mint a false dispatch item from it.
#
# Two pure functions, no side effects, sourced by agents/release/runner.sh and
# unit-tested directly (tests/release-incomplete-notify.bats). Requires `jq`.

# release_incomplete <exit_code> <result_file>
#   exit 0  → the run did not finish (wall-clock timeout / SIGKILL, or a
#             `run-in-progress`/incomplete result), so it is NOT a genuine
#             check failure.
#   exit 1  → not incomplete (a real pass or a real failure).
# Note: a session that exits WITHOUT a timeout and WITHOUT the sentinel (e.g.
# backgrounded a step and exited 0) is a real incident and stays a failure —
# this returns 1 for it.
release_incomplete() {
  local exit_code="$1" result_file="$2"
  [ "$exit_code" = "124" ] && return 0   # `timeout(1)` killed the run
  [ "$exit_code" = "137" ] && return 0   # SIGKILL / OOM killed the run
  if [ -n "$result_file" ] && [ -s "$result_file" ] && jq -e '
        (.incomplete == true)
        or ((.errors // []) | map(tostring) | any(test("run-in-progress")))
      ' "$result_file" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# release_notify_title <project> <Display> <mode> <pass:true|false> <incomplete:0|1>
#   Echoes the exact Signal title the owner sees:
#     pass=true          → "<project> <Display> (<mode>)"
#     incomplete=1        → "<project> <Display> DID NOT FINISH (<mode>)"
#     otherwise (failure) → "<project> <Display> FAILED (<mode>)"
release_notify_title() {
  local project="$1" display="$2" mode="$3" pass="$4" incomplete="$5"
  if [ "$pass" = "true" ]; then
    printf '%s %s (%s)' "$project" "$display" "$mode"
  elif [ "$incomplete" = "1" ]; then
    printf '%s %s DID NOT FINISH (%s)' "$project" "$display" "$mode"
  else
    printf '%s %s FAILED (%s)' "$project" "$display" "$mode"
  fi
}
