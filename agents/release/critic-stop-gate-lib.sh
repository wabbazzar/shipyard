# agents/release/critic-stop-gate-lib.sh — shared teeth for the shoulder-mode
# stop gate. Sourced by the per-harness front-ends:
#   critic-stop-gate.sh        (claude Stop hook)
#   critic-stop-gate-codex.sh  (codex  SessionEnd/Stop hook)
#   critic-stop-gate-hermes.sh (hermes on_session_end hook)
#
# DISARMED unless the session exports CRITIC_BLOCK=1 — the crew's own headless
# runs never set it, so they are never blocked. Armed, it reads the latest
# critique findings critic-watch.sh wrote beside the queue and, if any
# block-severity finding is unaddressed, returns 2 with them on stderr — the
# "don't stop yet" signal. Whether a given harness HONORS a stop-hook's exit 2
# is a harness capability verified live (see the ticket's P5); the gate's shape
# is identical across all three.

# csg_gate <session_id> <project_dir>
csg_gate() {
  [ "${CRITIC_BLOCK:-0}" = "1" ] || return 0
  local SESSION_ID="${1:-}" PROJECT_DIR="${2:-$PWD}" QUEUE_DIR FF BLOCKS
  [ -n "$SESSION_ID" ] || SESSION_ID="default"
  case "${CRITIC_QUEUE_NAMESPACE:-}" in
    claude|codex) SESSION_ID="${CRITIC_QUEUE_NAMESPACE}--$SESSION_ID" ;;
  esac
  if [ -d "$PROJECT_DIR/tmp" ]; then
    QUEUE_DIR="$PROJECT_DIR/tmp"
  else
    QUEUE_DIR="/tmp/shipyard-critic-$(id -u)/$(basename "$PROJECT_DIR")"
  fi
  FF="$QUEUE_DIR/critic-findings-$SESSION_ID"
  [ -f "$FF" ] || return 0
  BLOCKS="$(grep '^block|' "$FF" 2>/dev/null || true)"
  [ -n "$BLOCKS" ] || return 0
  {
    echo "release critic: unaddressed block-severity findings:"
    printf '%s\n' "$BLOCKS"
  } >&2
  return 2
}

csg_checked_sha256() {
  local result hash rest
  if command -v sha256sum >/dev/null 2>&1; then
    result="$(sha256sum)" || return 1
  elif command -v shasum >/dev/null 2>&1; then
    result="$(shasum -a 256)" || return 1
  else
    return 1
  fi
  hash="${result%%[[:space:]]*}"
  rest="${result#"$hash"}"
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] &&
    [[ "$rest" =~ ^[[:space:]]+(-|/dev/stdin)?[[:space:]]*$ ]] || return 1
  printf '%s\n' "$hash"
}

csg_hash_text() {
  printf '%s' "$1" | csg_checked_sha256
}

csg_mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

csg_uid_of() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null
}

csg_nlink_of() {
  stat -c '%h' "$1" 2>/dev/null || stat -f '%l' "$1" 2>/dev/null
}

csg_safe_state_file() {
  [ -f "$1" ] && [ ! -L "$1" ] &&
    [ "$(csg_uid_of "$1")" = "$(id -u)" ] &&
    [ "$(csg_mode_of "$1")" = "600" ] &&
    [ "$(csg_nlink_of "$1")" = "1" ]
}

csg_atomic_json() {
  local target="$1" json="$2" parent tmp
  parent="${target%/*}"
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  tmp="$parent/.${target##*/}.$$.$RANDOM"
  (umask 077; printf '%s\n' "$json" >"$tmp") || return 1
  chmod 600 "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  mv -f -- "$tmp" "$target" || {
    rm -f -- "$tmp"
    return 1
  }
}

