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
# CRITIC_POLL_SEC (30), GUARDIAN_CRITIC_MODEL (claude default model if unset).
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
CFG_JSON="{}"
if [ -f "$PROJECT_DIR/.agents/config.toml" ]; then
  CFG_JSON="$(load_config_json "$PROJECT_DIR/.agents/config.toml")" || CFG_JSON="{}"
fi
PROJECT_NAME="$(jq -r '.project_name // empty' <<<"$CFG_JSON")"
[ -n "$PROJECT_NAME" ] || PROJECT_NAME="$(basename "$PROJECT_DIR")"
BUDGET_TOKENS="$(jq -r '.release.budget_tokens_daily // 1000000' <<<"$CFG_JSON")"

# The shoulder-mode critic IS the release role's out-of-band voice. Resolve
# its display through the same map — legacy configs (no [names]) keep the
# svc string "<project>-guardian" and the critique event carries role:release.
ROLE="release"
export QUARTET_ROLE="$ROLE"
# shellcheck disable=SC1091
source "$QUARTET_DIR/agents/lib/naming.sh"
SVC="$PROJECT_NAME-$(role_display "$ROLE" "$CFG_JSON")"

EVENTS_DIR="${QUARTET_EVENTS_DIR:-$PROJECT_DIR/data/events}"

log() { echo "[$SVC-critic] $*"; }

emit_event() {
  # emit_event <event> [key=value ...]
  [ -x "$LOG_EVENT" ] || return 0
  QUARTET_EVENTS_DIR="$EVENTS_DIR" "$LOG_EVENT" "$SVC" "$@" || true
}

# ---------- queue location (must mirror critic-queue.sh) --------------------
if [ -d "$PROJECT_DIR/tmp" ]; then
  QUEUE_DIR="$PROJECT_DIR/tmp"
else
  QUEUE_DIR="/tmp/guardian-critic-$(id -u)/$(basename "$PROJECT_DIR")"
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

# ---------- delivery (separate so retries can reuse a cached critique) ------
deliver_findings() {
  local queue="$1" session="$2" findings_file="$3" n_files="$4"
  local findings n_block n_warn n_note
  findings="$(cat "$findings_file" 2>/dev/null || true)"
  n_block="$(grep -c '^block|' <<<"$findings" || true)"
  n_warn="$(grep -c '^warn|' <<<"$findings" || true)"
  n_note="$(grep -c '^note|' <<<"$findings" || true)"

  if [ -z "${CLAUDE_NOTE_CMD:-}" ]; then
    log "CLAUDE_NOTE_CMD unset; skipping delivery"
    rm -f "$queue"
    return 0
  fi

  local summary
  summary="$(role_display "$ROLE" "$CFG_JSON") critic: $n_block block, $n_warn warn, $n_note note across $n_files files"
  if [ -n "$findings" ]; then
    summary="$summary
$(grep -E '^(block|warn)\|' <<<"$findings" | head -10)"
  fi

  local note_rc
  # shellcheck disable=SC2086 — word-splitting CLAUDE_NOTE_CMD is intentional
  $CLAUDE_NOTE_CMD "$session" "$summary"
  note_rc=$?
  case "$note_rc" in
    2|3)
      # 2 = ambiguous target, 3 = session at an interactive prompt — the
      # note was NOT delivered. Keep the queue so a later pass retries.
      log "claude-note exit $note_rc; queue kept for retry" ;;
    *)
      rm -f "$queue" ;;
  esac
  return 0
}

