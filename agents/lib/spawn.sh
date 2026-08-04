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

# --- transient-stall retry (ticket: medic-transient-storm-cooldown) ----------
# A transient upstream/stream error (the claude CLI prints "API Error: Response
# stalled mid-stream" and exits non-zero) sank whole daily runs. Retry those a
# bounded number of times across ALL harnesses (D-5). NEVER retry a wrapper
# timeout (124 = a real runaway, the deliberate guard) or a non-transient
# failure. Count: ${SPAWN_STALL_RETRIES:-2} (D-4; 0 = pre-fix single-shot,
# byte-identical). Backoff seconds per attempt: ${SPAWN_STALL_BACKOFF:-5 15}.
_SPAWN_STALL_RE='Response stalled mid-stream|overloaded_error|Connection error|error 5[0-9][0-9]|(^|[^0-9])(429|529)([^0-9]|$)'
# Linux rejects any single execve argument above roughly 128 KiB regardless of
# total ARG_MAX. Stay comfortably below that boundary for harnesses that offer
# no file/stdin query mode (currently Hermes).
_SPAWN_SAFE_ARG_PROMPT_BYTES=100000

_prompt_byte_count() {
  LC_ALL=C printf '%s' "$1" | wc -c | tr -d ' '
}

_normalize_outcome_usage() {
  local name value
  for name in SPAWN_INPUT_TOKENS SPAWN_CACHE_READ_TOKENS \
      SPAWN_CACHE_WRITE_TOKENS SPAWN_OUTPUT_TOKENS SPAWN_REASONING_TOKENS; do
    value="${!name:-}"
    [[ "$value" =~ ^[0-9]+$ ]] || printf -v "$name" '%s' ""
  done
  [[ "$SPAWN_PROVIDER" =~ ^[A-Za-z0-9._:@/-]{1,128}$ ]] || SPAWN_PROVIDER=""
  if [ -z "$SPAWN_MODEL" ] || [ "${#SPAWN_MODEL}" -gt 256 ] ||
     [[ ! "$SPAWN_MODEL" =~ ^[A-Za-z0-9._:@/-]+$ ]]; then
    SPAWN_MODEL=""
  fi
}

