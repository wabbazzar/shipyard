#!/bin/bash
# agents/lib/post-run.sh — shared trailer for agent runners.
#
# Source me from a runner's hook|daily|live|dry-run code path. I expose
# one function:
#
#   agent_episode <project> <role> <mode> <cause> <result-file>
#   agent_finish <agent_name> <project_dir> <status> <duration_s> \
#       [--episode <key>] [--no-escalate] [k=v ...]
#
# Effects:
#   1. Emit a job.end event via log_event.sh, carrying status,
#      duration_s, and any extra k=v pairs the caller passes.
#   2. If status=fail AND agent_name != medic AND --no-escalate not
#      passed: synchronously invoke medic --mode post-run
#      --incident-source <agent_name>. Fire-and-forget (errors
#      logged but not propagated). Recursion guard lives in medic
#      itself — passing --incident-source medic causes it to refuse.
#
# Use --no-escalate for agents whose failures aren't fixable by the
# medic→build loop (scribe is the canonical example: doc-gen failures
# are typically Claude/API issues, not codebase regressions).
#
# Do NOT use this from a post-merge mode (where medic invoked the
# agent and is already managing the outcome). Post-merge code paths
# should call log_event.sh directly to avoid double-firing medic.

# Allow override for tests. Default to the canonical install location.
: "${QUARTET_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Derive an episode exactly once at the originating role. The result content,
# not its mutable path or wall clock, distinguishes a genuinely new failure.
agent_episode() {
  local project="${1:-}" role="${2:-}" mode="${3:-}" cause="${4:-}"
  local result_file="${5:-}" fingerprint="missing"
  if [ -n "$result_file" ] && [ -s "$result_file" ]; then
    fingerprint="$(sha256sum "$result_file" | awk '{print $1}')"
  fi
  printf '%s' "$project|$role|$mode|$cause|$fingerprint" |
    sha256sum | awk '{print $1}'
}

agent_finish() {
  local agent="${1:-}"
  local project_dir="${2:-}"
  local status="${3:-}"
  local duration_s="${4:-0}"
  shift 4 || true
  if [ -z "$agent" ] || [ -z "$project_dir" ] || [ -z "$status" ]; then
    echo "agent_finish: usage: agent_finish <agent> <project> <status> <dur> [--episode key] [--no-escalate] [k=v...]" >&2
    return 2
  fi

  # Pull control options out; pass everything else through as job.end fields.
  local escalate=1 origin_episode=""
  local kvs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-escalate) escalate=0; shift ;;
      --episode)
        [ "$#" -ge 2 ] || { echo "agent_finish: --episode requires a key" >&2; return 2; }
        origin_episode="$2"; shift 2 ;;
      *) kvs+=("$1"); shift ;;
    esac
  done
  [ -n "$origin_episode" ] && kvs+=("episode=$origin_episode")

  local log_event="$QUARTET_DIR/agents/lib/log_event.sh"
  local medic_runner="$QUARTET_DIR/agents/medic/runner.sh"

  # 1. job.end
  if [ -x "$log_event" ]; then
    "$log_event" "$agent" job.end \
      status="$status" duration_s="$duration_s" "${kvs[@]}" || true
  fi

  # 2. Escalate to medic on fail (skip recursion + opted-out agents).
  # stdout/stderr inherit from the caller. If the caller has redirected
  # the whole script's output (e.g. systemd captures, or `>> $LOG_FILE
  # 2>&1`), medic's output ends up there. Otherwise it lands on the
  # terminal. Medic also writes its own log under tmp/.
  if [ "$escalate" = "1" ] && [ "$status" = "fail" ] \
     && [ "$agent" != "medic" ] && [ -x "$medic_runner" ]; then
    "$medic_runner" \
      --project "$project_dir" \
      --mode post-run \
      --incident-source "$agent" \
      --origin-episode "$origin_episode" || true
  fi
}
