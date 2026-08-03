#!/bin/bash
# agents/release/critic-watch.sh — debounced spawner for the shoulder-mode
# critic. Watches the per-session queue that critic-queue.sh (PostToolUse
# hook) appends to, and when a session goes quiet — or piles up enough
# edits — runs ONE cold-context critique over the whole batch.
#
# Usage:
#   critic-watch.sh --project <dir> [--session <id>] [--once]
#
#   --once     one evaluation pass over the queue(s), then exit (tests, cron)
#   (default)  poll loop, every $CRITIC_POLL_SEC seconds
#
# Trigger: (queue idle >= CRITIC_IDLE_SEC AND non-empty)
#          OR (>= CRITIC_BATCH_FILES distinct files queued).
# Env knobs (test overrides): CRITIC_IDLE_SEC (300), CRITIC_BATCH_FILES (8),
# CRITIC_POLL_SEC (30), CRITIC_MODEL (claude default model if unset).
#
# Budget: sums today's release.critique `tokens` from the events dir
# (QUARTET_EVENTS_DIR or <project>/data/events) against
# [release] budget_tokens_daily (default 1000000). At/over cap the
# critique is skipped with a release.critique.skipped reason=budget event.
#
# Delivery: findings go to the dev session via $CLAUDE_NOTE_CMD
# (a claude-note-style command taking <session> <message>; the hub's
# installer sets it — unset means log-and-skip, never a hardcoded path,
# because this repo is public). claude-note exit 2 (ambiguous target) or
# 3 (session at a prompt) leaves the queue intact for retry; any other
# outcome clears it.
#
# The critic NEVER writes code to the project and NEVER blocks the dev
# agent — this process is fully out-of-band.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUARTET_DIR="${QUARTET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
LOG_EVENT="$QUARTET_DIR/agents/lib/log_event.sh"
ROLE_FILE="$SCRIPT_DIR/critic-role.md"

export QUARTET_SOURCE="${QUARTET_SOURCE:-shoulder}"

IDLE_SEC="${CRITIC_IDLE_SEC:-300}"
BATCH_FILES="${CRITIC_BATCH_FILES:-8}"
POLL_SEC="${CRITIC_POLL_SEC:-30}"

# ---------- argv ------------------------------------------------------------
PROJECT_DIR=""
SESSION=""
ONCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT_DIR="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --once)    ONCE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *)         echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -z "$PROJECT_DIR" ] && { echo "--project required" >&2; exit 2; }
[ -d "$PROJECT_DIR" ] || { echo "project dir missing: $PROJECT_DIR" >&2; exit 2; }
[ -f "$ROLE_FILE" ]   || { echo "critic-role.md not found: $ROLE_FILE" >&2; exit 2; }

# ---------- config (optional — critic works on bare repos too) --------------
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/load-config.sh"
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/spawn.sh"
# shellcheck source=agents/release/critic-queue-lib.sh
source "$SCRIPT_DIR/critic-queue-lib.sh"
CFG_JSON="{}"
if [ -f "$PROJECT_DIR/.agents/config.toml" ]; then
  if parsed_cfg="$(load_config_json "$PROJECT_DIR/.agents/config.toml")"; then
    CFG_JSON="$parsed_cfg"
  else
    config_rc=$?
    if [ "$config_rc" -eq 2 ]; then
      echo "critic-watch: failed to validate project config" >&2
      exit 2
    fi
    # Preserve shoulder mode's legacy tolerance of generally malformed TOML.
    CFG_JSON="{}"
  fi
fi
outcome_lineage_configure "$CFG_JSON" || exit 2
PROJECT_NAME="$(jq -r '.project_name // empty' <<<"$CFG_JSON")"
[ -n "$PROJECT_NAME" ] || PROJECT_NAME="$(basename "$PROJECT_DIR")"
BUDGET_TOKENS="$(jq -r '.release.budget_tokens_daily // 1000000' <<<"$CFG_JSON")"
# When true, annotate any CHANGED FILES entry that has NO diff hunk with a
# "(no hunks)" marker, so a project-authored file-conditional critic check can
# key on real +/- hunks instead of mere list membership (the changed-file list
# is a superset of the files that actually have hunks — a hook-queued but
# reverted tracked file lands in the list with no delta). Default false ⇒ the
# CHANGED FILES block is byte-identical to before.
HUNK_SAFE="$(jq -r '.release.hunk_safe_gates // false' <<<"$CFG_JSON")"
REQUIRE_FEEDBACK="$(jq -cr '
  if (.shoulder | type) == "object" and
     (.shoulder | has("require_feedback"))
  then .shoulder.require_feedback
  else false
  end
