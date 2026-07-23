# shellcheck shell=bash
# spawn.sh — the crew's harness dispatcher.
#
# One entry point, `spawn_model`, behind every role runner's model call so a
# role can be backed by claude (default), codex, or hermes without the runners
# knowing which. With no harness selected it reproduces the exact historical
# `claude -p …` invocation, flag-for-flag, so unset config == today's behavior.
#
# Contract — the caller passes its flag *intent* (not a literal command line);
# spawn_model composes the right invocation per harness and sets these globals:
#
#   SPAWN_RAW          raw stdout of the harness (claude: the JSON envelope)
#   SPAWN_RC           the harness exit code (0 = ok; wrapper timeout kills -> 124)
#   SPAWN_TEXT         the model's final message text, normalized across harnesses
#   SPAWN_TOKENS       input+output tokens for the daily gate (0 if unavailable)
#   SPAWN_TOKEN_SOURCE which harness/path produced SPAWN_TOKENS (telemetry)
#
# Errexit-safe: the invocation is captured with `|| SPAWN_RC=$?` so a nonzero
# harness exit never trips a caller's `set -e`. Exit code 2 (bad invocation) is
# load-bearing: an unknown harness is a config error, not a no-op.

spawn_model() {
  local harness="claude" model="" provider="" prompt="" logfile="/dev/null"
  local timeout_val="" skip_perms=0 json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness)    harness="$2";     shift 2 ;;
      --model)      model="$2";       shift 2 ;;
      --provider)   provider="$2";    shift 2 ;;
      --prompt)     prompt="$2";      shift 2 ;;
      --log)        logfile="$2";     shift 2 ;;
      --timeout)    timeout_val="$2"; shift 2 ;;
      --skip-perms) skip_perms=1;     shift ;;
      --json)       json=1;           shift ;;
      *) echo "spawn_model: unknown arg '$1'" >&2; return 2 ;;
    esac
  done

  SPAWN_RAW=""; SPAWN_RC=0; SPAWN_TEXT=""; SPAWN_TOKENS=0
  SPAWN_TOKEN_SOURCE="$harness"

  # The runners' historical model default is the claude alias "sonnet" (baked as
  # ${<ROLE>_MODEL:-sonnet}); it is meaningless to codex/hermes and would hard-
  # fail them (`codex exec -m sonnet` → invalid model). Drop a claude-family
  # alias for a non-claude harness so it falls back to that harness's own
  # configured default. An explicit non-claude model is always respected.
  if [ "$harness" != "claude" ]; then
    case "$model" in sonnet|opus|haiku|claude*) model="" ;; esac
  fi

  case "$harness" in
    claude) _spawn_claude ;;
    codex)  _spawn_codex ;;
    hermes) _spawn_hermes ;;
    *) echo "spawn_model: unknown harness '$harness'" >&2; SPAWN_RC=2; return 2 ;;
  esac
}

# --- claude (Claude Code) ----------------------------------------------------
# Canonical argv order: claude -p [--model M] [--dangerously-skip-permissions]
# [--output-format json] PROMPT. This matches every historical call site
# verbatim except release/critic-watch with CRITIC_MODEL set, where --model
# formerly trailed --output-format json — same binary, same flags, identical
# behavior; the order is normalized here on purpose.
_spawn_claude() {
  local cmd=(claude -p)
  [ -n "$model" ] && cmd+=(--model "$model")
  [ "$skip_perms" -eq 1 ] && cmd+=(--dangerously-skip-permissions)
  [ "$json" -eq 1 ] && cmd+=(--output-format json)
  cmd+=("$prompt")

  SPAWN_RC=0
  if [ -n "$timeout_val" ]; then
    SPAWN_RAW="$(timeout "$timeout_val" "${cmd[@]}" 2>>"$logfile")" || SPAWN_RC=$?
  else
    SPAWN_RAW="$("${cmd[@]}" 2>>"$logfile")" || SPAWN_RC=$?
  fi

  # The --output-format json envelope carries .result and .usage.*; text mode
  # (no --json) leaves these empty, which the jq // fallbacks handle.
  SPAWN_TEXT="$(jq -r '.result // ""' <<<"$SPAWN_RAW" 2>/dev/null || true)"
  SPAWN_TOKENS="$(jq -r '((.usage.input_tokens // 0) + (.usage.output_tokens // 0))' \
    <<<"$SPAWN_RAW" 2>/dev/null || echo 0)"
  [[ "$SPAWN_TOKENS" =~ ^[0-9]+$ ]] || SPAWN_TOKENS=0
  SPAWN_TOKEN_SOURCE="claude"
}

