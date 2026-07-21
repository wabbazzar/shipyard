#!/bin/bash
# agents/guardian/critic-queue.sh — PostToolUse hook: queue an edited file
# for the shoulder-mode critic (agents/guardian/critic-watch.sh).
#
# Reads the Claude Code PostToolUse hook JSON from stdin, appends
# "<file_path> <epoch>" to the per-session queue file, exits 0. No LLM,
# no network, no blocking work — this runs inline in the dev agent's
# tool loop and must never slow it down or fail it.
#
# Queue file: <project>/tmp/guardian-critic-queue-<session_id>
#   session_id — hook JSON .session_id, fallback "default"
#   project    — $CLAUDE_PROJECT_DIR, fallback cwd
# If <project>/tmp/ doesn't exist, falls back to
# /tmp/guardian-critic-<uid>/<project-basename>/.
#
# ALWAYS exits 0, even on malformed input or write errors.

set -u

INPUT="$(cat 2>/dev/null || true)"

FILE_PATH="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT" 2>/dev/null || true)"
[ -n "$FILE_PATH" ] || exit 0   # not an Edit/Write payload — nothing to queue

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)"
[ -n "$SESSION_ID" ] || SESSION_ID="default"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if [ -d "$PROJECT_DIR/tmp" ]; then
  QUEUE_DIR="$PROJECT_DIR/tmp"
else
  QUEUE_DIR="/tmp/guardian-critic-$(id -u)/$(basename "$PROJECT_DIR")"
  mkdir -p "$QUEUE_DIR" 2>/dev/null || exit 0
fi

printf '%s %s\n' "$FILE_PATH" "$(date +%s)" \
  >> "$QUEUE_DIR/guardian-critic-queue-$SESSION_ID" 2>/dev/null || true

exit 0