' <<<"$CFG_JSON" 2>/dev/null || echo invalid)"
case "$REQUIRE_FEEDBACK" in
  true|false) ;;
  *)
    echo "critic-watch: shoulder.require_feedback must be boolean" >&2
    exit 2 ;;
esac

# The shoulder-mode critic IS the release role's out-of-band voice: svc is
# "<project>-<display>" (role id when no [names]) and the critique event
# carries role:release.
ROLE="release"
export QUARTET_ROLE="$ROLE"
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/naming.sh"
SVC="$PROJECT_NAME-$(role_display "$ROLE" "$CFG_JSON")"

EVENTS_DIR="${QUARTET_EVENTS_DIR:-$PROJECT_DIR/data/events}"

log() { echo "[$SVC-critic] $*"; }

checked_sha256() {
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

session_hash() {
  printf 'shipyard-session-v1:%s' "$1" | checked_sha256
}

safe_private_file() {
  local path="$1" mode owner links
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  mode="$(stat -c '%a' "$path" 2>/dev/null ||
    stat -f '%Lp' "$path" 2>/dev/null || true)"
  owner="$(stat -c '%u' "$path" 2>/dev/null ||
    stat -f '%u' "$path" 2>/dev/null || true)"
  links="$(stat -c '%h' "$path" 2>/dev/null ||
    stat -f '%l' "$path" 2>/dev/null || true)"
  [ "$mode" = "600" ] && [ "$owner" = "$(id -u)" ] && [ "$links" = "1" ]
}

urgent_marker() {
  printf '%s/critic-flush-%s\n' "$QUEUE_DIR" "$(session_hash "$1")"
}

urgent_turn_hash() {
  local session="$1" marker hash
  marker="$(urgent_marker "$session")" || return 1
  hash="$(session_hash "$session")" || return 1
  safe_private_file "$marker" || return 1
  jq -er --arg hash "$hash" '
    select(type == "object" and .schema_version == 1
      and .session_hash == $hash
      and (.turn_hash | type == "string"
        and test("^[0-9a-f]{64}$")))
    | .turn_hash
  ' "$marker" 2>/dev/null
}

write_required_status() {
  local session="$1" status="$2" session_key turn_key target tmp json
  [ "$REQUIRE_FEEDBACK" = true ] || return 0
  turn_key="$(urgent_turn_hash "$session")" || return 0
  session_key="$(session_hash "$session")" || return 0
  target="$QUEUE_DIR/critic-status-$session_key"
  tmp="$(umask 077; mktemp \
    "$QUEUE_DIR/.critic-status-$session_key.XXXXXX")" || return 1
  json="$(jq -cn --arg sh "$session_key" --arg th "$turn_key" \
    --arg status "$status" --argjson updated_at "$(date +%s)" '
    {schema_version:1,session_hash:$sh,turn_hash:$th,status:$status,
      updated_at:$updated_at}
  ')" || return 1
  (umask 077; printf '%s\n' "$json" >"$tmp") || {
    rm -f -- "$tmp"
    return 1
  }
  chmod 600 "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  mv -f -- "$tmp" "$target" || {
    rm -f -- "$tmp"
    return 1
  }
}

urgent_requested() {
  [ "$REQUIRE_FEEDBACK" = true ] && urgent_turn_hash "$1" >/dev/null
}

# Retry exhaustion is bound to immutable reviewed work plus the urgent Stop
# turn. A continuously polling watcher must not restart a failed three-attempt
# cycle forever, but a new edit snapshot or a later Codex turn must be allowed
# to test a repaired harness/delivery path.
retry_generation() {
  local kind="$1" session="$2" work_id="$3" turn_id
  turn_id="$(urgent_turn_hash "$session" 2>/dev/null || true)"
  printf 'shipyard-critic-retry-v1\0%s\0%s\0%s' \
    "$kind" "$work_id" "$turn_id" | checked_sha256
}

