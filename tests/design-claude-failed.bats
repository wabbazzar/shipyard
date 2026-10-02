#!/usr/bin/env bats
#
# design-claude-failed.bats — pins the design runner's `claude_failed` path
# (ticket: design-claude-failed-diagnosis, phase 1).
#
# With `[design] failure_detail = true` the failing job.end must carry
# exit_code + cause, and tmp/<svc>-last-failure.log must survive. With the key
# unset the path must stay byte-identical to the pre-change runner (guards).
# `claude` and `gh` are PATH stubs: no network, no model.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
  make_stub gh 1
}

# _project <name> <detail: on|off> — fixture with no proposals (so the runner
# reaches the spawn: no open_cap, no budget skip).
_project() {
  local p
  p="$(make_fixture_project "$1" names-spacetime.toml)"
  if [ "$2" = "on" ]; then
    printf '\n[design]\nfailure_detail = true\n' >> "$p/.agents/config.toml"
  fi
  printf '%s\n' "$p"
}

_job_end() { events_json | jq -c 'select(.event=="job.end" and .status=="fail")'; }

_stub_claude() {  # <rc> <stderr-line-or-empty>
  make_stub_script claude "[ -n '$2' ] && printf '%s\\n' '$2' >&2; exit $1"
}

# _check <name> <rc> <stderr> <cause> <expect-log-line>
_check_on() {
  local p; p="$(_project "$1" on)"
  _stub_claude "$2" "$3"
  run run_runner design "$p"
  [ "$status" -eq 0 ]
  # argv log holds the multi-line prompt, so count invocations by their first line
  [ "$(grep -c '^-p ' "$SHIM_LOG/claude.argv")" = "1" ]
  local je; je="$(_job_end)"
  [ "$(jq -r .reason <<<"$je")" = "claude_failed" ]
  [ "$(jq -r .exit_code <<<"$je")" = "$2" ]
  [ "$(jq -r .cause <<<"$je")" = "$4" ]
  local log="$p/tmp/$1-mentat-last-failure.log"
  [ -f "$log" ]
  grep -q "$4" "$log"
  if [ -n "$3" ]; then grep -qF "$3" "$log"; fi
  grep -qE "rc=?:? ?$2|rc.*$2" "$log"
}

@test "failure_detail: rc=1 'Credit balance is too low' -> exit_nonzero + failure log" {
  _check_on fd1 1 'Credit balance is too low' exit_nonzero
}

@test "failure_detail: rc=0 empty stdout -> empty_output + failure log (ts/rc/cause)" {
  _check_on fd2 0 '' empty_output
}

@test "failure_detail: stall signature with SPAWN_STALL_RETRIES=0 -> stall_exhausted" {
  export SPAWN_STALL_RETRIES=0
  _check_on fd3 1 'API Error: Response stalled mid-stream' stall_exhausted
}

@test "failure_detail: rc=124 -> timeout + failure log" {
  _check_on fd4 124 '' timeout
}

# --- guards: key unset => pre-change behavior, must pass on the old runner ---

@test "guard: key unset, rc=1 -> claude_failed job.end has no exit_code/cause, no failure log" {
  local p; p="$(_project g1 off)"
  _stub_claude 1 'Credit balance is too low'
  run run_runner design "$p"
  [ "$status" -eq 0 ]
  local je; je="$(_job_end)"
  [ "$(jq -r .reason <<<"$je")" = "claude_failed" ]
  [ "$(jq 'has("exit_code") or has("cause")' <<<"$je")" = "false" ]
  run bash -c "ls '$p'/tmp/*-last-failure.log"
  [ "$status" -ne 0 ]
}

@test "guard: key unset, rc=0 empty stdout -> same bare claude_failed, no failure log" {
  local p; p="$(_project g2 off)"
  _stub_claude 0 ''
  run run_runner design "$p"
  [ "$status" -eq 0 ]
  local je; je="$(_job_end)"
  [ "$(jq -r .reason <<<"$je")" = "claude_failed" ]
  [ "$(jq 'has("exit_code") or has("cause")' <<<"$je")" = "false" ]
  run bash -c "ls '$p'/tmp/*-last-failure.log"
  [ "$status" -ne 0 ]
}