# ---------- one critique over a queue file ----------------------------------
critique_queue() {
  local queue="$1" session="$2"
  local findings_file="$QUEUE_DIR/guardian-critic-findings-$session"

  # Delivery-retry guard: when a critique already ran for this exact queue
  # state (findings newer than the last queue write), reuse it instead of
  # re-spending the model — claude-note exit 2/3 keeps the queue, and
  # without this every poll pass would re-run the whole critique.
  if [ -s "$findings_file" ] && [ "$findings_file" -nt "$queue" ]; then
    local cached_n
    cached_n="$(awk '{print $1}' "$queue" 2>/dev/null | sort -u | grep -c . || true)"
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
    log "skip: daily token budget reached ($used >= $BUDGET_TOKENS)"
    emit_event release.critique.skipped source=shoulder reason=budget \
      tokens_used="$used" budget="$BUDGET_TOKENS"
    rm -f "$queue"
    return 0
  fi

  # ---- gather the diff: working tree + branch vs trunk ----------------------
  local trunk="" diff="" changed=""
  # shellcheck disable=SC1091
  source "$QUARTET_DIR/agents/lib/detect-trunk.sh"
  trunk="$(detect_trunk "$CFG_JSON" "$PROJECT_DIR" 2>/dev/null)" || trunk=""
  if [ -n "$trunk" ] && git -C "$PROJECT_DIR" rev-parse -q --verify "$trunk" >/dev/null 2>&1; then
    diff="$(git -C "$PROJECT_DIR" diff "$trunk" 2>/dev/null || true)"
    changed="$(git -C "$PROJECT_DIR" diff --name-only "$trunk" 2>/dev/null || true)"
  else
    diff="$(git -C "$PROJECT_DIR" diff HEAD 2>/dev/null || true)"
    changed="$(git -C "$PROJECT_DIR" diff --name-only HEAD 2>/dev/null || true)"
  fi
  # Union with what the hook queued (covers files git can't see yet).
  local queued_files
  queued_files="$(awk '{print $1}' "$queue" 2>/dev/null | sort -u)"
  changed="$(printf '%s\n%s\n' "$changed" "$queued_files" | grep -v '^$' | sort -u)"
  local n_files
  n_files="$(printf '%s\n' "$changed" | grep -c . || true)"

  # ---- project extension (conventions layer) --------------------------------
  local project_ext="" ext_file="$PROJECT_DIR/.agents/release.md"
  [ -f "$ext_file" ] || ext_file="$PROJECT_DIR/.agents/guardian.md"   # legacy name
  [ -f "$ext_file" ] && project_ext="$(cat "$ext_file")"

  local prompt
  prompt="$(cat "$ROLE_FILE")

---

PROJECT EXTENSION (.agents/release.md):

$project_ext

---

CHANGED FILES:

$changed

---

DIFF:

$diff"

  # ---- spawn the critic -----------------------------------------------------
  local model_args=()
  [ -n "${GUARDIAN_CRITIC_MODEL:-}" ] && model_args=(--model "$GUARDIAN_CRITIC_MODEL")
  local claude_out claude_rc
  claude_out="$(claude -p --output-format json "${model_args[@]}" "$prompt" 2>/dev/null)"
  claude_rc=$?
  if [ "$claude_rc" -ne 0 ] || [ -z "$claude_out" ]; then
    log "critic claude run failed (exit=$claude_rc); queue kept for retry"
    return 0
  fi

  # ---- parse findings + real token usage ------------------------------------
  # `claude -p --output-format json` emits one JSON object with the reply
  # in .result and token usage in .usage.{input_tokens,output_tokens}.
  local result_text tokens
  result_text="$(jq -r '.result // ""' <<<"$claude_out" 2>/dev/null || true)"
  tokens="$(jq -r '((.usage.input_tokens // 0) + (.usage.output_tokens // 0))' \
    <<<"$claude_out" 2>/dev/null || echo 0)"
  [[ "$tokens" =~ ^[0-9]+$ ]] || tokens=0

  local findings n_block n_warn n_note
  findings="$(grep -E '^(block|warn|note)\|' <<<"$result_text" || true)"
  n_block="$(grep -c '^block|' <<<"$findings" || true)"
  n_warn="$(grep -c '^warn|' <<<"$findings" || true)"
  n_note="$(grep -c '^note|' <<<"$findings" || true)"

  printf '%s\n' "$findings" >"$findings_file"

  emit_event release.critique source=shoulder files="$n_files" \
    block="$n_block" warn="$n_warn" note="$n_note" tokens="$tokens"
  log "critique: $n_block block, $n_warn warn, $n_note note across $n_files files (tokens=$tokens)"

  # ---- deliver to the dev session -------------------------------------------
  deliver_findings "$queue" "$session" "$findings_file" "$n_files"
  return 0
}

# ---------- evaluation pass -------------------------------------------------
eval_pass() {
  local queues=()
  if [ -n "$SESSION" ]; then
    queues=("$QUEUE_DIR/guardian-critic-queue-$SESSION")
  else
    local q
    for q in "$QUEUE_DIR"/guardian-critic-queue-*; do
      [ -e "$q" ] && queues+=("$q")
    done
  fi
  local queue session now mtime idle distinct
  for queue in "${queues[@]}"; do
    [ -s "$queue" ] || continue
    session="${queue##*/guardian-critic-queue-}"
    now="$(date +%s)"
    mtime="$(stat -c %Y "$queue" 2>/dev/null || echo "$now")"
    idle=$(( now - mtime ))
    distinct="$(awk '{print $1}' "$queue" | sort -u | wc -l)"
    if [ "$idle" -ge "$IDLE_SEC" ] || [ "$distinct" -ge "$BATCH_FILES" ]; then
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