retry_state_count() {
  local state_file="$1" generation="$2" raw count stored_generation
  [ -f "$state_file" ] || {
    printf '0\n'
    return 0
  }
  raw="$(cat "$state_file" 2>/dev/null || true)"
  count="$(jq -er '.attempts | select(type == "number" and . >= 0)
    | floor' <<<"$raw" 2>/dev/null || true)"
  stored_generation="$(jq -er '.generation
    | select(type == "string")' <<<"$raw" 2>/dev/null || true)"
  if [[ "$count" =~ ^[0-9]+$ ]] && [ "$stored_generation" = "$generation" ]; then
    printf '%s\n' "$count"
  elif [[ "$raw" =~ ^[0-9]+$ ]]; then
    # Backward compatibility for an in-flight pre-upgrade retry counter.
    printf '%s\n' "$raw"
  else
    printf '0\n'
  fi
}

write_retry_state() {
  local state_file="$1" attempts="$2" generation="$3" tmp
  tmp="$(umask 077; mktemp "${state_file}.tmp.XXXXXX")" || return 1
  if ! jq -cn --argjson attempts "$attempts" --arg generation "$generation" \
      '{schema_version:1,attempts:$attempts,generation:$generation}' >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 600 "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  mv -f -- "$tmp" "$state_file"
}

emit_event() {
  # emit_event <event> [key=value ...]
  [ -x "$LOG_EVENT" ] || return 0
  QUARTET_EVENTS_DIR="$EVENTS_DIR" "$LOG_EVENT" "$SVC" "$@" || true
}

# ---------- queue location (must mirror critic-queue.sh) --------------------
if [ -d "$PROJECT_DIR/tmp" ]; then
  QUEUE_DIR="$PROJECT_DIR/tmp"
else
  QUEUE_DIR="/tmp/shipyard-critic-$(id -u)/$(basename "$PROJECT_DIR")"
fi

# ---------- budget ----------------------------------------------------------
tokens_used_today() {
  local f
  f="$EVENTS_DIR/$(date -u +%Y-%m-%d).jsonl"
  [ -f "$f" ] || { echo 0; return; }
  jq -R 'fromjson?' <"$f" 2>/dev/null | \
    jq -s '[.[] | select(.event=="release.critique") | (.tokens // 0)] | add // 0' \
    2>/dev/null || echo 0
}

# ---------- queue consumption -----------------------------------------------
# Remove only the exact byte prefix captured in the pre-critique snapshot.
# Capture writers and acknowledgement share the queue lock, so even a late line
# byte-identical to a reviewed line remains distinguishable by its position.
consume_queue() {
  local queue="$1" session="$2"
  local snap="$QUEUE_DIR/critic-snapshot-$session"
  if [ -f "$snap" ]; then
    if cq_consume_snapshot_prefix "$queue" "$snap"; then
      rm -f "$snap"
      if [ -s "$queue" ]; then
        log "queue kept: $(awk 'END {print NR}' "$queue") entr(ies) arrived during critique"
      fi
    else
      log "queue acknowledgement deferred: reviewed prefix changed; queue and snapshot kept"
      return 1
    fi
  else
    log "queue acknowledgement deferred: reviewed snapshot missing; queue kept"
    return 1
  fi
  return 0
}

# ---------- delivery (separate so retries can reuse a cached critique) ------
critique_delivery_summary() {
  local findings_file="$1" n_files="$2" findings n_block n_warn n_note summary
  findings="$(cat "$findings_file" 2>/dev/null || true)"
  n_block="$(grep -c '^block|' <<<"$findings" || true)"
  n_warn="$(grep -c '^warn|' <<<"$findings" || true)"
  n_note="$(grep -c '^note|' <<<"$findings" || true)"
  summary="$(role_display "$ROLE" "$CFG_JSON") critic: $n_block block, $n_warn warn, $n_note note across $n_files files"
  if [ -n "$findings" ]; then
    summary="$summary
$(grep -E '^(block|warn)\|' <<<"$findings" | head -10)"
  fi
  printf '%s\n' "$summary"
}

critique_identity() {
  local reviewed_snapshot="$1" findings_file="$2" summary="$3"
  {
    printf 'shipyard-codex-feedback-v1\0'
    cat "$reviewed_snapshot" 2>/dev/null || true
    printf '\0'
    cat "$findings_file" 2>/dev/null || true
    printf '\0%s' "$summary"
  } | checked_sha256
}

emit_delivery_disposition() {
  local critique_id="$1" disposition="$2"
  outcome_lineage_enabled || return 0
  case "$disposition" in deposited|deferred|failed|expired) ;; *) return 2 ;; esac
  emit_event release.critique.delivery source=shoulder \
    critique_id="$critique_id" disposition="$disposition"
}

