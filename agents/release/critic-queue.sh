#!/bin/bash
# agents/release/critic-queue.sh — PostToolUse hook: queue an edited file
# for the shoulder-mode critic (agents/release/critic-watch.sh).
#
# Reads the Claude Code PostToolUse hook JSON from stdin, appends
# "<file_path> <epoch>" to the per-session queue file, exits 0. No LLM,
# no network, no blocking work — this runs inline in the dev agent's
# tool loop and must never slow it down or fail it.
#
# Queue file: <project>/tmp/critic-queue-<session_id>
#   session_id — hook JSON .session_id, fallback "default"
#   project    — $CLAUDE_PROJECT_DIR, fallback cwd
# If <project>/tmp/ doesn't exist, falls back to
# /tmp/shipyard-critic-<uid>/<project-basename>/.
#
# The filters + queue format live in critic-queue-lib.sh (shared with the
# codex/hermes capture hooks). ALWAYS exits 0, even on malformed input.

set -u

# shellcheck source=agents/release/critic-queue-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/critic-queue-lib.sh"

INPUT="$(cat 2>/dev/null || true)"

FILE_PATH="$(jq -r '.tool_input.file_path // empty' <<<"$INPUT" 2>/dev/null || true)"
[ -n "$FILE_PATH" ] || exit 0   # not an Edit/Write payload — nothing to queue

SESSION_ID="$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null || true)"

cq_enqueue "$FILE_PATH" "$SESSION_ID" "${CLAUDE_PROJECT_DIR:-$PWD}"

exit 0