# _run_harness <stdin_mode> <cmd...>
#   stdin_mode "null" feeds the command </dev/null;
#   stdin_mode "file:<path>" feeds it from that private file;
#   an empty mode preserves inherited stdin.
# Sets SPAWN_RAW, SPAWN_RC, and _SPAWN_STDERR (the final attempt's stderr, also
# appended to $logfile as before). Errexit-safe: callers invoke it as
# `_run_harness … || true` and then read the globals.
_run_harness() {
  local stdin_mode="$1"; shift
  local max="${SPAWN_STALL_RETRIES:-2}" attempt=0 errf b stdin_file=""
  case "$stdin_mode" in
    file:*) stdin_file="${stdin_mode#file:}" ;;
  esac
  # shellcheck disable=SC2206  # intentional word-split into a backoff list
  local -a backoffs=(${SPAWN_STALL_BACKOFF:-5 15})
  while : ; do
    errf="$(mktemp)"; SPAWN_RC=0
    if [ "$stdin_mode" = "null" ]; then
      SPAWN_RAW="$("$@" </dev/null 2>"$errf")" || SPAWN_RC=$?
    elif [ -n "$stdin_file" ]; then
      SPAWN_RAW="$("$@" <"$stdin_file" 2>"$errf")" || SPAWN_RC=$?
    else
      SPAWN_RAW="$("$@" 2>"$errf")" || SPAWN_RC=$?
    fi
    _SPAWN_STDERR="$(cat "$errf" 2>/dev/null || true)"; rm -f "$errf"
    if [ "$logfile" != "/dev/null" ] && [ -n "$_SPAWN_STDERR" ]; then
      printf '%s\n' "$_SPAWN_STDERR" >>"$logfile" 2>/dev/null || true
    fi
    # Terminal: success, a real timeout, or retries exhausted.
    if [ "$SPAWN_RC" -eq 0 ] || [ "$SPAWN_RC" -eq 124 ] || [ "$attempt" -ge "$max" ]; then
      return "$SPAWN_RC"
    fi
    # Retry ONLY a transient-stall signature; any other failure is terminal.
    if printf '%s' "$_SPAWN_STDERR$SPAWN_RAW" | grep -qEi "$_SPAWN_STALL_RE"; then
      attempt=$((attempt+1))
      b="${backoffs[$((attempt-1))]:-15}"
      if [ "$logfile" != "/dev/null" ]; then
        echo "[spawn] transient stall (rc=$SPAWN_RC); retry $attempt/$max after ${b}s" \
          >>"$logfile" 2>/dev/null || true
      fi
      if [ "$b" -gt 0 ] 2>/dev/null; then sleep "$b"; fi
      continue
    fi
    return "$SPAWN_RC"
  done
}

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
  SPAWN_PROVIDER=""; SPAWN_MODEL=""; SPAWN_INPUT_TOKENS=""
  SPAWN_CACHE_READ_TOKENS=""; SPAWN_CACHE_WRITE_TOKENS=""
  SPAWN_OUTPUT_TOKENS=""; SPAWN_REASONING_TOKENS=""
  export SPAWN_PROVIDER SPAWN_MODEL SPAWN_INPUT_TOKENS
  export SPAWN_CACHE_READ_TOKENS SPAWN_CACHE_WRITE_TOKENS
  export SPAWN_OUTPUT_TOKENS SPAWN_REASONING_TOKENS
  SPAWN_TOKEN_SOURCE="$harness"

  # The runners' historical model default is the claude alias "sonnet" (baked as
  # ${<ROLE>_MODEL:-sonnet}); it is meaningless to codex/hermes and would hard-
  # fail them (`codex exec -m sonnet` → invalid model). Drop a claude-family
  # alias for a non-claude harness so it falls back to that harness's own
  # configured default. An explicit non-claude model is always respected.
  if [ "$harness" != "claude" ]; then
    case "$model" in sonnet|opus|haiku|claude*) model="" ;; esac
  fi
  SPAWN_PROVIDER="${provider:-$harness}"
  SPAWN_MODEL="$model"

  case "$harness" in
    claude) _spawn_claude ;;
    codex)  _spawn_codex ;;
    hermes) _spawn_hermes ;;
    *) echo "spawn_model: unknown harness '$harness'" >&2; SPAWN_RC=2; return 2 ;;
  esac
  _normalize_outcome_usage
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
  local prompt_file="" stdin_mode=""
  local prompt_bytes
  prompt_bytes="$(_prompt_byte_count "$prompt")"
  if [ "$prompt_bytes" -gt "$_SPAWN_SAFE_ARG_PROMPT_BYTES" ]; then
    prompt_file="$(mktemp)"
    (umask 077; printf '%s' "$prompt" >"$prompt_file") || {
      rm -f "$prompt_file"
      SPAWN_RC=1
      return 1
    }
    stdin_mode="file:$prompt_file"
  else
    cmd+=("$prompt")
  fi

  local -a inv=()
  if [ -n "$timeout_val" ]; then inv+=(timeout "$timeout_val"); fi
  inv+=("${cmd[@]}")
  _run_harness "$stdin_mode" "${inv[@]}" || true
  [ -z "$prompt_file" ] || rm -f "$prompt_file"

  # The --output-format json envelope carries .result and .usage.*; text mode
  # (no --json) leaves these empty, which the jq // fallbacks handle.
  SPAWN_TEXT="$(jq -r '.result // ""' <<<"$SPAWN_RAW" 2>/dev/null || true)"
  SPAWN_TOKENS="$(jq -r '((.usage.input_tokens // 0) + (.usage.output_tokens // 0))' \
    <<<"$SPAWN_RAW" 2>/dev/null || echo 0)"
  [[ "$SPAWN_TOKENS" =~ ^[0-9]+$ ]] || SPAWN_TOKENS=0
  SPAWN_INPUT_TOKENS="$(jq -r '.usage.input_tokens // empty' \
    <<<"$SPAWN_RAW" 2>/dev/null || true)"
  SPAWN_CACHE_READ_TOKENS="$(jq -r '.usage.cache_read_input_tokens // empty' \
    <<<"$SPAWN_RAW" 2>/dev/null || true)"
  SPAWN_CACHE_WRITE_TOKENS="$(jq -r '.usage.cache_creation_input_tokens // empty' \
    <<<"$SPAWN_RAW" 2>/dev/null || true)"
  SPAWN_OUTPUT_TOKENS="$(jq -r '.usage.output_tokens // empty' \
    <<<"$SPAWN_RAW" 2>/dev/null || true)"
  SPAWN_REASONING_TOKENS="$(jq -r \
    '.usage.reasoning_output_tokens // .usage.reasoning_tokens // empty' \
    <<<"$SPAWN_RAW" 2>/dev/null || true)"
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
  local last_msg prompt_file
  last_msg="$(mktemp)"
  prompt_file="$(mktemp)"
  (umask 077; printf '%s' "$prompt" >"$prompt_file") || {
    rm -f "$last_msg" "$prompt_file"
    SPAWN_RC=1
    return 1
  }
  cmd+=(-o "$last_msg" --json -)

  # Feed the prompt through a private file instead of one argv element. Linux
  # limits each argument to roughly 128 KiB, while release diffs and research
  # prompts routinely exceed that. The explicit `-` tells Codex to read only
  # this dispatcher-owned stream, never caller stdin.
  local -a inv=()
  if [ -n "$timeout_val" ]; then inv+=(timeout "$timeout_val"); fi
  inv+=("${cmd[@]}")
  _run_harness "file:$prompt_file" "${inv[@]}" || true

  SPAWN_TEXT="$(cat "$last_msg" 2>/dev/null || true)"
  rm -f "$last_msg" "$prompt_file"
  SPAWN_TOKENS="$(jq -rs 'map(select(.type=="turn.completed")) | last
    | (.usage.input_tokens // 0) + (.usage.output_tokens // 0)' \
    <<<"$SPAWN_RAW" 2>/dev/null || echo 0)"
  [[ "$SPAWN_TOKENS" =~ ^[0-9]+$ ]] || SPAWN_TOKENS=0
  SPAWN_INPUT_TOKENS="$(jq -rs 'map(select(.type=="turn.completed")) | last
    | .usage.input_tokens // empty' <<<"$SPAWN_RAW" 2>/dev/null || true)"
  SPAWN_CACHE_READ_TOKENS="$(jq -rs 'map(select(.type=="turn.completed")) | last
    | .usage.cached_input_tokens // empty' <<<"$SPAWN_RAW" 2>/dev/null || true)"
  SPAWN_OUTPUT_TOKENS="$(jq -rs 'map(select(.type=="turn.completed")) | last
    | .usage.output_tokens // empty' <<<"$SPAWN_RAW" 2>/dev/null || true)"
  SPAWN_REASONING_TOKENS="$(jq -rs 'map(select(.type=="turn.completed")) | last
    | .usage.reasoning_output_tokens // empty' <<<"$SPAWN_RAW" 2>/dev/null || true)"
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
  local prompt_bytes
  prompt_bytes="$(_prompt_byte_count "$prompt")"
  if [ "$prompt_bytes" -gt "$_SPAWN_SAFE_ARG_PROMPT_BYTES" ]; then
    SPAWN_RC=2
    SPAWN_RAW=""
    SPAWN_TEXT=""
    SPAWN_TOKENS=0
    _SPAWN_STDERR="spawn_model: Hermes prompt exceeds safe argv limit (${prompt_bytes} > ${_SPAWN_SAFE_ARG_PROMPT_BYTES} bytes); scope or chunk the request"
    if [ "$logfile" != "/dev/null" ]; then
      printf '%s\n' "$_SPAWN_STDERR" >>"$logfile" 2>/dev/null || true
    fi
    SPAWN_TOKEN_SOURCE="hermes-session"
    return 0
  fi
  local cmd=(hermes chat -q "$prompt" -Q --pass-session-id)
  [ -n "$model" ]    && cmd+=(-m "$model")
  [ -n "$provider" ] && cmd+=(--provider "$provider")
  [ "$skip_perms" -eq 1 ] && cmd+=(--yolo --accept-hooks)

  local -a inv=()
  if [ -n "$timeout_val" ]; then inv+=(timeout "$timeout_val"); fi
  inv+=("${cmd[@]}")
  _run_harness "null" "${inv[@]}" || true
  SPAWN_TEXT="$SPAWN_RAW"
  # _run_harness already appended stderr (incl. the session_id line) to $logfile.

  local sid usage_json=""
  sid="$(printf '%s' "$_SPAWN_STDERR" \
    | grep -oE 'session_id:[[:space:]]*[A-Za-z0-9._-]+' 2>/dev/null \
    | tail -1 | grep -oE '[A-Za-z0-9._-]+$' || true)"
  SPAWN_TOKENS=0
  if [ -n "$sid" ]; then
    usage_json="$(hermes sessions export - --session-id "$sid" 2>/dev/null || true)"
    SPAWN_TOKENS="$(jq -r '(.input_tokens // 0) + (.output_tokens // 0)' \
      <<<"$usage_json" 2>/dev/null || echo 0)"
    [[ "$SPAWN_TOKENS" =~ ^[0-9]+$ ]] || SPAWN_TOKENS=0
    SPAWN_INPUT_TOKENS="$(jq -r '.input_tokens // empty' \
      <<<"$usage_json" 2>/dev/null || true)"
    SPAWN_OUTPUT_TOKENS="$(jq -r '.output_tokens // empty' \
      <<<"$usage_json" 2>/dev/null || true)"
  fi
  SPAWN_TOKEN_SOURCE="hermes-session"
}