deliver_findings() {
  local queue="$1" session="$2" findings_file="$3" n_files="$4"
  local supplied_id="${5:-}"
  local findings n_block n_warn n_note
  DELIVERY_STATUS=delivery
  findings="$(cat "$findings_file" 2>/dev/null || true)"
  n_block="$(grep -c '^block|' <<<"$findings" || true)"
  n_warn="$(grep -c '^warn|' <<<"$findings" || true)"
  n_note="$(grep -c '^note|' <<<"$findings" || true)"

  if [ -z "${CLAUDE_NOTE_CMD:-}" ]; then
    if [ "${CRITIC_NOTE_HARNESS:-claude}" = "codex" ]; then
      log "CLAUDE_NOTE_CMD unset for Codex; queue kept for retry"
      [ -z "$supplied_id" ] || emit_delivery_disposition "$supplied_id" deferred
      write_required_status "$session" delivery || true
      return 0
    fi
    log "CLAUDE_NOTE_CMD unset; skipping delivery"
    consume_queue "$queue" "$session"
    [ -z "$supplied_id" ] || emit_delivery_disposition "$supplied_id" expired
    return 0
  fi

  local summary
  summary="$(critique_delivery_summary "$findings_file" "$n_files")"

  # Stable across retries: bind the immutable feedback item to the exact
  # reviewed queue snapshot, complete findings, and deposited summary.
  # The note command's two-argument argv contract is unchanged; external
  # injectors may ignore these scoped environment values.
  local note_rc note_id reviewed_snapshot attempts_file delivery_generation
  local live_queue_id
  reviewed_snapshot="$QUEUE_DIR/critic-snapshot-$session"
  [ -f "$reviewed_snapshot" ] || reviewed_snapshot="$queue"
  note_id="$supplied_id"
  if [ -z "$note_id" ]; then
    note_id="$(critique_identity "$reviewed_snapshot" "$findings_file" "$summary")" || {
      log "feedback ID hashing failed; queue kept for retry"
      return 0
    }
  fi
  if ! [[ "$note_id" =~ ^[0-9a-f]{64}$ ]]; then
    log "feedback ID hashing failed; queue kept for retry"
    return 0
  fi
  attempts_file="$QUEUE_DIR/critic-attempts-$session"
  live_queue_id="$(checked_sha256 <"$queue")" || {
    log "live queue hashing failed; queue kept for retry"
    return 0
  }
  delivery_generation="$(
    retry_generation delivery "$session" "$note_id:$live_queue_id"
  )" || {
    log "delivery retry generation failed; queue kept for retry"
    return 0
  }
  local prior_attempts
  prior_attempts="$(retry_state_count "$attempts_file" "$delivery_generation")"
  if [ "$REQUIRE_FEEDBACK" = true ] && [ "$prior_attempts" -ge 3 ]; then
    write_required_status "$session" delivery || true
    return 0
  fi
  # shellcheck disable=SC2086 — word-splitting CLAUDE_NOTE_CMD is intentional
  CRITIC_NOTE_ID="$note_id" CRITIC_PROJECT_DIR="$PROJECT_DIR" \
    $CLAUDE_NOTE_CMD "$session" "$summary"
  note_rc=$?
  case "$note_rc" in
    0)
      # Codex zero proves durable mailbox deposit only. Hook emission and model
      # consumption are later states; edit-queue acknowledgement is safe now.
      rm -f "$attempts_file"
      if consume_queue "$queue" "$session"; then
        DELIVERY_STATUS=deposited
        emit_delivery_disposition "$note_id" deposited
        write_required_status "$session" deposited || true
      else
        emit_delivery_disposition "$note_id" deferred
        write_required_status "$session" delivery || true
      fi ;;
    2|3)
      # 2 = ambiguous target, 3 = session at an interactive prompt — the
      # note was NOT delivered but the condition is session-state that a
      # later pass can find cleared. Keep the queue; no attempt cap.
      log "claude-note exit $note_rc; queue kept for retry"
      emit_delivery_disposition "$note_id" deferred
      write_required_status "$session" delivery || true ;;
    75)
      # Built-in Codex mailbox deposit failed before its atomic rename.
      # Never acknowledge the reviewed queue until durable persistence exists.
      log "critic-note deposit unavailable; queue kept for retry"
      emit_delivery_disposition "$note_id" deferred
      write_required_status "$session" delivery || true ;;
    *)
      # Any other nonzero (1 crash, 127 command-not-found, ...) means the
      # note command itself is broken — the finding was NOT delivered, so
      # dropping the queue here would silently lose it. Retry up to 3
      # passes, then give up LOUDLY: the findings file stays on disk for
      # the stop gate / manual reading, and a delivery_failed event fires.
      local attempts
      attempts="$(retry_state_count "$attempts_file" "$delivery_generation")"
      attempts=$((attempts + 1))
      if [ "$attempts" -ge 3 ]; then
        log "claude-note exit $note_rc after $attempts attempts; giving up — findings kept at $findings_file"
        local failed_lineage=()
        outcome_lineage_enabled && failed_lineage+=("critique_id=$note_id")
        emit_event release.critique.delivery_failed source=shoulder \
          rc="$note_rc" attempts="$attempts" "${failed_lineage[@]}"
        emit_delivery_disposition "$note_id" failed
        if [ "$REQUIRE_FEEDBACK" = true ]; then
          write_retry_state "$attempts_file" "$attempts" \
            "$delivery_generation" || true
          log "required feedback: reviewed queue preserved after delivery failure"
        else
          rm -f "$attempts_file"
          consume_queue "$queue" "$session"
        fi
      else
        write_retry_state "$attempts_file" "$attempts" \
          "$delivery_generation" || true
        emit_delivery_disposition "$note_id" deferred
        log "claude-note exit $note_rc; queue kept for retry ($attempts/3)"
      fi
      write_required_status "$session" delivery || true ;;
  esac
  return 0
}