# csg_drain_codex_feedback <project> <session>
# Claims, but does not emit, ready items through the Phase 1 mailbox API. The
# caller must use csg_emit_feedback so claims commit only after Stop JSON is
# written. EXIT rollback covers ordinary pre-emission failures; an untrappable
# crash replays through the mailbox's bounded stale-claim recovery.
csg_drain_codex_feedback() {
  local project="$1" session="$2" script out context token err claim_rc
  CSG_FEEDBACK_REASON=""
  CSG_DRAIN_FAILED=0
  CSG_CLAIM_PROJECT="$project"
  CSG_CLAIM_SESSION="$session"
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/critic-codex-feedback.sh"
  [ -x "$script" ] || {
    CSG_DRAIN_FAILED=1
    return 0
  }
  err="${CSG_QUEUE_DIR:-${TMPDIR:-/tmp}}/.critic-stop-drain.$$.$RANDOM"
  # One oldest immutable item per Stop response keeps the commit boundary
  # exact: no later item can be acknowledged after only a truncated prefix.
  while :; do
    : >"$err" || {
      CSG_DRAIN_FAILED=1
      break
    }
    out="$(bash "$script" --stop-claim "$project" "$session" 2>"$err")"
    claim_rc=$?
    if [ "$claim_rc" -eq 3 ] && [ ! -s "$err" ]; then
      rm -f -- "$err"
      break
    fi
    if [ "$claim_rc" -ne 0 ]; then
      CSG_DRAIN_FAILED=1
      rm -f -- "$err"
      break
    fi
    if [ -s "$err" ]; then
      CSG_DRAIN_FAILED=1
      rm -f -- "$err"
      break
    fi
    rm -f -- "$err"
    [ -n "$out" ] || break
    token="$(jq -er '
      select(type == "object" and .schema_version == 1
        and (.claim_token | type == "string"
          and test("^[0-9]{20}-[0-9a-f]{64}[.]json$"))
        and (.critique_id | type == "string"
          and test("^[0-9a-f]{64}$"))
        and (.summary | type == "string"))
      | .claim_token
    ' <<<"$out" 2>/dev/null)" || token=""
    context="$(jq -er '
      "Release critic [" + .critique_id + "]: " + .summary
    ' <<<"$out" 2>/dev/null)" || context=""
    if [ -z "$token" ] || [ -z "$context" ]; then
      CSG_DRAIN_FAILED=1
      break
    fi
    if [ -n "${CSG_CLAIM_TOKENS:-}" ]; then
      CSG_CLAIM_TOKENS="$CSG_CLAIM_TOKENS
$token"
    else
      CSG_CLAIM_TOKENS="$token"
    fi
    CSG_FEEDBACK_REASON="$context"
    break
  done
  rm -f -- "$err"
}

csg_rollback_claims() {
  local script token
  [ -n "${CSG_CLAIM_TOKENS:-}" ] || return 0
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/critic-codex-feedback.sh"
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    bash "$script" --stop-rollback "$CSG_CLAIM_PROJECT" \
      "$CSG_CLAIM_SESSION" "$token" >/dev/null 2>&1 || true
  done <<<"$CSG_CLAIM_TOKENS"
  CSG_CLAIM_TOKENS=""
}

csg_emit_feedback() {
  local reason="$1" script token
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/critic-codex-feedback.sh"
  if ! csg_stop_json "$reason"; then
    csg_rollback_claims
    return 1
  fi
  # A valid Stop response has now crossed stdout. A commit failure is
  # deliberately left as an ambiguous claim for stable-ID replay; rolling it
  # back eagerly would turn a post-emission bookkeeping fault into duplication.
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    bash "$script" --stop-commit "$CSG_CLAIM_PROJECT" \
      "$CSG_CLAIM_SESSION" "$token" >/dev/null 2>&1 || true
  done <<<"${CSG_CLAIM_TOKENS:-}"
  CSG_CLAIM_TOKENS=""
}

csg_stop_json() {
  jq -cn --arg reason "$1" '{decision:"block",reason:$reason}'
}

csg_read_required_feedback() {
  local project="$1" root cfg raw
  CSG_REQUIRE_FEEDBACK=false
  cfg="$project/.agents/config.toml"
  [ -f "$cfg" ] || return 0
  root="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
  # shellcheck source=agents/lib/load-config.sh
  . "$root/agents/lib/load-config.sh"
  CSG_CFG_JSON="$(load_config_json "$cfg")" || {
    echo "critic-stop-gate-codex: cannot parse $cfg" >&2
    return 2
  }
  raw="$(jq -cr '
    if (.memory | type) == "object" and .memory.mode == "required"
    then true
    elif (.shoulder | type) == "object" and
         (.shoulder | has("require_feedback"))
    then .shoulder.require_feedback
    else false
    end
  ' <<<"$CSG_CFG_JSON" 2>/dev/null)" || return 2
  case "$raw" in
    true|false) CSG_REQUIRE_FEEDBACK="$raw" ;;
    *)
      echo "critic-stop-gate-codex: shoulder.require_feedback must be boolean" >&2
      return 2 ;;
  esac
}

