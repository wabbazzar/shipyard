#!/bin/bash
# agents/lib/post-run.sh — shared trailer for agent runners.
#
# Source me from a runner's hook|daily|live|dry-run code path. I expose
# one function:
#
#   agent_finish <agent_name> <project_dir> <status> <duration_s> \
#       [--no-escalate] [k=v ...]
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

agent_finish() {
  local agent="${1:-}"
  local project_dir="${2:-}"
  local status="${3:-}"
  local duration_s="${4:-0}"
  shift 4 || true
  if [ -z "$agent" ] || [ -z "$project_dir" ] || [ -z "$status" ]; then
    echo "agent_finish: usage: agent_finish <agent> <project> <status> <dur> [--no-escalate] [k=v...]" >&2
    return 2
  fi

  # Pull --no-escalate out of the remaining args; pass everything else
  # through as k=v pairs to log_event.sh.
  local escalate=1
  local kvs=()
  for arg in "$@"; do
    if [ "$arg" = "--no-escalate" ]; then
      escalate=0
    else
      kvs+=("$arg")
    fi
  done

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
      --incident-source "$agent" || true
  fi
}