# _annotate_no_hunk <changed-list> <diff> — echo the changed list with a
# "(no hunks)" suffix on any path that has NO diff header in <diff>. A path
# "has a hunk" iff a `diff --git`/`+++`/`---` header line mentions it (this
# covers tracked modifications AND the --no-index synth used for untracked
# queued files, whose header carries the absolute path ending in the relative
# one). Used only when [release].hunk_safe_gates=true.
_annotate_no_hunk() {
  local list="$1" d="$2" f headers
  headers="$(printf '%s\n' "$d" | grep -E '^(diff --git |\+\+\+ |--- )' || true)"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if printf '%s\n' "$headers" | grep -qF -- "$f"; then
      printf '%s\n' "$f"
    else
      printf '%s (no hunks)\n' "$f"
    fi
  done <<<"$list"
}

# Keep the release prompt portable across every selectable critic harness.
# Claude and Codex can stream large prompts, but Hermes currently exposes only
# an argv query flag. Each section carries an explicit omission notice so the
# critic can use read-only repo tools for any content beyond the inline budget.
_bounded_prompt_section() {
  local value="$1" max_bytes="$2" label="$3" bytes omitted
  bytes="$(LC_ALL=C printf '%s' "$value" | wc -c | tr -d ' ')"
  if [ "$bytes" -le "$max_bytes" ]; then
    printf '%s' "$value"
    return 0
  fi
  omitted=$((bytes - max_bytes))
  LC_ALL=C printf '%s' "$value" |
    python3 -c 'import sys
n = int(sys.argv[1])
data = sys.stdin.buffer.read()[:n]
sys.stdout.buffer.write(data.decode("utf-8", "ignore").encode("utf-8"))' \
      "$max_bytes"
  printf '\n\n[SHIPYARD: %s omitted %s trailing bytes to keep this review cross-harness safe. Use read-only repository tools to inspect omitted queued work before final findings.]' \
    "$label" "$omitted"
}