csg_poll_feedback() {
  local project="$1" session="$2" wait_sec="$3" poll_sec="$4"
  local started now
  started="$(date +%s)"
  while :; do
    csg_drain_codex_feedback "$project" "$session"
    [ -n "$CSG_FEEDBACK_REASON" ] && return 0
    now="$(date +%s)"
    [ $((now - started)) -lt "$wait_sec" ] || return 1
    sleep "$poll_sec"
  done
}

csg_status_kind() {
  local file="$1" session_hash="$2" turn_hash="$3" raw
  CSG_STATUS=""
  [ -e "$file" ] || {
    CSG_STATUS=watcher
    return 0
  }
  if ! csg_safe_state_file "$file"; then
    CSG_STATUS=delivery
    return 0
  fi
  raw="$(jq -er --arg sh "$session_hash" --arg th "$turn_hash" '
    select(type == "object" and .schema_version == 1
      and .session_hash == $sh and .turn_hash == $th
      and (.status | type == "string"))
    | .status
  ' "$file" 2>/dev/null)" || {
    CSG_STATUS=delivery
    return 0
  }
  case "$raw" in
    budget|spawn|delivery|malformed_response_exhausted|memory) CSG_STATUS="$raw" ;;
    running|deposited) CSG_STATUS=timeout ;;
    *) CSG_STATUS=delivery ;;
  esac
}