# --- codex (OpenAI Codex CLI) ------------------------------------------------
# `codex exec` runs non-interactively. --json streams JSONL events; the final
# assistant message goes to a file via -o (stdout is the event stream, not the
# reply). skip-perms maps to sandboxed-but-unattended. Tokens come from the LAST
# turn.completed event's cumulative usage (input+output); 0 if none emitted.
# NB: never use --output-schema to force result.json — it is silently dropped
# when tools/MCP are active (openai/codex#15451); roles write result.json with
# codex's own file tools, exactly as under claude.
_spawn_codex() {
  local cmd=(codex exec)
  [ -n "$model" ]    && cmd+=(-m "$model")
  [ -n "$provider" ] && cmd+=(-c "model_provider=\"$provider\"")
  # Headless: codex exec cannot prompt, so approvals MUST be "never" for EVERY
  # role (without it codex errors out immediately). The sandbox scales with the
  # caller's write intent: skip-perms roles may write the workspace; read-mostly
  # roles (e.g. design) stay read-only.
  cmd+=(-c 'approval_policy="never"')
  if [ "$skip_perms" -eq 1 ]; then
    cmd+=(-s workspace-write)
  else
    cmd+=(-s read-only)
  fi
  local last_msg; last_msg="$(mktemp)"
  cmd+=(-o "$last_msg" --json "$prompt")

  # </dev/null is load-bearing: `codex exec` with a prompt arg ALSO drains any
  # piped stdin ("Reading additional input from stdin...") and errors in a
  # headless command-substitution context. Feed it EOF so it uses the arg only.
  SPAWN_RC=0
  if [ -n "$timeout_val" ]; then
    SPAWN_RAW="$(timeout "$timeout_val" "${cmd[@]}" </dev/null 2>>"$logfile")" || SPAWN_RC=$?
  else
    SPAWN_RAW="$("${cmd[@]}" </dev/null 2>>"$logfile")" || SPAWN_RC=$?
  fi

  SPAWN_TEXT="$(cat "$last_msg" 2>/dev/null || true)"
  rm -f "$last_msg"
  SPAWN_TOKENS="$(jq -rs 'map(select(.type=="turn.completed")) | last
    | (.usage.input_tokens // 0) + (.usage.output_tokens // 0)' \
    <<<"$SPAWN_RAW" 2>/dev/null || echo 0)"
  [[ "$SPAWN_TOKENS" =~ ^[0-9]+$ ]] || SPAWN_TOKENS=0
  SPAWN_TOKEN_SOURCE="codex"
}

# --- hermes (Hermes Agent) ---------------------------------------------------
# `hermes chat -q … -Q` prints ONLY the final reply to stdout; the session id
# lands on stderr as `session_id: <id>`. hermes emits no per-invocation token
# count, but its session store does — so we key off that id and read usage from
# `hermes sessions export` (verified fields: top-level input_tokens/output_tokens).
# 0-fallback on any failure keeps the daily token gate fed a real number, never
# a crash. --pass-session-id is what surfaces the id; --yolo/--accept-hooks are
# the unattended (skip-perms) equivalents.
_spawn_hermes() {
  local cmd=(hermes chat -q "$prompt" -Q --pass-session-id)
  [ -n "$model" ]    && cmd+=(-m "$model")
  [ -n "$provider" ] && cmd+=(--provider "$provider")
  [ "$skip_perms" -eq 1 ] && cmd+=(--yolo --accept-hooks)

  local errf; errf="$(mktemp)"
  SPAWN_RC=0
  if [ -n "$timeout_val" ]; then
    SPAWN_RAW="$(timeout "$timeout_val" "${cmd[@]}" </dev/null 2>"$errf")" || SPAWN_RC=$?
  else
    SPAWN_RAW="$("${cmd[@]}" </dev/null 2>"$errf")" || SPAWN_RC=$?
  fi
  SPAWN_TEXT="$SPAWN_RAW"
  # keep the stderr trail (incl. the session_id line) in the caller's log
  if [ "$logfile" != "/dev/null" ]; then cat "$errf" >>"$logfile" 2>/dev/null || true; fi

  local sid
  sid="$(grep -oE 'session_id:[[:space:]]*[A-Za-z0-9._-]+' "$errf" 2>/dev/null \
    | tail -1 | grep -oE '[A-Za-z0-9._-]+$' || true)"
  rm -f "$errf"
  SPAWN_TOKENS=0
  if [ -n "$sid" ]; then
    SPAWN_TOKENS="$(hermes sessions export - --session-id "$sid" 2>/dev/null \
      | jq -r '(.input_tokens // 0) + (.output_tokens // 0)' 2>/dev/null || echo 0)"
    [[ "$SPAWN_TOKENS" =~ ^[0-9]+$ ]] || SPAWN_TOKENS=0
  fi
  SPAWN_TOKEN_SOURCE="hermes-session"
}