# ---------- one critique over a queue file ----------------------------------
critique_queue() {
  local queue="$1" session="$2"
  local findings_file="$QUEUE_DIR/critic-findings-$session"
  local findings_files_count="$QUEUE_DIR/critic-findings-files-$session"
  local retry_snapshot="$QUEUE_DIR/critic-snapshot-$session"

  # Delivery-retry guard: when a critique already ran for this exact queue
  # snapshot, reuse it instead of re-spending the model. Late live-queue
  # appends do not change the already-reviewed snapshot or its delivery ID.
  if [ -s "$findings_file" ] && [ -s "$retry_snapshot" ] &&
      [ "$findings_file" -nt "$retry_snapshot" ]; then
    local cached_n
    cached_n="$(cat "$findings_files_count" 2>/dev/null || true)"
    if ! [[ "$cached_n" =~ ^[0-9]+$ ]]; then
      cached_n="$(awk '{print $1}' "$retry_snapshot" 2>/dev/null |
        sort -u | grep -c . || true)"
    fi
    log "reusing cached critique for session $session (delivery retry)"
    deliver_findings "$queue" "$session" "$findings_file" "$cached_n"
    return 0
  fi

  # Budget gate — before any model spend.
  local used
  used="$(tokens_used_today)"
  [[ "$used" =~ ^[0-9]+$ ]] || used=0
  [[ "$BUDGET_TOKENS" =~ ^[0-9]+$ ]] || BUDGET_TOKENS=1000000
  if [ "$used" -ge "$BUDGET_TOKENS" ]; then
    # Defer, don't discard: the queue survives so the review happens in the
    # next budget window instead of being silently lost. The skip event and
    # log line fire once per session per UTC day — the gate itself is hit on
    # every poll pass while the budget stays blown.
    local day marker
    day="$(date -u +%Y%m%d)"
    marker="$QUEUE_DIR/critic-budget-skip-$session-$day"
    if [ ! -e "$marker" ]; then
      log "skip: daily token budget reached ($used >= $BUDGET_TOKENS); queue deferred"
      emit_event release.critique.skipped source=shoulder reason=budget \
        tokens_used="$used" budget="$BUDGET_TOKENS"
      : >"$marker" 2>/dev/null || true
    fi
    write_required_status "$session" budget || true
    return 0
  fi
  rm -f "$QUEUE_DIR/critic-budget-skip-$session-"* 2>/dev/null || true

  # Snapshot the queue state under the same lock capture hooks use. Delivery
  # consumes exactly this byte prefix; later appends remain queued.
  local reviewed_queue="$QUEUE_DIR/critic-snapshot-$session"
  if ! cq_snapshot_queue "$queue" "$reviewed_queue"; then
    log "snapshot unavailable; queue kept for retry"
    return 0
  fi
  local spawn_attempts_file snapshot_id spawn_generation prior_spawn_attempts
  spawn_attempts_file="$QUEUE_DIR/critic-spawn-attempts-$session"
  snapshot_id="$(checked_sha256 <"$reviewed_queue")" || {
    log "snapshot hashing failed; queue kept for retry"
    return 0
  }
  spawn_generation="$(retry_generation spawn "$session" "$snapshot_id")" || {
    log "spawn retry generation failed; queue kept for retry"
    return 0
  }
  prior_spawn_attempts="$(
    retry_state_count "$spawn_attempts_file" "$spawn_generation"
  )"
  if [ "$REQUIRE_FEEDBACK" = true ] && [ "$prior_spawn_attempts" -ge 3 ]; then
    write_required_status "$session" spawn || true
    return 0
  fi

  # ---- gather the diff for the exact queued edit batch ----------------------
  local trunk="" diff="" changed=""
  # shellcheck disable=SC1091
  source "$QUARTET_DIR/agents/lib/detect-trunk.sh"
  trunk="$(detect_trunk "$CFG_JSON" "$PROJECT_DIR" 2>/dev/null)" || trunk=""
  if [ -z "$trunk" ] ||
     ! git -C "$PROJECT_DIR" rev-parse -q --verify "$trunk" >/dev/null 2>&1; then
    trunk=HEAD
  fi
  # The queue is the review boundary. Pulling every historical branch hunk into
  # each edit batch made long-lived branches exceed both execve and model input
  # limits, and caused unrelated older work to contaminate current feedback.
  # A queued tracked path still gets its complete branch-vs-trunk hunk.
  local queued_files qf abs rel patch
  queued_files="$(awk '{print $1}' "$reviewed_queue" 2>/dev/null | sort -u | \
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      # Absolute paths outside this project were queued by older hooks or a
      # cross-repo session — reviewing them here applies the wrong project's
      # conventions and trunk. Their own project's watcher covers them.
      if [ "${f#/}" != "$f" ] && [ "${f#"$PROJECT_DIR"/}" = "$f" ]; then
        continue
      fi
      if [ "${f#"$PROJECT_DIR"/}" != "$f" ]; then
        f="${f#"$PROJECT_DIR"/}"
      fi
      git -C "$PROJECT_DIR" --literal-pathspecs check-ignore -q -- "$f" \
        2>/dev/null ||
        printf '%s\n' "$f"
    done)"
  changed="$queued_files"
  local n_files
  n_files="$(printf '%s\n' "$changed" | grep -c . || true)"

  # Tracked paths get their complete branch-vs-trunk hunk. Untracked queued
  # paths use --no-index so a brand-new file is equally reviewable.
  while IFS= read -r qf; do
    [ -n "$qf" ] || continue
    rel="$qf"
    if [ "${qf#/}" != "$qf" ]; then
      if [ "${qf#"$PROJECT_DIR"/}" = "$qf" ]; then
        continue
      fi
      rel="${qf#"$PROJECT_DIR"/}"
    fi
    abs="$PROJECT_DIR/$rel"
    patch="$(git -C "$PROJECT_DIR" --literal-pathspecs diff "$trunk" -- \
      "$rel" 2>/dev/null || true)"
    if [ -z "$patch" ] && [ -f "$abs" ] &&
       git -C "$PROJECT_DIR" --literal-pathspecs ls-files \
         --others --exclude-standard -- "$rel" 2>/dev/null |
         grep -Fxq -- "$rel"; then
      patch="$(git -C "$PROJECT_DIR" --literal-pathspecs diff --no-index -- \
        /dev/null "$abs" 2>/dev/null || true)"
    fi
    [ -n "$patch" ] || continue
    diff="${diff}${diff:+
}${patch}"
  done <<<"$queued_files"

  # No diff hunks -> nothing the rubric can grade. Spawning the critic anyway
  # yields only "diff body was empty" notes (observed 4x on shredly,
  # 2026-07-22): tokens spent, owner pinged, zero signal. Drop the queue and
  # skip. Note this also skips edits that were committed AND pushed to trunk
  # before the idle window fired — those are post-release, and the shoulder
  # critic's contract is pre-release review of pending work.
  if [ -z "$(printf '%s' "$diff" | tr -d '[:space:]')" ]; then
    log "skip: empty diff (changed files: ${n_files:-0}); reviewed entries dropped"
    emit_event release.critique.skipped source=shoulder reason=empty_diff \
      files="${n_files:-0}"
    consume_queue "$queue" "$session"
    return 0
  fi

  # ---- project extension (conventions layer) --------------------------------
  local project_ext="" ext_file="$PROJECT_DIR/.agents/release.md"
  local full_diff="$diff"
  [ -f "$ext_file" ] && project_ext="$(cat "$ext_file")"
  project_ext="$(_bounded_prompt_section "$project_ext" 16000 \
    "PROJECT EXTENSION")"

  # CHANGED FILES block: byte-identical to $changed unless hunk_safe_gates is on,
  # in which case no-hunk entries are marked so a file-conditional check can key
  # on real hunks (see critic-role.md "Input contract").
  local changed_block="$changed"
  [ "$HUNK_SAFE" = "true" ] &&
    changed_block="$(_annotate_no_hunk "$changed" "$full_diff")"
  changed_block="$(_bounded_prompt_section "$changed_block" 12000 \
    "CHANGED FILES")"
  diff="$(_bounded_prompt_section "$full_diff" 60000 "DIFF")"

  local prompt
  prompt="$(cat "$ROLE_FILE")

