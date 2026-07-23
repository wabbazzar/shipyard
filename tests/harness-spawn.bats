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
# codex (Phase 2): codex exec -m/-c/-s -o --json; tokens from turn.completed
# ---------------------------------------------------------------------------

# A codex stub: log argv, write the final message to the -o file, emit a JSONL
# event stream including a turn.completed.usage event.
_argv_codex() {
  ARGVLOG="$BATS_TEST_TMPDIR/argv"
  make_stub_script codex "printf '%s\\n' \"\$@\" > '$ARGVLOG'
out=''; while [ \$# -gt 0 ]; do [ \"\$1\" = '-o' ] && out=\"\$2\"; shift; done
[ -n \"\$out\" ] && printf 'codex final' > \"\$out\"
printf '%s\\n' '{\"type\":\"thread.started\"}' '{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":100,\"cached_input_tokens\":10,\"output_tokens\":25}}'"
}

@test "spawn(codex): composes exec -m -c -s -o --json; text from -o, tokens from turn.completed" {
  _argv_codex
  source "$QUARTET_ROOT/agents/lib/spawn.sh"
  spawn_model --harness codex --model gpt-5.4 --provider openrouter --prompt "P" \
    --log /dev/null --timeout 900 --skip-perms --json
  [ "$SPAWN_RC" = "0" ]
  [ "$SPAWN_TEXT" = "codex final" ]
  [ "$SPAWN_TOKENS" = "125" ]          # 100 input + 25 output (cumulative)
  [ "$SPAWN_TOKEN_SOURCE" = "codex" ]
  # composed flags (order fixed by the dispatcher; -o path is a mktemp, so we
  # assert presence per line rather than the whole string):
  [ "$(head -1 "$ARGVLOG")" = "exec" ]
  grep -Fxq -- '-m' "$ARGVLOG"; grep -Fxq 'gpt-5.4' "$ARGVLOG"
  grep -Fxq -- '-c' "$ARGVLOG"; grep -Fxq 'model_provider="openrouter"' "$ARGVLOG"
  grep -Fxq -- '-s' "$ARGVLOG"; grep -Fxq 'workspace-write' "$ARGVLOG"
  grep -Fxq -- '--dangerously-bypass-approvals-and-sandbox' "$ARGVLOG"
  grep -Fxq -- '--json' "$ARGVLOG"
  [ "$(tail -1 "$ARGVLOG")" = "P" ]    # prompt is the final positional
}

@test "spawn(codex): no turn.completed event -> 0-token fallback (never crashes)" {
  make_stub_script codex "out=''; while [ \$# -gt 0 ]; do [ \"\$1\" = '-o' ] && out=\"\$2\"; shift; done
[ -n \"\$out\" ] && printf 'x' > \"\$out\"
printf '%s\\n' '{\"type\":\"thread.started\"}'"
  source "$QUARTET_ROOT/agents/lib/spawn.sh"
  spawn_model --harness codex --model m --prompt P --log /dev/null --json
  [ "$SPAWN_TOKENS" = "0" ]
  [ "$SPAWN_TEXT" = "x" ]
}

@test "spawn(codex): no provider -> no -c model_provider override" {
  _argv_codex
  source "$QUARTET_ROOT/agents/lib/spawn.sh"
  spawn_model --harness codex --model m --prompt P --log /dev/null --json
  run grep -Fxq -- '-c' "$ARGVLOG"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# hermes (Phase 3): chat -q -Q --pass-session-id; metered via sessions export
# ---------------------------------------------------------------------------

# A hermes stub: on `chat` log argv, print the reply (stdout) + session_id
# (stderr, matching the real CLI); on `sessions export` print a usage object
# with the verified top-level input_tokens/output_tokens fields.
_argv_hermes() {
  ARGVLOG="$BATS_TEST_TMPDIR/argv"
  make_stub_script hermes "if [ \"\$1\" = 'chat' ]; then
printf '%s\\n' \"\$@\" > '$ARGVLOG'
printf 'HERMES REPLY\\n'
printf 'session_id: TESTSID\\n' >&2
elif [ \"\$1\" = 'sessions' ]; then
printf '%s' '{\"input_tokens\":15050,\"output_tokens\":53}'
fi"
}

@test "spawn(hermes): composes chat -q -Q --pass-session-id ...; meters via sessions export" {
  _argv_hermes
  source "$QUARTET_ROOT/agents/lib/spawn.sh"
  spawn_model --harness hermes --model moonshotai/kimi-k3 --provider openrouter \
    --prompt "P" --log /dev/null --timeout 900 --skip-perms --json
  [ "$SPAWN_RC" = "0" ]
  [ "$SPAWN_TEXT" = "HERMES REPLY" ]
  [ "$SPAWN_TOKENS" = "15103" ]        # 15050 input + 53 output from sessions export
  [ "$SPAWN_TOKEN_SOURCE" = "hermes-session" ]
  [ "$(head -2 "$ARGVLOG" | tr '\n' ' ')" = "chat -q " ]
  grep -Fxq -- '-Q' "$ARGVLOG"
  grep -Fxq -- '--pass-session-id' "$ARGVLOG"
  grep -Fxq -- '-m' "$ARGVLOG"; grep -Fxq 'moonshotai/kimi-k3' "$ARGVLOG"
  grep -Fxq -- '--provider' "$ARGVLOG"; grep -Fxq 'openrouter' "$ARGVLOG"
  grep -Fxq -- '--yolo' "$ARGVLOG"; grep -Fxq -- '--accept-hooks' "$ARGVLOG"
}

@test "spawn(hermes): no session_id on stderr -> 0-token fallback (metered, never crashes)" {
  make_stub_script hermes "if [ \"\$1\" = 'chat' ]; then printf 'reply\\n'; else printf '%s' '{\"input_tokens\":1,\"output_tokens\":1}'; fi"
  source "$QUARTET_ROOT/agents/lib/spawn.sh"
  spawn_model --harness hermes --model m --prompt P --log /dev/null --json
  [ "$SPAWN_TOKENS" = "0" ]
  [ "$SPAWN_TEXT" = "reply" ]
  [ "$SPAWN_TOKEN_SOURCE" = "hermes-session" ]
}

@test "spawn(hermes): no provider -> no --provider flag" {
  _argv_hermes
  source "$QUARTET_ROOT/agents/lib/spawn.sh"
  spawn_model --harness hermes --model m --prompt P --log /dev/null --json
  run grep -Fxq -- '--provider' "$ARGVLOG"
  [ "$status" -ne 0 ]
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