# csg_codex_stop <input-json>
# Codex Stop JSON is always exit 0 when asking for an automatic continuation.
# Exit 2 is reserved for invalid required-feedback configuration or the legacy
# CRITIC_BLOCK compatibility path.
csg_codex_stop() {
  local input="$1" project session session_key turn active last session_hash turn_hash
  local queue_dir queue flush status state phase state_reason wait_sec poll_sec
  local pending_reason terminal_reason state_json marker_json
  jq -e 'type == "object"' <<<"$input" >/dev/null 2>&1 || {
    echo "critic-stop-gate-codex: malformed Stop payload" >&2
    return 2
  }
  session="$(jq -r '.session_id // empty' <<<"$input")"
  turn="$(jq -r '.turn_id // "default"' <<<"$input")"
  project="$(jq -r '.cwd // empty' <<<"$input")"
  active="$(jq -er '
    if has("stop_hook_active") then
      if (.stop_hook_active | type) == "boolean"
      then (.stop_hook_active | tostring)
      else error("stop_hook_active must be boolean")
      end
    else "false"
    end
  ' <<<"$input" 2>/dev/null)" || {
    echo "critic-stop-gate-codex: stop_hook_active must be boolean" >&2
    return 2
  }
  last="$(jq -r '.last_assistant_message // empty' <<<"$input")"
  [ -n "$session" ] && [ "${#session}" -le 4096 ] &&
    [[ "$session" != */* ]] && [[ "$session" != *$'\n'* ]] || {
      echo "critic-stop-gate-codex: session_id is required and must not contain a path separator" >&2
      return 2
    }
  [ -n "$turn" ] && [ "${#turn}" -le 4096 ] &&
    [[ "$turn" != *$'\n'* ]] || {
      echo "critic-stop-gate-codex: turn_id is invalid" >&2
      return 2
    }
  project="$(cd "$project" 2>/dev/null && pwd -P)" || {
    echo "critic-stop-gate-codex: cwd must name an existing project" >&2
    return 2
  }
  csg_read_required_feedback "$project" || return $?
  session_key="$session"
  case "${CRITIC_QUEUE_NAMESPACE:-}" in
    claude|codex) session_key="${CRITIC_QUEUE_NAMESPACE}--$session" ;;
  esac

  if [ -d "$project/tmp" ]; then
    queue_dir="$project/tmp"
  else
    queue_dir="/tmp/shipyard-critic-$(id -u)/$(basename "$project")"
  fi
  CSG_QUEUE_DIR="$queue_dir"
  queue="$queue_dir/critic-queue-$session_key"
  session_hash="$(csg_hash_text "shipyard-session-v1:$session_key")" || return 2
  turn_hash="$(csg_hash_text "shipyard-turn-v1:$session_key:$turn")" || return 2
  flush="$queue_dir/critic-flush-$session_hash"
  status="$queue_dir/critic-status-$session_hash"
  state="$queue_dir/critic-stop-state-$session_hash-$turn_hash"

  csg_drain_codex_feedback "$project" "$session"
  if [ -n "$CSG_FEEDBACK_REASON" ]; then
    csg_emit_feedback "$CSG_FEEDBACK_REASON" || return 1
    rm -f -- "$state" "$flush" "$status"
    return 0
  fi

  if [ "$CSG_REQUIRE_FEEDBACK" != true ]; then
    csg_gate "$session" "$project"
    return $?
  fi
  if [ ! -s "$queue" ]; then
    rm -f -- "$state" "$flush" "$status"
    csg_gate "$session" "$project"
    return $?
  fi

  phase=""
  state_reason=""
  if [ -e "$state" ]; then
    if csg_safe_state_file "$state"; then
      phase="$(jq -er --arg sh "$session_hash" --arg th "$turn_hash" '
        select(type == "object" and .schema_version == 1
          and .session_hash == $sh and .turn_hash == $th
          and (.phase == "awaiting" or .phase == "terminal"))
        | .phase
      ' "$state" 2>/dev/null)" || phase=""
      state_reason="$(jq -er '.reason // empty' "$state" 2>/dev/null)" ||
        state_reason=""
    fi
    [ -n "$phase" ] || phase=malformed
  fi

  if [ "$phase" = terminal ]; then
    if [ -n "$state_reason" ] && [[ "$last" == *"$state_reason"* ]]; then
      rm -f -- "$state" "$flush" "$status"
      return 0
    fi
    csg_stop_json "$state_reason"
    return 0
  fi

  wait_sec="${CRITIC_STOP_WAIT_SEC:-20}"
  poll_sec="${CRITIC_STOP_POLL_SEC:-1}"
  [[ "$wait_sec" =~ ^[0-9]+$ ]] && [ "$wait_sec" -le 20 ] || wait_sec=20
  [[ "$poll_sec" =~ ^(0[.][0-9]+|[1-9][0-9]*([.][0-9]+)?)$ ]] ||
    poll_sec=1

  if [ -z "$phase" ] || [ "$phase" = malformed ]; then
    marker_json="$(jq -cn --arg sh "$session_hash" --arg th "$turn_hash" \
      --argjson created_at "$(date +%s)" '
      {schema_version:1,session_hash:$sh,turn_hash:$th,created_at:$created_at}
    ')" || return 2
    csg_atomic_json "$flush" "$marker_json" || {
      echo "critic-stop-gate-codex: cannot publish urgent critic flush" >&2
      return 2
    }
    state_json="$(jq -cn --arg sh "$session_hash" --arg th "$turn_hash" '
      {schema_version:1,session_hash:$sh,turn_hash:$th,phase:"awaiting",reason:""}
    ')" || return 2
    csg_atomic_json "$state" "$state_json" || return 2
    if csg_poll_feedback "$project" "$session" "$wait_sec" "$poll_sec"; then
      csg_emit_feedback "$CSG_FEEDBACK_REASON" || return 1
      rm -f -- "$state" "$flush" "$status"
      return 0
    fi
    pending_reason="The release review is pending; wait for the urgent flush and make no completion claim."
    csg_stop_json "$pending_reason"
    return 0
  fi

  # The automatic continuation sets stop_hook_active=true. The persisted
  # awaiting phase is authoritative if another hook omitted that advisory bit.
  if csg_poll_feedback "$project" "$session" "$wait_sec" "$poll_sec"; then
    csg_emit_feedback "$CSG_FEEDBACK_REASON" || return 1
    rm -f -- "$state" "$flush" "$status"
    return 0
  fi
  if [ ! -s "$queue" ]; then
    rm -f -- "$state" "$flush" "$status"
    csg_gate "$session" "$project"
    return $?
  fi
  csg_status_kind "$status" "$session_hash" "$turn_hash"
  terminal_reason="Release critic unavailable ($CSG_STATUS); stop all implementation and report this hard blocker to the user."
  state_json="$(jq -cn --arg sh "$session_hash" --arg th "$turn_hash" \
    --arg reason "$terminal_reason" '
    {schema_version:1,session_hash:$sh,turn_hash:$th,phase:"terminal",reason:$reason}
  ')" || return 2
  csg_atomic_json "$state" "$state_json" || return 2
  csg_stop_json "$terminal_reason"
}