---

PROJECT EXTENSION (.agents/release.md):

$project_ext

---

CHANGED FILES:

$changed_block

---

DIFF:

$diff"

  # ---- spawn the critic -----------------------------------------------------
  # Unset CRITIC_MODEL => no --model (harness default); unset CRITIC_HARNESS =>
  # claude. spawn_model omits --model when empty, matching the historical
  # conditional model_args exactly.
  local claude_out claude_rc
  spawn_model --harness "${CRITIC_HARNESS:-claude}" --model "${CRITIC_MODEL:-}" \
    --provider "${CRITIC_PROVIDER:-}" --prompt "$prompt" --log /dev/null --json
  claude_out="$SPAWN_RAW"; claude_rc="$SPAWN_RC"
  if [ "$claude_rc" -ne 0 ] || [ -z "$claude_out" ]; then
    # Same 3-strike rule as delivery: a persistent spawn failure (bad
    # CRITIC_MODEL, oversized prompt, missing binary) must not retry every
    # poll pass forever. Give up loudly with an event so the failure is
    # visible instead of an infinite silent loop.
    local sa err_line
    sa="$(retry_state_count "$spawn_attempts_file" "$spawn_generation")"
    sa=$((sa + 1))
    # The dispatcher already captures the final harness stderr. Preserve one
    # bounded, single-line diagnostic: an exit code alone cannot distinguish a
    # missing binary, EACCES, bad model, or an oversized prompt after the run.
    err_line="$(printf '%s' "${_SPAWN_STDERR:-}" | tr '\r\n' '  ' | cut -c1-300)"
    if [ "$sa" -ge 3 ]; then
      log "critic claude run failed (exit=$claude_rc) after $sa attempts; giving up on reviewed entries: $err_line"
      emit_event release.critique.spawn_failed source=shoulder \
        rc="$claude_rc" attempts="$sa" files="$n_files" stderr="$err_line"
      if [ "$REQUIRE_FEEDBACK" = true ]; then
        write_retry_state "$spawn_attempts_file" "$sa" \
          "$spawn_generation" || true
        log "required feedback: reviewed queue preserved after spawn failure"
        write_required_status "$session" spawn || true
      else
        rm -f "$spawn_attempts_file"
        consume_queue "$queue" "$session"
      fi
    else
      write_retry_state "$spawn_attempts_file" "$sa" \
        "$spawn_generation" || true
      log "critic claude run failed (exit=$claude_rc); queue kept for retry ($sa/3): $err_line"
    fi
    return 0
  fi
  rm -f "$spawn_attempts_file"

  # ---- parse findings + real token usage ------------------------------------
  # `claude -p --output-format json` emits one JSON object with the reply
  # in .result and token usage in .usage.{input_tokens,output_tokens}.
  local result_text tokens
  result_text="$SPAWN_TEXT"
  tokens="$SPAWN_TOKENS"

  local findings n_block n_warn n_note
  findings="$(grep -E '^(block|warn|note)\|' <<<"$result_text" || true)"
  n_block="$(grep -c '^block|' <<<"$findings" || true)"
  n_warn="$(grep -c '^warn|' <<<"$findings" || true)"
  n_note="$(grep -c '^note|' <<<"$findings" || true)"

  printf '%s\n' "$findings" >"$findings_file"
  printf '%s\n' "$n_files" >"$findings_files_count"

  local critique_id="" critique_lineage=() summary
  if outcome_lineage_enabled; then
    summary="$(critique_delivery_summary "$findings_file" "$n_files")"
    critique_id="$(critique_identity "$reviewed_queue" "$findings_file" "$summary")" || {
      log "feedback ID hashing failed; queue kept for retry"
      return 0
    }
    outcome_lineage_token_fields
    critique_lineage=("critique_id=$critique_id" "${OUTCOME_TOKEN_FIELDS[@]}")
  fi
  emit_event release.critique source=shoulder files="$n_files" \
    block="$n_block" warn="$n_warn" note="$n_note" tokens="$tokens" \
    "${critique_lineage[@]}"
  log "critique: $n_block block, $n_warn warn, $n_note note across $n_files files (tokens=$tokens)"

  # ---- deliver to the dev session -------------------------------------------
  deliver_findings "$queue" "$session" "$findings_file" "$n_files" "$critique_id"
  return 0
}

