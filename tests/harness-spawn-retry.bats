#!/usr/bin/env bats
#
# harness-spawn-retry.bats — the transient-stall retry in spawn.sh's dispatcher
# (ticket: medic-transient-storm-cooldown, defect 1).
#
# The 2026-07-24 storm's trigger was a single Anthropic SSE stall ("API Error:
# Response stalled mid-stream", exit 1) sinking a whole daily run because
# spawn_model had no retry. These cases pin the contract: retry a transient
# stall, but NEVER a wrapper timeout (124) or a non-transient failure, and
# SPAWN_STALL_RETRIES=0 reproduces the pre-fix single-shot behavior.
#
# Every claude invocation is a PATH stub — no network, no model. `timeout` is
# real coreutils (not stubbed), so the 124 case exercises the actual guard.
# make_stub_script logs each call to $SHIM_LOG/claude.argv; stub_calls counts.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
}

# A claude stub that STALLS (stderr signature + exit 1) on call 1, then SUCCEEDS
# with a canonical envelope on every later call. Call number is derived from the
# argv log make_stub_script already writes (one line appended per invocation).
_stub_stall_then_ok() {
  make_stub_script claude "n=\$(wc -l < '$SHIM_LOG/claude.argv' 2>/dev/null | tr -d ' ')
if [ \"\${n:-0}\" -le 1 ]; then
  printf 'API Error: Response stalled mid-stream. The response above may be incomplete.\\n' >&2
  exit 1
fi
printf '%s' '{\"result\":\"ok\",\"usage\":{\"input_tokens\":2,\"output_tokens\":3}}'"
}

@test "retry: a transient stall is retried, then succeeds (2 invocations, RC=0)" {
  _stub_stall_then_ok
  source "$QUARTET_ROOT/agents/lib/spawn.sh"
  export SPAWN_STALL_BACKOFF="0 0"   # no real sleeping in the test
  spawn_model --harness claude --model sonnet --prompt P \
    --log /dev/null --timeout 900 --skip-perms --json
  [ "$SPAWN_RC" = "0" ]
  [ "$SPAWN_TEXT" = "ok" ]
  [ "$SPAWN_TOKENS" = "5" ]
  [ "$(stub_calls claude)" = "2" ]   # stalled once, retried once
}

@test "retry: a wrapper timeout (RC=124) is NEVER retried (1 invocation)" {
  # Stub sleeps past a 1s --timeout; real `timeout` kills it -> RC 124.
  make_stub_script claude "sleep 3"
  source "$QUARTET_ROOT/agents/lib/spawn.sh"
  export SPAWN_STALL_BACKOFF="0 0"
  spawn_model --harness claude --model sonnet --prompt P \
    --log /dev/null --timeout 1 --skip-perms --json
  [ "$SPAWN_RC" = "124" ]
  [ "$(stub_calls claude)" = "1" ]   # a real runaway is not a transient stall
}

@test "retry: a non-transient failure is NEVER retried (1 invocation, RC preserved)" {
  make_stub_script claude "printf 'boom: a real error, not a stall\\n' >&2; exit 1"
  source "$QUARTET_ROOT/agents/lib/spawn.sh"
  export SPAWN_STALL_BACKOFF="0 0"
  spawn_model --harness claude --model sonnet --prompt P \
    --log /dev/null --timeout 900 --skip-perms --json
  [ "$SPAWN_RC" = "1" ]
  [ "$(stub_calls claude)" = "1" ]
}

@test "retry: SPAWN_STALL_RETRIES=0 reproduces pre-fix single-shot behavior" {
  _stub_stall_then_ok
  source "$QUARTET_ROOT/agents/lib/spawn.sh"
  export SPAWN_STALL_RETRIES=0
  export SPAWN_STALL_BACKOFF="0 0"
  spawn_model --harness claude --model sonnet --prompt P \
    --log /dev/null --timeout 900 --skip-perms --json
  [ "$SPAWN_RC" = "1" ]               # the stall is fatal, exactly like today
  [ "$(stub_calls claude)" = "1" ]
}
