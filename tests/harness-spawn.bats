#!/usr/bin/env bats
#
# harness-spawn.bats — the harness dispatcher (agents/lib/spawn.sh).
#
# Proves byte-identity of the claude invocation the dispatcher composes for each
# historical call-site flag shape (paired with token-caps.bats test 10, which
# proves each runner passes the right flag intent to spawn_model). Every harness
# binary is a PATH stub — no network, no model. Phases 2/3 append codex/hermes
# cases here.

bats_require_minimum_version 1.5.0

setup() {
  load helpers
  quartet_setup
}

# A claude stub that logs each argv element on its own line to $ARGVLOG and
# prints a canonical envelope (result="ok", 2+3 tokens).
_argv_claude() {
  ARGVLOG="$BATS_TEST_TMPDIR/argv"
  make_stub_script claude "printf '%s\\n' \"\$@\" > '$ARGVLOG'
printf '%s' '{\"result\":\"ok\",\"usage\":{\"input_tokens\":2,\"output_tokens\":3}}'"
}

# ---------------------------------------------------------------------------
# Byte-identity: the composed claude argv, per historical call-site flag shape
# ---------------------------------------------------------------------------

@test "spawn(claude): timeout+skip-perms sites (build/medic/release/scribe) compose the exact line" {
  _argv_claude
  source "$QUARTET_ROOT/agents/lib/spawn.sh"
  spawn_model --harness claude --model sonnet --prompt "THE PROMPT" \
    --log /dev/null --timeout 900 --skip-perms --json
  run cat "$ARGVLOG"
  [ "$output" = "-p
--model
sonnet
--dangerously-skip-permissions
--output-format
json
THE PROMPT" ]
  [ "$SPAWN_RC" = "0" ]
  [ "$SPAWN_TOKENS" = "5" ]
  [ "$SPAWN_TEXT" = "ok" ]
  [ "$SPAWN_TOKEN_SOURCE" = "claude" ]
}

@test "spawn(claude): design site (no timeout, no skip-perms) composes the exact line" {
  _argv_claude
  source "$QUARTET_ROOT/agents/lib/spawn.sh"
  spawn_model --harness claude --model sonnet --prompt "THE PROMPT" \
    --log /dev/null --json
  run cat "$ARGVLOG"
  [ "$output" = "-p
--model
sonnet
--output-format
json
THE PROMPT" ]
  [ "$SPAWN_RC" = "0" ]
}

@test "spawn(claude): shoulder critic with CRITIC_MODEL unset omits --model" {
  _argv_claude
  source "$QUARTET_ROOT/agents/lib/spawn.sh"
  spawn_model --harness claude --model "" --prompt "THE PROMPT" \
    --log /dev/null --json
  run cat "$ARGVLOG"
  [ "$output" = "-p
--output-format
json
THE PROMPT" ]
}

# ---------------------------------------------------------------------------
# Errexit-safety + load-bearing exit codes
# ---------------------------------------------------------------------------

@test "spawn(claude): a nonzero harness exit is captured, not fatal" {
  make_stub_script claude "printf '%s' '{}'; exit 7"
  source "$QUARTET_ROOT/agents/lib/spawn.sh"
  set -e   # caller has errexit on; spawn must not trip it
  spawn_model --harness claude --model sonnet --prompt p --log /dev/null --json
  set +e
  [ "$SPAWN_RC" = "7" ]
  [ "$SPAWN_TOKENS" = "0" ]
}

@test "spawn: unknown harness is a config error (exit 2)" {
  source "$QUARTET_ROOT/agents/lib/spawn.sh"
  run spawn_model --harness bogus --model m --prompt p --log /dev/null --json
  [ "$status" -eq 2 ]
}