# ---------- evaluation pass -------------------------------------------------
eval_pass() {
  local queues=()
  if [ -n "$SESSION" ]; then
    queues=("$QUEUE_DIR/critic-queue-$SESSION")
  else
    local q
    for q in "$QUEUE_DIR"/critic-queue-*; do
      [ -e "$q" ] && queues+=("$q")
    done
  fi
  local queue session now mtime idle distinct urgent
  for queue in "${queues[@]}"; do
    [ -s "$queue" ] || continue
    session="${queue##*/critic-queue-}"
    now="$(date +%s)"
    mtime="$(stat -c %Y "$queue" 2>/dev/null || stat -f %m "$queue" 2>/dev/null || echo "$now")"
    idle=$(( now - mtime ))
    distinct="$(awk '{print $1}' "$queue" | sort -u | wc -l)"
    urgent=0
    if urgent_requested "$session"; then
      urgent=1
      write_required_status "$session" running || true
    fi
    if [ "$urgent" -eq 1 ] || [ "$idle" -ge "$IDLE_SEC" ] ||
       [ "$distinct" -ge "$BATCH_FILES" ]; then
      critique_queue "$queue" "$session"
    fi
  done
}

if [ "$ONCE" -eq 1 ]; then
  eval_pass
  exit 0
fi

while :; do
  eval_pass
  sleep "$POLL_SEC"
done
